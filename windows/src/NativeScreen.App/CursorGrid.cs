using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;

namespace NativeScreen.App;

/// <summary>A grid that shows its own pointer cursor; UIElement.ProtectedCursor is only reachable from a subclass.</summary>
internal sealed partial class CursorGrid : Grid
{
    public CursorGrid(InputSystemCursorShape shape) => ProtectedCursor = InputSystemCursor.Create(shape);
}
