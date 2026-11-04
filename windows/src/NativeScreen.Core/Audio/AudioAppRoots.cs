namespace NativeScreen.Core;

/// <summary>Which processes to capture for a set of chosen apps.</summary>
public static class AudioAppRoots
{
    /// <summary>
    /// A capture includes a process's whole tree, so a child of the same app is left out: a browser's helpers would otherwise
    /// be heard twice. Stops at <paramref name="limit"/>, one stream per process.
    /// </summary>
    public static List<int> Select(IReadOnlyList<(int Id, int ParentId, string Name)> processes, IReadOnlyCollection<string> chosenNames, int limit)
    {
        var chosen = new HashSet<string>(chosenNames, StringComparer.OrdinalIgnoreCase);
        var names = new Dictionary<int, string>();
        foreach (var process in processes)
        {
            names[process.Id] = process.Name;
        }

        var roots = new List<int>();
        foreach (var process in processes)
        {
            if (roots.Count == limit)
            {
                break;
            }

            var underSameApp = process.ParentId != process.Id
                && names.TryGetValue(process.ParentId, out var parent)
                && string.Equals(parent, process.Name, StringComparison.OrdinalIgnoreCase);
            if (chosen.Contains(process.Name) && !underSameApp)
            {
                roots.Add(process.Id);
            }
        }

        return roots;
    }
}
