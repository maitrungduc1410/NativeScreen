using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using WinRT;

namespace NativeScreen.App;

internal static class SwapChainPanelInterop
{
    // ISwapChainPanelNative from microsoft.ui.xaml.media.dxinterop.h.
    private static readonly Guid NativePanelIid = new("63aad0b8-7c24-40ff-85a8-640d944cc325");
    private const int SetSwapChainSlot = 3;

    // Projected WinUI objects are not COM wrappers, so a managed cast to a [ComImport] interface always throws.
    // QueryInterface has to go through the panel's native pointer.
    public static unsafe void SetSwapChain(SwapChainPanel panel, nint swapChain)
    {
        var unknown = ((IWinRTObject)panel).NativeObject.ThisPtr;
        var iid = NativePanelIid;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unknown, in iid, out var native));
        try
        {
            var vtable = *(nint**)native;
            var setSwapChain = (delegate* unmanaged[Stdcall]<nint, nint, int>)vtable[SetSwapChainSlot];
            Marshal.ThrowExceptionForHR(setSwapChain(native, swapChain));
        }
        finally
        {
            Marshal.Release(native);
        }

        GC.KeepAlive(panel);
    }
}
