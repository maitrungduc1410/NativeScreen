using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace NativeScreen.App;

/// <summary>Settings > AI Agents: the switch, the server status and the lines to paste into each agent (spec/06 ADR-52).</summary>
public sealed partial class SettingsWindow
{
    private TextBlock? agentStatus;

    private void Agents()
    {
        var settings = AppSettings.Shared;
        var toggle = new ToggleSwitch { IsOn = settings.AiAgentsEnabled, OnContent = "", OffContent = "", MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Right };
        A11y.Name(toggle, "Allow AI agents to control Native Screen");
        toggle.Toggled += (_, _) =>
        {
            settings.AiAgentsEnabled = toggle.IsOn;
            settings.Save();
            McpServer.Shared.ApplySetting();
            RefreshAgentStatus();
        };
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var texts = new StackPanel { Spacing = 4 };
        texts.Children.Add(Ui.Text("Allow AI agents to control Native Screen", 13, "Ink95", true));
        var description = Ui.Text("Claude, Codex, Cursor and other MCP apps can record, edit, change settings and export for you. They connect on this PC only.", 12, "Ink60");
        description.TextWrapping = TextWrapping.Wrap;
        texts.Children.Add(description);
        row.Children.Add(texts);
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        Body.Children.Add(row);

        Heading("Status");
        agentStatus = Ui.Text("", 12.5, "Ink60");
        Body.Children.Add(agentStatus);
        RefreshAgentStatus();

        Heading("Connect an agent");
        var hint = Ui.Text("Paste this in the agent’s terminal or settings. The agent starts Native Screen when it needs it.", 12, "Ink60");
        hint.TextWrapping = TextWrapping.Wrap;
        Body.Children.Add(hint);
        var executable = Environment.ProcessPath ?? "NativeScreen.App.exe";
        var json = $$"""
            {
              "mcpServers": {
                "nativescreen": {
                  "command": {{System.Text.Json.JsonSerializer.Serialize(executable)}},
                  "args": ["--mcp"]
                }
              }
            }
            """;
        // The "--" is quoted: npm installs these CLIs as PowerShell scripts (claude.ps1), and PowerShell drops a bare "--"
        // before the script sees it, so "--mcp" was read as the CLI's own option. The quoted form works in Git Bash too.
        foreach (var (title, text) in new[]
        {
            ("Claude Code", $"claude mcp add nativescreen '--' \"{executable}\" --mcp"),
            ("Codex", $"codex mcp add nativescreen '--' \"{executable}\" --mcp"),
            ("Claude Desktop, Cursor and other apps", json)
        })
        {
            Body.Children.Add(CopyBlock(title, text));
        }

        var footnote = Ui.Text("Every edit an agent makes shows in the editor and can be undone with Ctrl+Z. Recording shows the recording bar and its countdown. A deleted project goes to the Recycle Bin.", 12, "Ink45");
        footnote.TextWrapping = TextWrapping.Wrap;
        Body.Children.Add(footnote);
    }

    private static UIElement CopyBlock(string title, string text)
    {
        var block = new StackPanel { Spacing = 6 };
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Ui.Text(title, 12.5, "Ink88", true));
        Button? copy = null;
        copy = Ui.Option("Copy", false, () =>
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(text);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            copy!.Content = Loc.T("Copied");
        });
        copy.Padding = new Thickness(12, 4, 12, 4);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(copy, Loc.F("Copy %@", Loc.T(title)));
        Grid.SetColumn(copy, 1);
        header.Children.Add(copy);
        block.Children.Add(header);
        var code = new TextBox
        {
            // AcceptsReturn comes before Text: without it a TextBox keeps only the first line.
            AcceptsReturn = true,
            Text = text,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(code, Loc.T(title));
        block.Children.Add(code);
        return block;
    }

    private void RefreshAgentStatus()
    {
        if (agentStatus is null)
        {
            return;
        }

        var server = McpServer.Shared;
        agentStatus.Text = !AppSettings.Shared.AiAgentsEnabled ? Loc.T("Off")
            : server.LastError is { } error ? error
            : server.ConnectedClients.Count == 0 ? Loc.T("Waiting for an agent to connect")
            : Loc.F("Connected: %@", string.Join(", ", server.ConnectedClients));
    }
}
