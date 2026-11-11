using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>
/// What the MCP tools do with the recording bar. Every recording an agent starts goes through the bar and its countdown, so
/// the user always sees it (spec/06 ADR-52).
/// </summary>
public sealed partial class RecordingHudWindow
{
    private string? mcpLastError;

    internal static string McpState
    {
        get
        {
            if (shared is not { } hud)
            {
                return "idle";
            }

            if (hud.recorder is not null)
            {
                return hud.isPaused ? "paused" : "recording";
            }

            return hud.pending is not null ? "counting_down" : hud.pickingMode is not null ? "picking_target" : "idle";
        }
    }

    internal static string McpMode => shared?.target?.Mode.ToString().ToLowerInvariant() ?? shared?.pickingMode?.ToString().ToLowerInvariant() ?? "display";

    internal static double McpElapsedSeconds => shared?.recorder is not null ? shared.Elapsed().TotalSeconds : 0;

    internal static string? McpLastError => shared?.mcpLastError;

    internal static (string? CameraId, string? MicrophoneId, bool SystemAudio) McpChoices =>
        shared is { } hud ? (hud.camera?.Id, hud.microphone?.Id, hud.systemAudio) : (null, null, true);

    /// <summary>The target of a camera-only recording started by an agent.</summary>
    internal static CaptureTarget McpCameraTarget() => CameraTarget();

    /// <summary>Applies the agent's device choices as a click in the bar would, then starts the countdown.</summary>
    internal static void McpStart(CaptureTarget target, (bool Set, CaptureDeviceInfo? Device) camera, (bool Set, CaptureDeviceInfo? Device) microphone, bool? systemAudio, int? countdownSeconds)
    {
        shared ??= new RecordingHudWindow();
        var hud = shared;
        if (hud.recorder is not null || hud.pending is not null || hud.busy)
        {
            throw new McpToolException("A recording is already running. Use control_recording.");
        }

        if (camera.Set)
        {
            hud.camera = camera.Device;
        }

        if (microphone.Set)
        {
            hud.microphone = microphone.Device;
        }

        if (systemAudio is { } audio)
        {
            hud.systemAudio = audio;
            if (audio && !hud.systemAudioAllApps && hud.systemAudioApps.Count == 0)
            {
                hud.systemAudioAllApps = true;
            }
        }

        hud.mcpLastError = null;
        if (target.Mode == CaptureTargetMode.Camera)
        {
            if (hud.camera is null)
            {
                throw new McpToolException("A camera recording needs a camera: pass cameraId (from list_capture_targets).");
            }

            // The large preview stays up through the countdown and the recording, as when the mode is picked in the bar.
            if (hud.stage is null)
            {
                hud.ToggleCameraStage();
            }
        }

        hud.Reveal();
        hud.CancelPicking();
        hud.UpdateDevices();
        hud.BeginCountdown(target, countdownSeconds, fromAgent: true);
    }

    internal static async Task<string> McpPause(bool pause)
    {
        if (shared?.recorder is not { } || shared.busy)
        {
            throw new McpToolException("Nothing is being recorded.");
        }

        if (shared.isPaused != pause)
        {
            shared.TogglePause();
        }

        await Task.CompletedTask;
        return shared.isPaused ? "paused" : "recording";
    }

    /// <summary>Ends the countdown if one runs, then stops and opens the project. Returns its package.</summary>
    internal static async Task<string> McpStop()
    {
        if (shared is not { } hud)
        {
            throw new McpToolException("Nothing is being recorded.");
        }

        if (hud.pending is not null && hud.recorder is null)
        {
            hud.countdownTimer.Stop();
            await hud.StartRecording();
        }

        for (var wait = 0; wait < 40 && hud.recorder is null; wait++)
        {
            await Task.Delay(100);
        }

        if (hud.recorder is null || hud.package is not { } directory)
        {
            throw new McpToolException(hud.mcpLastError ?? "Nothing is being recorded.");
        }

        await hud.StopAndOpen();
        return directory;
    }

    internal static async Task McpRestart()
    {
        if (shared?.recorder is null)
        {
            throw new McpToolException("Nothing is being recorded.");
        }

        await shared.Restart();
    }

    /// <summary>Cancels the countdown, or deletes the recording in progress without the confirmation dialog.</summary>
    internal static async Task<string> McpCancel()
    {
        if (shared is not { } hud)
        {
            throw new McpToolException("Nothing is being recorded.");
        }

        if (hud.pending is not null && hud.recorder is null)
        {
            hud.CancelCountdown();
            return "countdown";
        }

        if (hud.recorder is null)
        {
            throw new McpToolException("Nothing is being recorded.");
        }

        await hud.AbortRecording();
        return "recording";
    }
}
