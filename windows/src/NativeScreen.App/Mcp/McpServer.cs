using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;

namespace NativeScreen.App;

/// <summary>
/// Lets AI agents (Claude, Codex, Cursor...) drive the app through the Model Context Protocol (spec/06 ADR-52). The app is the
/// server: it listens on a named pipe only the current user can open, and clients reach it through <c>--mcp</c>
/// (<see cref="McpBridge"/>). Messages are newline-delimited JSON-RPC, as on MCP's stdio transport. Waiting for a client is
/// an overlapped pipe wait, so it costs no CPU.
/// </summary>
internal sealed class McpServer
{
    public static readonly string[] SupportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"];

    private readonly List<McpConnection> connections = [];
    private DispatcherQueue? ui;
    private CancellationTokenSource? listening;
    private McpToolbox? toolbox;

    public static McpServer Shared { get; } = new();

    public bool IsListening => listening is not null;

    public IReadOnlyList<string> ConnectedClients => connections.Select(item => item.ClientName).OfType<string>().Order().ToList();

    public string? LastError { get; private set; }

    /// <summary>The status or the client list changed; raised on the UI thread.</summary>
    public event Action? Changed;

    internal McpToolbox Toolbox => toolbox ??= new McpToolbox();

    /// <summary>Starts or stops listening to match the setting. Called on the UI thread.</summary>
    public void ApplySetting()
    {
        if (AppSettings.Shared.AiAgentsEnabled)
        {
            Start();
        }
        else
        {
            Stop();
        }
    }

    public void Stop()
    {
        if (listening is null)
        {
            return;
        }

        listening.Cancel();
        listening.Dispose();
        listening = null;
        foreach (var connection in connections.ToList())
        {
            connection.Close();
        }

        connections.Clear();
        Changed?.Invoke();
    }

    private void Start()
    {
        if (listening is not null)
        {
            return;
        }

        ui = DispatcherQueue.GetForCurrentThread();
        LastError = null;
        listening = new CancellationTokenSource();
        var token = listening.Token;
        _ = Task.Run(() => AcceptLoop(token));
        Changed?.Invoke();
    }

    private async Task AcceptLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = new NamedPipeServerStream(McpBridge.PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                Post(() =>
                {
                    LastError = exception.Message;
                    Changed?.Invoke();
                });
                return;
            }

            try
            {
                await pipe.WaitForConnectionAsync(token);
            }
            catch (OperationCanceledException)
            {
                await pipe.DisposeAsync();
                return;
            }
            catch (IOException)
            {
                await pipe.DisposeAsync();
                continue;
            }

            Post(() => Adopt(pipe));
        }
    }

    private void Post(Action action) => ui?.TryEnqueue(() => action());

    private void Adopt(NamedPipeServerStream pipe)
    {
        if (listening is null)
        {
            pipe.Dispose();
            return;
        }

        var connection = new McpConnection(pipe);
        connections.Add(connection);
        connection.Message += message => Post(() => Handle(message, connection));
        connection.Ended += () => Post(() =>
        {
            if (connections.Remove(connection))
            {
                Changed?.Invoke();
            }
        });
        connection.Start();
    }

    private void Handle(JsonNode message, McpConnection connection)
    {
        if (message is JsonArray batch)
        {
            foreach (var item in batch)
            {
                if (item is not null)
                {
                    Handle(item, connection);
                }
            }

            return;
        }

        if (message is not JsonObject request || request["method"]?.GetValue<string>() is not { } method)
        {
            return; // a response to a request this server never sends
        }

        var id = request["id"]?.DeepClone();
        var parameters = request["params"] as JsonObject ?? [];
        switch (method)
        {
            case "initialize":
                var requested = parameters["protocolVersion"]?.GetValue<string>();
                var version = requested is not null && SupportedProtocolVersions.Contains(requested) ? requested : SupportedProtocolVersions[0];
                var wasEmpty = ConnectedClients.Count == 0;
                connection.ClientName = parameters["clientInfo"]?["name"]?.GetValue<string>() ?? "MCP client";
                Changed?.Invoke();
                if (wasEmpty)
                {
                    Projects.Active?.McpToast("AI agent connected");
                }

                connection.Reply(id, new JsonObject
                {
                    ["protocolVersion"] = version,
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
                    ["serverInfo"] = new JsonObject { ["name"] = "nativescreen", ["title"] = "Native Screen", ["version"] = AppVersion },
                    ["instructions"] = Toolbox.Instructions
                });
                break;
            case "notifications/initialized" or "notifications/roots/list_changed":
                break;
            case "ping":
                connection.Reply(id, []);
                break;
            case "tools/list":
                connection.Reply(id, new JsonObject { ["tools"] = Toolbox.Definitions.DeepClone() });
                break;
            case "tools/call":
                if (parameters["name"]?.GetValue<string>() is not { } name)
                {
                    connection.ReplyError(id, -32602, "Missing tool name");
                    return;
                }

                var arguments = parameters["arguments"] as JsonObject ?? [];
                var token = parameters["_meta"]?["progressToken"]?.DeepClone();
                Action<double, string>? progress = token is null ? null : (fraction, text) => connection.Notify("notifications/progress", new JsonObject
                {
                    ["progressToken"] = token.DeepClone(),
                    ["progress"] = fraction,
                    ["total"] = 1.0,
                    ["message"] = text
                });
                _ = Call(connection, id, name, arguments, progress);
                break;
            case "notifications/cancelled":
                connection.Cancel(Key(parameters["requestId"]));
                break;
            case "resources/list":
                connection.Reply(id, new JsonObject { ["resources"] = new JsonArray() });
                break;
            case "prompts/list":
                connection.Reply(id, new JsonObject { ["prompts"] = new JsonArray() });
                break;
            default:
                if (id is not null)
                {
                    connection.ReplyError(id, -32601, "Method not found: " + method);
                }

                break;
        }
    }

    private async Task Call(McpConnection connection, JsonNode? id, string name, JsonObject arguments, Action<double, string>? progress)
    {
        var key = Key(id);
        using var cancel = connection.Track(key);
        var result = await Toolbox.Call(name, arguments, progress, cancel.Token);
        connection.Finish(key);
        if (!cancel.IsCancellationRequested)
        {
            connection.Reply(id, result);
        }
    }

    private static string Key(JsonNode? id) => id is null ? "?" : id.ToJsonString();

    public static string AppVersion => typeof(McpServer).Assembly.GetName().Version?.ToString(3) ?? "0";
}

