using System.Runtime.InteropServices;

namespace NativeScreen.App;

[ComImport]
[Guid("63aad0b8-7c24-40ff-85a8-640d944cc325")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface INativeSwapChainPanel
{
    void SetSwapChain(nint swapChain);
}

internal static class SwapChainPanelInterop
{
    public static void SetSwapChain(object panel, nint swapChain)
    {
        var native = (INativeSwapChainPanel)panel;
        native.SetSwapChain(swapChain);
    }
}
