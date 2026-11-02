using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using WinRT;

namespace NativeScreen.Media;

/// <summary>IGraphicsCaptureItemInterop through its vtable: projected objects cannot be cast to [ComImport] interfaces (spec/06 ADR-18).</summary>
internal static unsafe class CaptureItemInterop
{
    private static readonly Guid InteropIid = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    private static readonly Guid ItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    public static GraphicsCaptureItem ForWindow(nint hwnd) => Create(3, hwnd);

    public static GraphicsCaptureItem ForMonitor(nint monitor) => Create(4, monitor);

    private static GraphicsCaptureItem Create(int slot, nint handle)
    {
        using var factory = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var iid = InteropIid;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(factory.ThisPtr, in iid, out var interop));
        try
        {
            var method = (delegate* unmanaged[Stdcall]<nint, nint, Guid*, nint*, int>)(*(nint**)interop)[slot];
            var itemIid = ItemIid;
            nint raw;
            Marshal.ThrowExceptionForHR(method(interop, handle, &itemIid, &raw));
            try
            {
                return GraphicsCaptureItem.FromAbi(raw);
            }
            finally
            {
                Marshal.Release(raw);
            }
        }
        finally
        {
            Marshal.Release(interop);
        }
    }
}