/// <summary>One client on the pipe. Reads on a worker; writes are serialized so replies never interleave.</summary>
internal sealed class McpConnection(NamedPipeServerStream pipe)
{
    private readonly SemaphoreSlim writing = new(1, 1);
    private readonly Dictionary<string, CancellationTokenSource> tasks = [];
    private bool closed;

    public string? ClientName { get; set; }

    public event Action<JsonNode>? Message;

    public event Action? Ended;

    public void Start() => _ = Task.Run(ReadLoop);

    private async Task ReadLoop()
    {
        try
        {
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 65_536, leaveOpen: true);
            while (await reader.ReadLineAsync() is { } line)
            {
                if (line.Length == 0)
                {
                    continue;
                }

                JsonNode? node;
                try
                {
                    node = JsonNode.Parse(line);
                }
                catch (System.Text.Json.JsonException)
                {
                    ReplyError(null, -32700, "Parse error");
                    continue;
                }

                if (node is not null)
                {
                    Message?.Invoke(node);
                }
            }
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
        }

        Close();
    }

    public void Reply(JsonNode? id, JsonObject result) => Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["result"] = result });

    public void ReplyError(JsonNode? id, int code, string message) =>
        Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = new JsonObject { ["code"] = code, ["message"] = message } });

    public void Notify(string method, JsonObject parameters) => Send(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = method, ["params"] = parameters });

    private void Send(JsonObject message)
    {
        if (closed)
        {
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(message.ToJsonString() + "\n");
        _ = Task.Run(async () =>
        {
            await writing.WaitAsync();
            try
            {
                await pipe.WriteAsync(bytes);
                await pipe.FlushAsync();
            }
            catch (Exception exception) when (exception is IOException or ObjectDisposedException)
            {
            }
            finally
            {
                writing.Release();
            }
        });
    }

    public CancellationTokenSource Track(string key)
    {
        var source = new CancellationTokenSource();
        lock (tasks)
        {
            tasks[key] = source;
        }

        return source;
    }

    public void Finish(string key)
    {
        lock (tasks)
        {
            tasks.Remove(key);
        }
    }

    public void Cancel(string key)
    {
        lock (tasks)
        {
            if (tasks.Remove(key, out var source))
            {
                source.Cancel();
            }
        }
    }

    public void Close()
    {
        if (closed)
        {
            return;
        }

        closed = true;
        lock (tasks)
        {
            foreach (var source in tasks.Values)
            {
                source.Cancel();
            }

            tasks.Clear();
        }

        try
        {
            pipe.Dispose();
        }
        catch (IOException)
        {
        }

        Ended?.Invoke();
    }
}
