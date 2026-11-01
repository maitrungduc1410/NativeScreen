namespace NativeScreen.Core;

public readonly record struct CursorSpriteName(string SetId, string Kind, int Variant, double HotspotX, double HotspotY)
{
    public static readonly string[] PreferredThemeOrder = ["arrow", "rounded", "touch"];

    public static string NormalizeThemeId(string? themeId)
    {
        if (themeId is "arrow" or "rounded" or "touch")
        {
            return themeId;
        }

        return themeId?.StartsWith("touch", StringComparison.Ordinal) == true ? "touch" : "arrow";
    }

    public static CursorSpriteName Parse(string fileName, string setId)
    {
        var baseName = fileName;
        while (baseName.EndsWith(".svg", StringComparison.OrdinalIgnoreCase))
        {
            baseName = baseName[..^4];
        }

        var parts = baseName.Split("__", StringSplitOptions.None);
        if (parts.Length != 2)
        {
            throw new FormatException($"Cursor file '{fileName}' is not kind-variant__hotspot.svg.");
        }

        var idPieces = parts[0].Split('-');
        var hotspot = parts[1].Split('-');
        var kind = idPieces[0];
        var variant = idPieces.Length > 1 && int.TryParse(idPieces[^1], out var number) ? number : 1;
        var hx = hotspot.Length > 0 && double.TryParse(hotspot[0], out var x) ? x : 14;
        var hy = hotspot.Length > 1 && double.TryParse(hotspot[1], out var y) ? y : 10;
        return new CursorSpriteName(setId, kind, variant, hx / 100.0, hy / 100.0);
    }
}
