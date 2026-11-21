using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace PopupCaptureSpike;

/// <summary>Driving other apps: a button by its accessible name, keys to a window.</summary>
internal static class Ui
{
    public static void Invoke(int processId, string name)
    {
        var condition = new AndCondition(new PropertyCondition(AutomationElement.ProcessIdProperty, processId), new PropertyCondition(AutomationElement.NameProperty, name));
        var element = AutomationElement.RootElement.FindFirst(TreeScope.Descendants, condition);
        if (element?.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern invoke)
        {
            invoke.Invoke();
        }
    }

    public static void PressEscape(nint window) => KeyTo(window, alt: false, 0x1B);

    public static void KeyTo(nint window, bool alt, byte key)
    {
        SetForegroundWindow(window);
        Thread.Sleep(300);
        if (alt)
        {
            keybd_event(0x12, 0, 0, 0);
        }

        keybd_event(key, 0, 0, 0);
        keybd_event(key, 0, 2, 0);
        if (alt)
        {
            keybd_event(0x12, 0, 2, 0);
        }
    }

    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, nint extra);
}
