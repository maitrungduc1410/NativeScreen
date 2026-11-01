namespace NativeScreen.Media;

public static class CapturePolicy
{
    public const int ExcludeFromCapture = 0x00000011;
    public const bool CaptureCursor = false;

    // VERIFY: GraphicsCaptureSession.IsCursorCaptureEnabled = CaptureCursor.
    // VERIFY: GraphicsCaptureAccess.RequestAccessAsync(Borderless), then IsBorderRequired = false. Keep the border if access is denied.
    // VERIFY: SetWindowDisplayAffinity(hwnd, ExcludeFromCapture) on the HUD before the capture session starts.
    // VERIFY: t = 0 is the QPC of the first frame. Hook callbacks only enqueue; timestamps come from QueryPerformanceCounter.
}
