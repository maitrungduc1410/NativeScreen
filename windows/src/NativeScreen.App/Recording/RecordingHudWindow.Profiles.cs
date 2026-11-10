using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>Speaker notes and recording profiles in the recording bar's options (spec/06 ADR-76).</summary>
public sealed partial class RecordingHudWindow
{
    private SpeakerNotesWindow? notes;

    /// <summary>The options menu entries for the notes and the profiles.</summary>
    private void AddNotesAndProfiles(MenuFlyout menu)
    {
        var settings = AppSettings.Shared;
        var showNotes = new ToggleMenuFlyoutItem { Text = Loc.T("Speaker Notes"), IsChecked = notes is not null };
        showNotes.Click += (_, _) => SetSpeakerNotes(showNotes.IsChecked);
        menu.Items.Add(showNotes);
        menu.Items.Add(new MenuFlyoutSeparator());
        var profiles = new MenuFlyoutSubItem { Text = Loc.T("Profiles") };
        foreach (var profile in settings.RecordingProfiles)
        {
            var chosen = profile;
            var item = new ToggleMenuFlyoutItem { Text = profile.Name, IsChecked = Matches(profile) };
            item.Click += (_, _) => ApplyProfile(chosen);
            profiles.Items.Add(item);
        }

        if (settings.RecordingProfiles.Count > 0)
        {
            profiles.Items.Add(new MenuFlyoutSeparator());
        }

        var save = new MenuFlyoutItem { Text = Loc.T("Save Current Settings as Profile...") };
        save.Click += (_, _) => _ = SaveProfile();
        profiles.Items.Add(save);
        if (settings.RecordingProfiles.Count > 0)
        {
            var delete = new MenuFlyoutSubItem { Text = Loc.T("Delete Profile") };
            foreach (var profile in settings.RecordingProfiles)
            {
                var chosen = profile;
                var item = new MenuFlyoutItem { Text = profile.Name };
                item.Click += (_, _) =>
                {
                    settings.RecordingProfiles.Remove(chosen);
                    settings.Save();
                };
                delete.Items.Add(item);
            }

            profiles.Items.Add(delete);
        }

        menu.Items.Add(profiles);
    }

    private void SetSpeakerNotes(bool on)
    {
        AppSettings.Shared.ShowSpeakerNotes = on;
        AppSettings.Shared.Save();
        if (on && notes is null)
        {
            notes = new SpeakerNotesWindow();
            notes.Closed += (_, _) =>
            {
                // Closing the window turns the option off.
                notes = null;
                AppSettings.Shared.ShowSpeakerNotes = false;
                AppSettings.Shared.Save();
            };
            notes.Activate();
            if (recorder is not null)
            {
                notes.RecordingStarted();
            }

            DockNotes();
        }
        else if (!on && notes is not null)
        {
            var window = notes;
            notes = null;
            window.Close();
        }
    }

    /// <summary>While the Camera mode is open, the notes sit at the top center under the camera with the preview below them.</summary>
    private void DockNotes()
    {
        if (notes is null)
        {
            return;
        }

        if (stage is null)
        {
            notes.DockUnderCamera(null);
            return;
        }

        var area = Microsoft.UI.Windowing.DisplayArea.Primary.WorkArea;
        var width = stage.AppWindow.Size.Width;
        var height = (int)(width * 0.28);
        var left = area.X + (area.Width - width) / 2;
        notes.DockUnderCamera(new Windows.Graphics.RectInt32(left, area.Y, width, height));
        stage.AppWindow.Move(new Windows.Graphics.PointInt32(left, area.Y + height + 8));
    }

    private CaptureTargetMode CurrentMode => stage is not null ? CaptureTargetMode.Camera : pickingMode ?? CaptureTargetMode.Display;

