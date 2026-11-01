namespace NativeScreen.Core;

public sealed class MeshPreset
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Category { get; init; }
    public required IReadOnlyList<string> ColorsHex { get; init; }

    public static IReadOnlyList<MeshPreset> BuiltIn { get; } =
    [
        new() { Id = "spring-aurora", Name = "Spring Aurora", Category = "Spring", ColorsHex = ["#00D2FF", "#92FE9D", "#FF6B6B", "#FFE66D"] },
        new() { Id = "spring-blossom", Name = "Spring Blossom", Category = "Spring", ColorsHex = ["#FF9A9E", "#FAD0C4", "#A18CD1", "#FBC2EB"] },
        new() { Id = "sunset-glow", Name = "Sunset Glow", Category = "Sunset", ColorsHex = ["#FA709A", "#FEE140", "#F83600", "#FE8C00"] },
        new() { Id = "radiant-violet", Name = "Radiant Violet", Category = "Radiant", ColorsHex = ["#4776E6", "#8E54E9", "#FF0844", "#FFB199"] },
        new() { Id = "midnight-indigo", Name = "Midnight Indigo", Category = "Midnight", ColorsHex = ["#0F2027", "#203A43", "#2C5364", "#4A00E0"] },
        new() { Id = "iridescent-pearl", Name = "Iridescent Pearl", Category = "Iridescent", ColorsHex = ["#8EC5FC", "#E0C3FC", "#FFDEE9", "#B5FFFC"] },
        new() { Id = "energy-cyber", Name = "Energy Pulse", Category = "Energy", ColorsHex = ["#12C2E9", "#C471ED", "#F64F59", "#7F00FF"] },
        new() { Id = "glass-ocean", Name = "Glass Ocean", Category = "Glassmorphism", ColorsHex = ["#2193B0", "#6DD5ED", "#1A2980", "#26D0CE"] }
    ];

    public static MeshPreset Find(string? id) =>
        BuiltIn.FirstOrDefault(preset => preset.Id == id) ?? BuiltIn[0];
}
