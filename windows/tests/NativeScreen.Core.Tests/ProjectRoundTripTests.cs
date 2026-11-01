using System.Globalization;
using System.Text.Json;
using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>Everything a macOS project contains must survive load and save, so Windows can never lose data.</summary>
public sealed class ProjectRoundTripTests
{
    public static IEnumerable<object[]> Cases()
    {
        foreach (var directory in Directory.GetDirectories(CasesRoot()).OrderBy(path => path, StringComparer.Ordinal))
        {
            yield return [Path.GetFileName(directory)];
        }
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void ProjectJsonKeepsEveryValue(string caseId)
    {
        var path = Path.Combine(CasesRoot(), caseId, "project.nativescreen", "project.json");
        AssertKept(File.ReadAllText(path), text => ProjectJson.Serialize(ProjectJson.Deserialize<ProjectDocument>(text)), caseId);
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void MetadataJsonKeepsEveryValue(string caseId)
    {
        var path = Path.Combine(CasesRoot(), caseId, "project.nativescreen", "recording", "metadata.json");
        AssertKept(File.ReadAllText(path), text => ProjectJson.Serialize(ProjectJson.Deserialize<RecordingMetadata>(text)), caseId);
    }

    private static void AssertKept(string source, Func<string, string> roundTrip, string caseId)
    {
        using var before = JsonDocument.Parse(source);
        using var after = JsonDocument.Parse(roundTrip(source));
        var differences = new List<string>();
        Compare(before.RootElement, after.RootElement, "$", differences);
        Assert.True(differences.Count == 0, $"{caseId}:\n{string.Join("\n", differences.Take(40))}");
    }

    private static void Compare(JsonElement source, JsonElement output, string path, List<string> differences)
    {
        switch (source.ValueKind)
        {
            case JsonValueKind.Object:
                if (output.ValueKind != JsonValueKind.Object)
                {
                    differences.Add($"{path}: expected object, got {output.ValueKind}");
                    return;
                }

                foreach (var property in source.EnumerateObject())
                {
                    if (property.Value.ValueKind == JsonValueKind.Null)
                    {
                        continue;
                    }

                    if (output.TryGetProperty(property.Name, out var value))
                    {
                        Compare(property.Value, value, $"{path}.{property.Name}", differences);
                    }
                    else
                    {
                        differences.Add($"{path}.{property.Name}: dropped");
                    }
                }

                break;
            case JsonValueKind.Array:
                if (output.ValueKind != JsonValueKind.Array || output.GetArrayLength() != source.GetArrayLength())
                {
                    differences.Add($"{path}: array changed");
                    return;
                }

                var index = 0;
                foreach (var pair in source.EnumerateArray().Zip(output.EnumerateArray()))
                {
                    Compare(pair.First, pair.Second, $"{path}[{index++}]", differences);
                }

                break;
            case JsonValueKind.Number:
                if (output.ValueKind != JsonValueKind.Number || Math.Abs(source.GetDouble() - output.GetDouble()) > 1e-9)
                {
                    differences.Add($"{path}: {source.GetDouble().ToString(CultureInfo.InvariantCulture)} became {output}");
                }

                break;
            default:
                if (source.ValueKind != output.ValueKind || source.ToString() != output.ToString())
                {
                    differences.Add($"{path}: '{source}' became '{output}'");
                }

                break;
        }
    }

    private static string CasesRoot([System.Runtime.CompilerServices.CallerFilePath] string file = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "..", "..", "..", "conformance", "cases"));
}