    private RecordingProfile CurrentProfile(string name) => new()
    {
        Name = name,
        Mode = McpDocument.Name(CurrentMode),
        CameraId = camera?.Id,
        CameraName = camera?.Name,
        ShowCameraPreview = showCameraPreview,
        CameraMaxHeight = cameraMaxHeight,
        CaptureMicrophone = microphone is not null,
        MicrophoneId = microphone?.Id,
        MicrophoneName = microphone?.Name,
        CaptureSystemAudio = systemAudio,
        SystemAudioFromAllApps = systemAudioAllApps,
        SystemAudioApps = [.. systemAudioApps],
        CountdownSeconds = AppSettings.Shared.CountdownSeconds,
        HighlightRecordedArea = AppSettings.Shared.HighlightRecordedArea,
        ShowSpeakerNotes = notes is not null
    };

    /// <summary>Whether the bar is set up as `profile`; a device that is not connected is ignored.</summary>
    private bool Matches(RecordingProfile profile)
    {
        var cameras = WebcamRecorder.Cameras();
        var microphones = AudioTrackRecorder.Microphones();
        var cameraMatches = profile.CameraId is null ? camera is null : !cameras.Any(item => item.Id == profile.CameraId) || camera?.Id == profile.CameraId;
        var microphoneMatches = !profile.CaptureMicrophone ? microphone is null : !microphones.Any(item => item.Id == profile.MicrophoneId) || microphone?.Id == profile.MicrophoneId;
        return cameraMatches
            && microphoneMatches
            && profile.CaptureSystemAudio == systemAudio
            && profile.CountdownSeconds == AppSettings.Shared.CountdownSeconds
            && profile.HighlightRecordedArea == AppSettings.Shared.HighlightRecordedArea
            && profile.ShowSpeakerNotes == (notes is not null);
    }

    private void ApplyProfile(RecordingProfile profile)
    {
        var cameras = WebcamRecorder.Cameras();
        var microphones = AudioTrackRecorder.Microphones();
        if (profile.CameraId is null)
        {
            camera = null;
        }
        else if (cameras.FirstOrDefault(item => item.Id == profile.CameraId) is { } connected)
        {
            camera = connected;
        }

        if (!profile.CaptureMicrophone)
        {
            microphone = null;
        }
        else if (microphones.FirstOrDefault(item => item.Id == profile.MicrophoneId) is { } connected)
        {
            microphone = connected;
        }

        showCameraPreview = profile.ShowCameraPreview;
        cameraMaxHeight = profile.CameraMaxHeight;
        systemAudio = profile.CaptureSystemAudio;
        systemAudioAllApps = profile.SystemAudioFromAllApps;
        systemAudioApps.Clear();
        systemAudioApps.UnionWith(profile.SystemAudioApps);
        AppSettings.Shared.CountdownSeconds = profile.CountdownSeconds;
        AppSettings.Shared.HighlightRecordedArea = profile.HighlightRecordedArea;
        AppSettings.Shared.Save();
        SetSpeakerNotes(profile.ShowSpeakerNotes);
        // A window cannot be saved, so a profile keeps the mode only; the Camera mode opens its preview.
        if (profile.Mode == "camera" && stage is null && recorder is null && pending is null)
        {
            ToggleCameraStage();
        }
        else if (profile.Mode != "camera" && stage is not null && recorder is null)
        {
            CloseCameraStage();
        }

        ShowIdle();
        UpdateDevices();
    }

    private async Task SaveProfile()
    {
        var name = new TextBox { PlaceholderText = Loc.T("Profile name") };
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot,
            RequestedTheme = ElementTheme.Dark,
            Title = Loc.T("Save Profile"),
            Content = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new TextBlock { Text = Loc.T("A profile keeps the capture mode, camera, microphone, system audio and recording options, so you can switch setups in one click."), TextWrapping = TextWrapping.Wrap },
                    name
                }
            },
            PrimaryButtonText = Loc.T("Save"),
            CloseButtonText = Loc.T("Cancel")
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && name.Text.Trim() is { Length: > 0 } chosen)
        {
            AppSettings.Shared.RecordingProfiles.Add(CurrentProfile(chosen));
            AppSettings.Shared.Save();
        }
    }
}
