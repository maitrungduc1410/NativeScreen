namespace NativeScreen.Media;

public static class CapturePolicy
{
    public const int ExcludeFromCapture = 0x00000011;
    public const bool CaptureCursor = false;

    // VERIFY: GraphicsCaptureSession.IsCursorCaptureEnabled = CaptureCursor.
    // GraphicsCaptureAccess.RequestAccessAsync(Borderless), then IsBorderRequired = false; the border stays if access is denied.
    // An unpackaged copy needs no declaration. The MSIX declares uap11:Capability graphicsCaptureWithoutBorder, a general-use
    // capability in the Windows SDK schema (spec/06 ADR-81). Items come from HWND/HMONITOR interop, so graphicsCaptureProgrammatic
    // (only for items made from a WindowId or DisplayId) is not declared.
    // VERIFY: from the installed MSIX, a recording shows no yellow border.
    // VERIFY: SetWindowDisplayAffinity(hwnd, ExcludeFromCapture) on the HUD before the capture session starts.
    // VERIFY: t = 0 is the QPC of the first frame. Hook callbacks only enqueue; timestamps come from QueryPerformanceCounter.
}
