using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NativeScreen.Core;
using NativeScreen.Intelligence;
using NativeScreen.Media;
using Windows.Storage.Pickers;

namespace NativeScreen.App;

/// <summary>Editor actions that touch files or run long: pickers, assets, presets, scans and transcription.</summary>
internal sealed class EditorTools(Window window, EditorSession session, EditorSource source, Action<string> toast)
{
    private static readonly string[] ImageTypes = [".jpg", ".jpeg", ".png", ".bmp", ".webp"];
    private static readonly string[] AudioTypes = [".m4a", ".mp3", ".wav", ".aac", ".wma"];
    private const int ThumbnailLimit = 24;

    private CancellationTokenSource? transcriptCancel;
    private VoiceoverRecorder? voiceoverRecorder;
    private string? voiceoverRelativePath;
    private bool voiceoverBusy;
    private bool closing;

    /// <summary>Starts the preview if it is paused, and finishes when it is moving.</summary>
    public Func<Task>? StartPlayback { get; set; }

    /// <summary>Pauses the preview if it is playing.</summary>
    public Action? PausePlayback { get; set; }

    /// <summary>A long job moved on, so the inspector should redraw its status.</summary>
    public event Action? Changed;

    public bool HasPackage => source.PackagePath is not null;

    public string? PackagePath => source.PackagePath;

    /// <summary>The camera movie: the camera layer, or the main picture of a camera-only recording.</summary>
    public string? CameraPicturePath => WebcamPath;

    /// <summary>
    /// Turns on green screen keying with the backdrop color read from the top 12% of the camera picture at the playhead
    /// (spec/06 ADR-78). Keeps the current color when no frame can be read. One undo step.
    /// </summary>
    public async Task UseGreenScreen()
    {
        var color = await SampledBackdropColor(session.SourceAtPlayhead);
        session.Mutate(document =>
        {
            document.Camera.BackgroundRemoval = CameraBackgroundRemoval.GreenScreen;
            if (color is not null)
            {
                document.Camera.ChromaKeyColor = color;
            }
        });
    }

    /// <summary>The average color of the top strip of the camera picture at `sourceMs`, as `#RRGGBB`.</summary>
    public async Task<string?> SampledBackdropColor(double sourceMs)
    {
        if (CameraPicturePath is not { } path || !File.Exists(path))
        {
            return null;
        }

        try
        {
            return await Task.Run(() =>
            {
                using var reader = new VideoFileReader(path);
                if (MediaAssets.FrameAt(reader, sourceMs) is not { } frame || frame.Width <= 4 || frame.Height <= 4)
                {
                    return null;
                }

                var pixels = MediaAssets.ToBgra(frame);
                var rows = Math.Max(1, (int)(frame.Height * 0.12));
                long b = 0, g = 0, r = 0;
                for (var y = 0; y < rows; y++)
                {
                    for (var x = 0; x < frame.Width; x++)
                    {
                        var o = (y * frame.Width + x) * 4;
                        b += pixels[o];
                        g += pixels[o + 1];
                        r += pixels[o + 2];
                    }
                }

                var count = (long)rows * frame.Width;
                return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"#{r / count:X2}{g / count:X2}{b / count:X2}");
            });
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException or System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }
    public string? Status { get; private set; }
    public bool IsTranscribing { get; private set; }
    public bool IsScanningSensitive { get; private set; }
    public bool IsScanningFaces { get; private set; }
    public XamlRoot? XamlRoot { get; set; }

    // MARK: Camera effects

    private Task<FaceTrack?>? faceScan;
    private CancellationTokenSource? faceScanCancel;

    /// <summary>The face positions for stickers and face tracking; null until scanned or loaded.</summary>
    public FaceTrack? FaceTrack
    {
        get;
        private set
        {
            field = value;
            session.FaceTrack = value;
        }
    }

    /// <summary>0 to 1 while the webcam is being scanned, null otherwise.</summary>
    public double? FaceScanProgress { get; private set; }

    public bool FaceScanFoundNoFace => FaceTrack is { HasFaces: false };

    public PreviewPersonMasks PreviewMasks { get; } = new();


    public event Action? FaceTrackChanged;

