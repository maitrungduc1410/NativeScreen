using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;

namespace NativeScreen.App;

/// <summary>
/// <c>NativeScreen.App.exe --mcp</c>: what MCP clients run. It never starts WinUI; it connects to the running app's pipe,
/// starting the app first when needed, and copies bytes both ways until either side closes. Nothing else may be written
/// to stdout, which carries the protocol (spec/06 ADR-52).
/// </summary>
internal static class McpBridge
{
    private const int LaunchTimeoutMs = 20_000;

    /// <summary>One pipe per Windows user; the pipe itself only admits that user.</summary>
    public static string PipeName { get; } = "NativeScreen.MCP." + (WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName);

    public static int Run()
    {
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();
        var pipe = Connect(300);
        if (pipe is null)
        {
            if (!AppSettings.Shared.AiAgentsEnabled)
            {
                return FailFirstRequest(input, output, "AI agent access is turned off. In Native Screen, open Settings > AI Agents and turn on “Allow AI agents to control Native Screen”.");
            }

            Launch();
            var clock = Stopwatch.StartNew();
            while (pipe is null && clock.ElapsedMilliseconds < LaunchTimeoutMs)
            {
                pipe = Connect(500);
            }

            if (pipe is null)
            {
                return FailFirstRequest(input, output, "Native Screen did not start its AI agent server. Open Native Screen and check Settings > AI Agents.");
            }
        }

        using (pipe)
        {
            var toApp = Task.Run(async () =>
            {
                try
                {
                    await input.CopyToAsync(pipe);
                }
                catch (IOException)
                {
                }
            });
            var fromApp = Task.Run(async () =>
            {
                try
                {
                    var buffer = new byte[65_536];
                    int read;
                    while ((read = await pipe.ReadAsync(buffer)) > 0)
                    {
                        await output.WriteAsync(buffer.AsMemory(0, read));
                        await output.FlushAsync();
                    }
                }
                catch (IOException)
                {
                }
            });
            Task.WaitAny(toApp, fromApp);
        }

        return 0;
    }

    private static NamedPipeClientStream? Connect(int timeoutMs)
    {
        var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try
        {
            pipe.Connect(timeoutMs);
            return pipe;
        }
        catch (Exception exception) when (exception is TimeoutException or IOException or UnauthorizedAccessException)
        {
            pipe.Dispose();
            return null;
        }
    }

    /// <summary>
    /// Starts this same executable as the app. It shows the recording bar, as any launch does. Through the shell, so the app
    /// does not inherit this process's stdout: a client waits for every holder of that pipe to close before it sees the
    /// bridge exit, and the app would hold it until it quits.
    /// </summary>
    private static void Launch()
    {
        if (Environment.ProcessPath is { } executable)
        {
            Process.Start(new ProcessStartInfo(executable) { UseShellExecute = true })?.Dispose();
        }
    }

    /// <summary>Answers the client's first request (normally initialize) with the reason, so it shows up in the client.</summary>
    private static int FailFirstRequest(Stream input, Stream output, string message)
    {
        Console.Error.WriteLine(message);
        JsonNode? id = null;
        try
        {
            using var reader = new StreamReader(input, Encoding.UTF8, false, 4096, leaveOpen: true);
            if (reader.ReadLine() is { } line && JsonNode.Parse(line) is JsonObject request)
            {
                id = request["id"]?.DeepClone();
            }
        }
        catch (Exception exception) when (exception is IOException or System.Text.Json.JsonException)
        {
        }

        var response = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id,
            ["error"] = new JsonObject { ["code"] = -32000, ["message"] = message }
        };
        var bytes = Encoding.UTF8.GetBytes(response.ToJsonString() + "\n");
        output.Write(bytes);
        output.Flush();
        return 1;
    }
}
