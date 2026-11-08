using NativeScreen.Core;
using NativeScreen.Export;

namespace NativeScreen.App;

/// <summary>What the MCP tools reach in an editor: the same session, tools and export path the UI uses (spec/06 ADR-52).</summary>
public sealed partial class EditorWindow
{
    /// <summary>A stable id for this editor while it is open, for the project argument of the tools.</summary>
    internal string McpId { get; } = Guid.NewGuid().ToString().ToUpperInvariant();

    internal EditorSession McpSession => session;

    internal EditorTools McpTools => tools;

    internal EditorSource McpSource => source;

    internal bool McpHasUnsavedChanges => hasUnsavedChanges;

    internal bool McpIsClosed => closed;

    internal ExportSource McpExportSource() => CurrentExportSource();

    internal void McpToast(string message) => ShowToast(message);

    internal void McpSeek(double timelineMs) => SeekTo(Math.Clamp(timelineMs, 0, session.DurationMs));

    internal void McpPause()
    {
        if (session.IsPlaying)
        {
            TogglePlayback();
        }
    }

    internal void McpPlay()
    {
        if (!session.IsPlaying)
        {
            TogglePlayback();
        }
    }

    /// <summary>Writes the project now, whether or not it changed.</summary>
    internal void McpSave()
    {
        hasUnsavedChanges = source.PackagePath is not null;
        SaveNow(waitForDisk: true);
    }

    /// <summary>Moves the package to the Recycle Bin without asking: agents were told destructive tools act at once.</summary>
    internal async Task McpDeleteProject()
    {
        if (source.PackagePath is not { } path)
        {
            throw new McpToolException("This project is not saved in a package.");
        }

        session.StartNewUndoStep();
        hasUnsavedChanges = false;
        saveTimer.Stop();
        AppSettings.Shared.RecentProjects.RemoveAll(item => string.Equals(item, path, StringComparison.OrdinalIgnoreCase));
        AppSettings.Shared.Save();
        Close();
        if (!await RecycleBin.SendAsync(path))
        {
            throw new McpToolException($"Could not move {path} to the Recycle Bin. Still in use: {string.Join(", ", RecycleBin.FilesInUse(path))}.");
        }
    }

    /// <summary>The editor's toast and preview follow an export an agent started.</summary>
    internal ExportSettings McpExportDefaults() => new()
    {
        Format = exportSettings.Format,
        Fps = exportSettings.Fps,
        ResolutionHeight = exportSettings.ResolutionHeight,
        Compression = exportSettings.Compression,
        Mp4Codec = exportSettings.Mp4Codec,
        ProResProfile = exportSettings.ProResProfile,
        GifHighQuality = exportSettings.GifHighQuality,
        GifDisableLoop = exportSettings.GifDisableLoop
    };
}