    public event Action? FaceScanProgressChanged;

    // A camera-only picture is scanned for its face too: framing and zoom follow it (spec/06 ADR-77).
    private bool NeedsFaceTrack => (session.IsCameraOnly || session.HasRecordedCamera && session.Document.Camera.Enabled)
        && (session.Document.Camera.StickerId is not null || session.Document.Camera.EnableFaceTracking);

    private string? WebcamPath => source.PackagePath is { } package && (source.Project?.IsCameraOnly == true ? source.Project.Metadata.Tracks.DisplayVideo : source.Project?.Metadata.Tracks.WebcamVideo) is { } webcam
        ? Path.Combine(package, "recording", webcam)
        : null;

    /// <summary>Loads the saved face track, or scans the webcam once. Does nothing until a feature needs it.</summary>
    public void EnsureFaceTrack()
    {
        if (NeedsFaceTrack && FaceTrack is null && faceScan is null && WebcamPath is not null)
        {
            faceScan = RunFaceScan();
        }
    }

    /// <summary>The track an export should use, scanning first if a feature needs it. UI thread.</summary>
    public Task<FaceTrack?> WaitForFaceTrack()
    {
        EnsureFaceTrack();
        return faceScan ?? Task.FromResult(FaceTrack);
    }

    public void CancelFaceScan() => faceScanCancel?.Cancel();

    private async Task<FaceTrack?> RunFaceScan()
    {
        var webcam = WebcamPath!;
        var file = Path.Combine(source.PackagePath!, "assets", "face-track.json");
        faceScanCancel = new CancellationTokenSource();
        var cancel = faceScanCancel.Token;
        FaceScanProgress = 0;
        Changed?.Invoke();
        var progress = new Progress<double>(fraction =>
        {
            FaceScanProgress = fraction;
            FaceScanProgressChanged?.Invoke();
        });
        try
        {
            var stored = await Task.Run(
                () =>
                {
                    var loaded = LoadFaceTrack(file);
                    if (loaded is not null)
                    {
                        return loaded;
                    }

                    var scanned = FaceTrackScanner.Scan(webcam, progress, cancel);
                    if (scanned is not null)
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                        var partial = file + ".part";
                        File.WriteAllText(partial, System.Text.Json.JsonSerializer.Serialize(scanned));
                        File.Move(partial, file, overwrite: true);
                    }

                    return scanned;
                },
                cancel);
            FaceTrack = stored is null ? null : new FaceTrack(stored);
        }
        catch (Exception exception) when (exception is OperationCanceledException or IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException or System.Runtime.InteropServices.COMException or Microsoft.ML.OnnxRuntime.OnnxRuntimeException)
        {
            FaceTrack = null;
        }

