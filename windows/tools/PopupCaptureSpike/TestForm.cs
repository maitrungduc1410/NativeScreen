using System.Runtime.InteropServices;

namespace PopupCaptureSpike;

/// <summary>A solid green window that opens one kind of popup at a time over itself.</summary>
internal sealed class TestForm : Form
{
    private readonly ComboBox combo = new() { Left = 40, Top = 40, Width = 260, DropDownStyle = ComboBoxStyle.DropDownList, BackColor = Color.Magenta };
    private readonly DateTimePicker date = new() { Left = 340, Top = 40, Width = 260 };
    private readonly ContextMenuStrip context = new() { BackColor = Color.Orange };
    private readonly ToolTip tip = new() { BackColor = Color.Yellow, OwnerDraw = false };
    private Form? palette;

    public TestForm()
    {
        Text = "Popup capture spike";
        BackColor = Color.FromArgb(0, 200, 0);
        StartPosition = FormStartPosition.Manual;
        Left = 200;
        Top = 150;
        Width = 1100;
        Height = 760;
        for (var index = 1; index <= 15; index++)
        {
            combo.Items.Add($"ComboBox item {index}");
            context.Items.Add($"Context menu item {index}");
        }

        combo.SelectedIndex = 0;
        Controls.Add(combo);
        Controls.Add(date);
    }

    public sealed record Scenario(string Name, Action Open, Action<TestForm> Close);

    public IReadOnlyList<Scenario> Scenarios =>
    [
        new("Win32 menu (TrackPopupMenu)", () => BeginInvoke(ShowWin32Menu), form => PostMessageW(form.Handle, 0x001F, 0, 0)),
        new("ComboBox dropdown", () => combo.DroppedDown = true, form => form.Invoke(() => combo.DroppedDown = false)),
        new("ContextMenuStrip", () => context.Show(this, new Point(400, 200)), form => form.Invoke(context.Close)),
        new("ToolTip", () => tip.Show("A tooltip over the green window, long enough to measure", this, new Point(200, 400), 8000), form => form.Invoke(() => tip.Hide(this))),
        new("DateTimePicker calendar", () => SendMessageW(date.Handle, 0x0104, 0x28, 0x20000000), form => form.Invoke(() => SendMessageW(date.Handle, 0x0100, 0x1B, 0))),
        new("Owned borderless form", ShowPalette, form => form.Invoke(() => palette?.Close())),
    ];

    private void ShowWin32Menu()
    {
        var menu = CreatePopupMenu();
        for (var index = 1; index <= 12; index++)
        {
            AppendMenuW(menu, 0, (nuint)index, $"Win32 menu item {index}");
        }

        var origin = PointToScreen(new Point(700, 200));
        TrackPopupMenu(menu, 0x0100, origin.X, origin.Y, 0, Handle, 0);
        DestroyMenu(menu);
    }

    private void ShowPalette()
    {
        var origin = PointToScreen(new Point(150, 480));
        palette = new Form
        {
            Owner = this,
            FormBorderStyle = FormBorderStyle.None,
            ShowInTaskbar = false,
            StartPosition = FormStartPosition.Manual,
            BackColor = Color.SteelBlue,
            Left = origin.X,
            Top = origin.Y,
            Width = 360,
            Height = 160
        };
        palette.Show(this);
    }

    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenuW(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern int TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")] private static extern bool PostMessageW(nint window, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern nint SendMessageW(nint window, uint message, nint wParam, nint lParam);
}