        FaceScanProgress = null;
        faceScan = null;
        FaceTrackChanged?.Invoke();
        return FaceTrack;
    }

    private static StoredFaceTrack? LoadFaceTrack(string file)
    {
        try
        {
            return File.Exists(file) && System.Text.Json.JsonSerializer.Deserialize<StoredFaceTrack>(File.ReadAllText(file)) is { Version: 1 } stored ? stored : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>Copies an image into the package and uses it behind the person. A name marks a built-in image as selected.</summary>
    public async Task SelectCameraBackgroundImage(string file, string? name)
    {
        if (source.PackagePath is not { } package)
        {
            toast("Open a saved project first");
            return;
        }

        try
        {
            var relative = await Task.Run(() =>
            {
                // Named after the source bytes, so the same image reuses its file. Old files stay: undo can point at them.
                var fileName = CameraEffects.BackgroundFileName(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(file)));
                var assets = Path.Combine(package, "assets");
                Directory.CreateDirectory(assets);
                var target = Path.Combine(assets, fileName);
                if (!File.Exists(target))
                {
                    var image = NativeScreen.Rendering.ImageTexture.Load(file, 2560);
                    var partial = target + ".part.jpg";
                    NativeScreen.Rendering.ImageTexture.Save(image.Pixels, image.Width, image.Height, partial, jpeg: true, jpegQuality: 0.90f);
                    File.Move(partial, target, overwrite: true);
                }

                return "assets/" + fileName;
            });
            session.Mutate(document =>
            {
                document.Camera.BackgroundMode = CameraBackgroundMode.Image;
                document.Camera.BackgroundImagePath = relative;
                document.Camera.BackgroundImageName = name;
            });
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException or System.Runtime.InteropServices.COMException)
        {
            toast($"Could not use this image: {exception.Message}");
        }
    }

    /// <summary>
    /// Asks for a picture and copies it into `assets/<folder>/<UUID>.<ext>` of the package. Returns the package-relative path,
    /// or null when cancelled or the copy failed. A replaced file is never deleted, so undo can bring it back.
    /// </summary>
    public async Task<string?> PickImageIntoPackage(string folder)
    {
        if (source.PackagePath is not { } package)
        {
            return null;
        }

        var picker = new FileOpenPicker();
        foreach (var type in ImageTypes)
        {
            picker.FileTypeFilter.Add(type);
        }

        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        if (await picker.PickSingleFileAsync() is not { } file)
        {
            return null;
        }

        var extension = Path.GetExtension(file.Path).TrimStart('.').ToLowerInvariant();
        var name = Guid.NewGuid().ToString().ToUpperInvariant() + "." + (extension.Length == 0 ? "png" : extension);
        var relative = $"assets/{folder}/{name}";
        try
        {
            await Task.Run(() =>
            {
                Directory.CreateDirectory(Path.Combine(package, "assets", folder));
                File.Copy(file.Path, Path.Combine(package, "assets", folder, name));
            });
            return relative;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            toast("Could not copy the image");
            return null;
        }
    }

    /// <summary>A custom arrow or hand picture, copied into `assets/cursors/` (spec/02 Custom cursors).</summary>
    public async Task SetCustomCursor(bool hand)
    {
        if (await PickImageIntoPackage("cursors") is not { } path)
        {
            return;
        }

        var image = new CustomCursorImage { ImagePath = path, Hotspot01 = hand ? new Point01(0.45, 0.05) : new Point01(0, 0) };
        session.Mutate(document =>
        {
            if (hand)
            {
                document.Cursor.CustomHand = image;
            }
            else
            {
                document.Cursor.CustomPointer = image;
            }
        });
    }

    public async Task ChooseCameraBackgroundImage()
    {
        var picker = new FileOpenPicker();
        foreach (var type in ImageTypes)
        {
            picker.FileTypeFilter.Add(type);
        }

        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        if (await picker.PickSingleFileAsync() is { } file)
        {
            await SelectCameraBackgroundImage(file.Path, null);
        }
    }

    /// <summary>Runs only when the person pressed Download. Progress and Cancel are shown where the button was.</summary>
    public async Task DownloadModel(DownloadableModel model)
    {
        var (installed, error) = await ModelDownloads.Download(model);
        if (error is not null)
        {
            toast(Loc.F("Download failed: %@", error));
        }
        else if (!installed)
        {
            toast("Download cancelled");
        }
        else if (model == DownloadableModel.Person)
        {
            // The camera background and cutout can now separate the person.
            FaceTrackChanged?.Invoke();
        }
    }

    /// <summary>Removes a downloaded model; it is downloaded again when needed.</summary>
    public void DeleteModel(DownloadableModel model)
    {
        if (ModelDownloads.Delete(model) is not null)
        {
            toast("The model is in use and could not be deleted.");
        }
        else if (model == DownloadableModel.Person)
        {
            FaceTrackChanged?.Invoke();
        }
    }

    public static string PresetsDirectory { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NativeScreen", "Presets");

    public ProjectPresetStore Presets { get; } = new(PresetsDirectory);

    public static IReadOnlyList<WallpaperItem> SystemWallpapers()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Web", "Wallpaper");
        return Directory.Exists(root)
            ? Directory.EnumerateFiles(root, "*.jpg", SearchOption.AllDirectories)
                .Take(ThumbnailLimit)
                .Select(file => new WallpaperItem(Path.GetFileNameWithoutExtension(file), file, file, false))
                .ToList()
            : [];
    }

    // MARK: Pickers

    public async Task<string?> PickFile(params string[] types)
    {
        var picker = new FileOpenPicker();
        foreach (var type in types)
        {
            picker.FileTypeFilter.Add(type);
        }

        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        return (await picker.PickSingleFileAsync())?.Path;
    }

    public async Task<string?> PickSave(string suggestedName, string title, string extension)
    {
        title = Loc.T(title);
        var picker = new FileSavePicker { SuggestedFileName = suggestedName };
        picker.FileTypeChoices.Add(title, new List<string> { extension });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        return (await picker.PickSaveFileAsync())?.Path;
    }

    private string? CopyToAssets(string file, string name)
    {
        if (source.PackagePath is not { } package)
        {
            toast("Open a saved project first");
            return null;
        }

        var assets = Path.Combine(package, "assets");
        Directory.CreateDirectory(assets);
        File.Copy(file, Path.Combine(assets, name), overwrite: true);
        return "assets/" + name;
    }

    // MARK: Background

    public async void PickBackgroundImage()
    {
        if (await PickFile(ImageTypes) is { } file)
        {
            var relative = CopyToAssets(file, $"custom-bg-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}{Path.GetExtension(file).ToLowerInvariant()}");
            if (relative is not null)
            {
                session.Mutate(document =>
                {
                    document.Background.Type = BackgroundType.Image;
                    document.Background.WallpaperRelativePath = relative;
                });
            }
        }
    }

    /// <summary>Copied byte for byte, so a project stores the same file whichever platform picked a bundled wallpaper.</summary>
    public void SelectWallpaper(WallpaperItem item)
    {
        var name = $"background-{item.Id}{Path.GetExtension(item.FullImagePath).ToLowerInvariant()}";
        var alreadyCopied = source.PackagePath is { } package && File.Exists(Path.Combine(package, "assets", name));
        var relative = alreadyCopied ? "assets/" + name : CopyToAssets(item.FullImagePath, name);
        if (relative is not null)
        {
            session.Mutate(document =>
            {
                document.Background.Type = BackgroundType.Wallpaper;
                document.Background.SystemWallpaperName = item.Id;
                document.Background.WallpaperRelativePath = relative;
            });
        }
    }

    // MARK: Audio

    public async void AddBackgroundAudio()
    {
        if (await PickFile(AudioTypes) is { } file)
        {
            var relative = CopyToAssets(file, "bg-" + Path.GetFileName(file));
            if (relative is not null)
            {
                session.Mutate(document =>
                {
                    document.Audio.BackgroundMusic.RelativePath = relative;
                    document.Audio.BackgroundMusic.Muted = false;
                });
                toast("Background audio file added");
            }
        }
    }

    /// <summary>
    /// Starts a recording, or finishes the one running. The microphone opens before the preview moves, and the file starts when
    /// the preview does, so the take lines up with what was on screen (spec/06 ADR-40).
    /// </summary>
    public async void ToggleVoiceoverRecording()
    {
        if (voiceoverBusy)
        {
            return;
        }

        voiceoverBusy = true;
        try
        {
            if (voiceoverRecorder is null)
            {
                await StartVoiceoverRecording();
            }
            else
            {
                await StopVoiceoverRecording();
            }
        }
        finally
        {
            voiceoverBusy = false;
        }
    }

    private async Task StartVoiceoverRecording()
    {
        if (source.PackagePath is not { } package)
        {
            toast("Open a saved project first");
            return;
        }

        var name = $"voiceover-{EditorSession.NewId()}.m4a";
        var path = Path.Combine(package, "assets", name);
        var recorder = await Task.Run(() =>
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            return VoiceoverRecorder.TryStart(path);
        });
        if (recorder is null)
        {
            toast("Could not start microphone voiceover recording");
            return;
        }

        if (StartPlayback is { } start)
        {
            await start();
        }

        if (closing)
        {
            _ = Task.Run(() => FinishRecorder(recorder, 0));
            return;
        }

        recorder.MarkStart();
        voiceoverRecorder = recorder;
        voiceoverRelativePath = "assets/" + name;
        session.BeginVoiceoverRecording();
        toast("Recording voiceover... Click again to finish");
    }

    private async Task StopVoiceoverRecording()
    {
        var (recorder, relative, recordedMs) = TakeRecording();
        PausePlayback?.Invoke();
        session.EndVoiceoverRecording();
        var finished = await Task.Run(() => FinishRecorder(recorder, recordedMs));
        if (finished)
        {
            session.AddRecordedVoiceover(relative, recordedMs);
            toast("Voiceover added");
        }
        else
        {
            toast("Could not finish the voiceover recording");
        }
    }

    /// <summary>The window is closing. A take still running is kept: the segment goes in now, so the final save includes it.</summary>
    public void FinishVoiceoverRecordingForClose()
    {
        closing = true;
        if (voiceoverRecorder is null)
        {
            return;
        }

        var (recorder, relative, recordedMs) = TakeRecording();
        session.EndVoiceoverRecording();
        session.AddRecordedVoiceover(relative, recordedMs);
        _ = Task.Run(() => FinishRecorder(recorder, recordedMs));
    }

    private (VoiceoverRecorder Recorder, string Relative, double RecordedMs) TakeRecording()
    {
        var recorder = voiceoverRecorder!;
        var relative = voiceoverRelativePath!;
        voiceoverRecorder = null;
        voiceoverRelativePath = null;
        return (recorder, relative, recorder.ElapsedMs);
    }

    private static bool FinishRecorder(VoiceoverRecorder recorder, double recordedMs)
    {
        try
        {
            recorder.Stop(recordedMs);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            return false;
        }
        finally
        {
            try
            {
                recorder.Dispose();
            }
            catch (Exception exception) when (exception is System.Runtime.InteropServices.COMException or InvalidOperationException)
            {
                // The device went away; there is nothing left to release.
            }
        }
    }

    public async void UploadVoiceover()
    {
        if (await PickFile(AudioTypes) is not { } file)
        {
            return;
        }

        var relative = CopyToAssets(file, $"voiceover-{Guid.NewGuid():N}{Path.GetExtension(file).ToLowerInvariant()}");
        if (relative is null)
        {
            return;
        }

        var start = Math.Max(0, Math.Min(session.SourceDurationMs - 400, session.SourceAtPlayhead));
        var length = await Task.Run(() => AudioLengthMs(file));
        var segment = new VoiceoverSegment
        {
            Id = EditorSession.NewId(),
            SourceStartMs = start,
            DurationMs = Math.Min(Math.Max(500, length), Math.Max(400, session.SourceDurationMs - start)),
            RelativePath = relative
        };
        session.Mutate(document =>
        {
            segment.TrackIndex = VoiceoverTrackLayout.FirstFreeTrack(document.Timeline.Voiceovers, segment.SourceStartMs, segment.SourceEndMs);
            VoiceoverTrackLayout.SetTrackHidden(document.Timeline, segment.TrackIndex, false);
            document.Timeline.Voiceovers.Add(segment);
            VoiceoverTrackLayout.Normalize(document.Timeline);
        });
        toast("Voiceover added");
    }

    private static double AudioLengthMs(string file)
    {
        using var reader = AudioFileReader.TryOpen(file);
        if (reader is null)
        {
            return 3000;
        }

        var samples = 0L;
        while (reader.ReadBlock() is { } block)
        {
            samples += block.Samples.Length / reader.Channels;
        }

        return samples * 1000.0 / reader.SampleRate;
    }

    // MARK: Masks

    private string? VideoPath => source.PackagePath is { } package && source.Project is { } project
        ? Path.Combine(package, "recording", project.Metadata.Tracks.DisplayVideo)
        : null;

    private readonly ClickSounds previewSounds = new();
    private Windows.Media.Playback.MediaPlayer? musicPreview;

    public string? LoadingTrack { get; private set; }

    public bool IsPreviewingMusic => musicPreview is not null;

    public bool IsHoveringBackgroundDrop { get; set; }

    /// <summary>Picking the selected track again clears it. A new one is made if needed, then previews.</summary>
    public async void SelectBuiltInTrack(string track)
    {
        StopMusicPreview();
        if (session.Document.Audio.BackgroundMusic.RelativePath == track)
        {
            session.Mutate(document => document.Audio.BackgroundMusic.RelativePath = null);
            return;
        }

        session.Mutate(document =>
        {
            document.Audio.BackgroundMusic.RelativePath = track;
            document.Audio.BackgroundMusic.Muted = false;
        });
        LoadingTrack = track;
        Changed?.Invoke();
        await Task.Run(() => BuiltInBackgroundMusic.EnsureTrack(track));
        LoadingTrack = null;
        if (session.Document.Audio.BackgroundMusic.RelativePath == track && !session.IsPlaying)
        {
            ToggleMusicPreview();
        }

        Changed?.Invoke();
    }

    public void ToggleMusicPreview()
    {
        if (musicPreview is not null)
        {
            StopMusicPreview();
        }
        else if (BuiltInBackgroundMusic.ResolvePath(source.PackagePath, session.Document.Audio.BackgroundMusic.RelativePath) is { } file)
        {
            musicPreview = new Windows.Media.Playback.MediaPlayer
            {
                Source = Windows.Media.Core.MediaSource.CreateFromUri(new Uri(file)),
                IsLoopingEnabled = true,
                Volume = Math.Clamp(session.Document.Audio.BackgroundMusic.Volume * 2.5, 0.05, 1)
            };
            musicPreview.Play();
        }

        Changed?.Invoke();
    }

    /// <summary>The editor closed: nothing may keep playing after the window is gone.</summary>
    public void Dispose()
    {
        PreviewMasks.Dispose();
        StopMusicPreview();
        previewSounds.Dispose();
    }

    public void StopMusicPreview()
    {
        musicPreview?.Dispose();
        musicPreview = null;
    }

    /// <summary>Copies an image into the project and makes it the background.</summary>
    public void SetBackgroundImage(string file)
    {
        if (CopyToAssets(file, $"custom-bg-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}{Path.GetExtension(file)}") is { } relative)
        {
            session.Mutate(document =>
            {
                document.Background.Type = BackgroundType.Image;
                document.Background.WallpaperRelativePath = relative;
            });
        }
    }

    public async Task PasteBackgroundImage()
    {
        var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
        if (!content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Bitmap))
        {
            toast("The clipboard has no image");
            return;
        }

        var reference = await content.GetBitmapAsync();
        using var input = await reference.OpenReadAsync();
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(input);
        using var bitmap = await decoder.GetSoftwareBitmapAsync();
        var temporary = Path.Combine(Directory.CreateTempSubdirectory("ns-paste-").FullName, "pasted.png");
        using (var output = File.Create(temporary))
        {
            var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(output));
            encoder.SetSoftwareBitmap(Windows.Graphics.Imaging.SoftwareBitmap.Convert(bitmap, Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied));
            await encoder.FlushAsync();
        }

        SetBackgroundImage(temporary);
    }


    public void PreviewClickSound() => previewSounds.Play(session.Document.Cursor.ClickEffect.SoundSet, session.Document.Cursor.ClickEffect.SoundVolume);

    public async void LoadLutFile()
    {
        if (await PickFile(".cube") is not { } file)
        {
            return;
        }

        if (CubeLut.TryParse(await File.ReadAllTextAsync(file)) is null)
        {
            toast("This file is not a 3D LUT");
            return;
        }

        // In the package, so the project stays portable.
        if (CopyToAssets(file, "lut-" + Path.GetFileName(file)) is { } relative)
        {
            session.Mutate(document =>
            {
                document.Camera.CustomLutRelativePath = relative;
                document.Camera.SelectedCustomColorPresetId = null;
            });
        }
    }

    /// <summary>Name and four sliders; the new preset goes on the project and is selected.</summary>
    public async Task CreateColorPreset()
    {
        var name = new TextBox { Text = Loc.T("My preset") };
        var panel = new StackPanel { Spacing = 10, Width = 340 };
        panel.Children.Add(new TextBlock { Text = Loc.T("Preset name") });
        panel.Children.Add(name);
        Slider Row(string title, double minimum, double maximum, double value)
        {
            var slider = new Slider { Minimum = minimum, Maximum = maximum, StepFrequency = 0.01, Value = value };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(slider, title);
            panel.Children.Add(new TextBlock { Text = title });
            panel.Children.Add(slider);
            return slider;
        }

        var warmth = Row("Warmth", -1, 1, 0);
        var pop = Row("Background pop", 0, 1, 0.2);
        var contrast = Row("Contrast", -1, 1, 0.25);
        var intensity = Row("Color intensity", -1, 1, 0.2);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = AppTheme.Current, Title = Loc.T("Color preset studio"), Content = panel, PrimaryButtonText = Loc.T("Create preset"), CloseButtonText = Loc.T("Cancel"), DefaultButton = ContentDialogButton.Primary };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            var preset = new CustomCameraColorPreset
            {
                Id = EditorSession.NewId(),
                Name = name.Text.Trim().Length == 0 ? "My preset" : name.Text.Trim(),
                Warmth = warmth.Value,
                BackgroundPop = pop.Value,
                Contrast = contrast.Value,
                ColorIntensity = intensity.Value
            };
            session.Mutate(document =>
            {
                document.Camera.CustomColorPresets.Add(preset);
                document.Camera.SelectedCustomColorPresetId = preset.Id;
                document.Camera.CustomLutRelativePath = null;
            });
        }
    }

    /// <summary>One frame of the recording as BGRA, off the UI thread, for thumbnails.</summary>
    public async Task<(byte[] Bgra, int Width, int Height)?> ReadFrame(double sourceMs)
    {
        if (VideoPath is not { } path || !File.Exists(path))
        {
            return null;
        }

        return await Task.Run<(byte[] Bgra, int Width, int Height)?>(() =>
        {
            using var reader = new VideoFileReader(path);
            return MediaAssets.FrameAt(reader, sourceMs) is { } frame ? (MediaAssets.ToBgra(frame), frame.Width, frame.Height) : null;
        });
    }

    public void SetHideSensitive(bool enabled)
    {
        session.Mutate(document =>
        {
            document.Background.HideSensitiveData = enabled;
            if (!enabled)
            {
                AutoMaskBuilder.Replace(document, item => item.IsAutoSensitiveMask, []);
            }
        });
        if (enabled)
        {
            _ = ScanSensitive();
        }
    }

    public void SetSensitivePhrases(string text)
    {
        var phrases = text.Split(',').Select(item => item.Trim()).Where(item => item.Length > 0).ToList();
        session.Mutate(document => document.Background.SensitiveDataCustomPhrases = phrases);
        if (session.Document.Background.HideSensitiveData)
        {
            _ = ScanSensitive();
        }
    }

    private async Task ScanSensitive()
    {
        if (IsScanningSensitive || VideoPath is not { } path)
        {
            return;
        }

        IsScanningSensitive = true;
        Report("Scanning for sensitive data...");
        try
        {
            var phrases = session.Document.Background.SensitiveDataCustomPhrases;
            var found = await OnDeviceMaskScanner.DetectSensitiveAsync(path, session.SourceDurationMs, phrases, null, CancellationToken.None);
            if (found is null)
            {
                toast("Windows has no text recognition language installed");
            }
            else if (session.Document.Background.HideSensitiveData)
            {
                session.Mutate(document => AutoMaskBuilder.Replace(document, item => item.IsAutoSensitiveMask, found));
                toast(found.Count == 0 ? "No sensitive data found" : $"Hid {found.Count} sensitive areas");
            }
        }
        catch (Exception exception) when (exception is IOException or SharpGen.Runtime.SharpGenException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            toast($"Scan failed: {exception.Message}");
        }

        IsScanningSensitive = false;
        Report(null);
    }

    public void SetHideFaces(bool enabled)
    {
        session.Mutate(document =>
        {
            document.Background.HideFaces = enabled;
            if (!enabled)
            {
                AutoMaskBuilder.Replace(document, item => item.IsAutoFaceMask, []);
            }
        });
        if (enabled)
        {
            _ = ScanFaces();
        }
    }

    private async Task ScanFaces()
    {
        if (IsScanningFaces || VideoPath is not { } path)
        {
            return;
        }

        IsScanningFaces = true;
        Report("Scanning for faces...");
        try
        {
            var found = await OnDeviceMaskScanner.DetectFacesAsync(path, session.SourceDurationMs, null, CancellationToken.None);
            if (session.Document.Background.HideFaces)
            {
                session.Mutate(document => AutoMaskBuilder.Replace(document, item => item.IsAutoFaceMask, found));
                toast(found.Count == 0 ? "No faces found" : $"Hid {found.Count} faces");
            }
        }
        catch (Exception exception) when (exception is IOException or SharpGen.Runtime.SharpGenException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            toast($"Scan failed: {exception.Message}");
        }

        IsScanningFaces = false;
        Report(null);
    }

    // MARK: Transcript

    public void CancelTranscript() => transcriptCancel?.Cancel();

    /// <summary>The model downloads only after the person agreed in this dialog.</summary>
    public async void GenerateTranscript()
    {
        if (IsTranscribing || source.PackagePath is not { } package || source.Project is not { } project)
        {
            if (source.PackagePath is null)
            {
                toast("Open a recording first");
            }

            return;
        }

        var tracks = project.Metadata.Tracks;
        var audioPath = Path.Combine(package, "recording", tracks.MicrophoneAudio ?? tracks.SystemAudio ?? tracks.DisplayVideo);
        var model = WhisperModel.ForTier(session.Document.Captions.WhisperModelTier);
        using var cancel = new CancellationTokenSource();
        transcriptCancel = cancel;
        IsTranscribing = true;
        try
        {
            if (!model.IsInstalled)
            {
                var answer = await new ContentDialog
                {
                    XamlRoot = XamlRoot,
                    RequestedTheme = AppTheme.Current,
                    Title = Loc.T("Download the speech model?"),
                    Content = $"Transcripts run on this device with the Whisper {model.Tier} model. It downloads {model.SizeText} from huggingface.co once. Your audio is never uploaded.",
                    PrimaryButtonText = Loc.T("Download"),
                    CloseButtonText = Loc.T("Not now")
                }.ShowAsync();
                if (answer != ContentDialogResult.Primary)
                {
                    return;
                }

                // Shown with Cancel next to the Model choice; Stop cancels it too.
                var speech = DownloadableModel.Speech(model);
                Report("Downloading the speech model");
                (bool Installed, string? Error) downloaded;
                using (cancel.Token.Register(() => ModelDownloads.Cancel(speech)))
                {
                    downloaded = await ModelDownloads.Download(speech);
                }

                if (!downloaded.Installed)
                {
                    toast(downloaded.Error is { } reason ? Loc.F("Download failed: %@", reason) : "Download cancelled");
                    return;
                }
            }

            Report("Transcribing...");
            var document = session.Document;
            var segments = await WhisperTranscriber.TranscribeAsync(
                audioPath,
                model,
                document.Captions.TranscriptLocale,
                document.Captions.CustomPrompt,
                session.SourceDurationMs,
                new Progress<double>(share => Report($"Transcribing • {share:P0}")),
                cancel.Token);
            session.SelectCaption(null);
            var duration = session.SourceDurationMs;
            session.Mutate(next =>
            {
                // A model can place words past the end of the audio, where no frame would ever show them.
                next.Captions.Segments = segments.Where(word => word.SourceStartMs < duration).ToList();
                next.Captions.RebuildTranscriptCaptionBlocks();
                next.Captions.Enabled = true;
            });
            toast(segments.Count == 0 ? "No speech found" : $"Transcribed {segments.Count} words");
        }
        catch (OperationCanceledException)
        {
            toast("Transcript stopped");
        }
        catch (Exception exception) when (exception is IOException or HttpRequestException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException or InvalidOperationException or Whisper.net.Wave.CorruptedWaveException)
        {
            toast($"Transcript failed: {exception.Message}");
        }
        finally
        {
            transcriptCancel = null;
            IsTranscribing = false;
            Report(null);
        }
    }

    public async void ExportSrt()
    {
        var text = TranscriptEditing.FormatSrt(session.Document.Captions.Segments, session.Mapper);
        if (text.Length == 0)
        {
            toast("Generate a transcript first");
        }
        else if (await PickSave(session.Document.Name, "SubRip subtitles", ".srt") is { } path)
        {
            await File.WriteAllTextAsync(path, text);
            toast($"Exported {Path.GetFileName(path)}");
        }
    }

    private void Report(string? status)
    {
        Status = status;
        Changed?.Invoke();
    }
}
