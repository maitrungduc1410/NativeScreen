//! NativeScreen for Linux: records the screen into a `.nativescreen` package (spec/02) on Wayland
//! compositors with a ScreenCast portal (Umbriel, and others).
//!
//! The recorder runs in the foreground until it gets SIGINT/SIGTERM or `nativescreen stop`. Its state is
//! published in `$XDG_RUNTIME_DIR/nativescreen/status.json` for shells (the Noctalia plugin reads it).

mod autozoom;
mod bundle;
mod capture;
mod cursor_kind;
mod encoder;
mod input;
mod session;
mod status;
mod telemetry;

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use tokio::signal::unix::{SignalKind, signal};

use status::{Status, StatusFile};

const USAGE: &str = "\
nativescreen: screen recorder for NativeScreen projects (.nativescreen)

Usage:
  nativescreen record [options]   record until stopped (SIGINT/SIGTERM or `nativescreen stop`)
  nativescreen stop               stop the running recording and wait until the package is written
  nativescreen toggle [options]   stop if recording, else record
  nativescreen status             print the recorder state as JSON

Record options:
  --dir <path>          where packages go (default: ~/Videos/NativeScreen)
  --pick                show the portal picker again instead of reusing the last screen
  --window              allow picking a single window too
  --mic                 also record the default microphone (recording/microphone.m4a)
  --no-system-audio     do not record what the speakers play
  --no-input            do not read clicks and keys from /dev/input
  --typed-keys          store which plain keys were typed, not only that typing happened
  --no-auto-zoom        do not create zooms from clicks
  --quality <0-51>      encoder quantizer, lower is better (default 20)
";

struct RecordArgs {
    dir: PathBuf,
    pick: bool,
    window: bool,
    mic: bool,
    system_audio: bool,
    input: bool,
    typed_keys: bool,
    auto_zoom: bool,
    quality: u32,
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn expand(path: &str) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => home().join(rest),
        None => PathBuf::from(path),
    }
}

fn parse_record(args: &[String]) -> Result<RecordArgs> {
    let videos = std::env::var_os("XDG_VIDEOS_DIR").map(PathBuf::from).unwrap_or_else(|| home().join("Videos"));
    let mut out = RecordArgs {
        dir: videos.join("NativeScreen"),
        pick: false,
        window: false,
        mic: false,
        system_audio: true,
        input: true,
        typed_keys: false,
        auto_zoom: true,
        quality: 20,
    };
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--dir" => out.dir = expand(it.next().ok_or_else(|| anyhow!("--dir needs a path"))?),
            "--pick" => out.pick = true,
            "--window" => out.window = true,
            "--mic" => out.mic = true,
            "--no-system-audio" => out.system_audio = false,
            "--no-input" => out.input = false,
            "--typed-keys" => out.typed_keys = true,
            "--no-auto-zoom" => out.auto_zoom = false,
            "--quality" => {
                out.quality = it.next().ok_or_else(|| anyhow!("--quality needs a number"))?.parse::<u32>()?.min(51);
            }
            other => bail!("unknown option {other}\n\n{USAGE}"),
        }
    }
    Ok(out)
}

/// VA-API driver to pin on a hybrid machine: the first non-NVIDIA render node (ADR-98). Loading the
/// GStreamer VA plugin initializes the driver of every render node; with `libva-nvidia-driver` installed
/// that starts CUDA on the discrete GPU, waking it from runtime suspend (~3 s, and battery) although
/// encoding runs on the integrated GPU.
fn libva_driver_for(vendors: &[u16]) -> Option<&'static str> {
    const NVIDIA: u16 = 0x10de;
    if !vendors.contains(&NVIDIA) {
        return None;
    }
    vendors.iter().find_map(|v| match *v {
        0x1002 => Some("radeonsi"),
        0x8086 => Some("iHD"),
        _ => None,
    })
}

/// Vendor ids of `/dev/dri/renderD*`, in node order.
fn render_node_vendors() -> Vec<u16> {
    let mut nodes: Vec<_> = std::fs::read_dir("/sys/class/drm")
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("renderD"))
        .map(|e| e.path())
        .collect();
    nodes.sort();
    nodes
        .iter()
        .filter_map(|n| std::fs::read_to_string(n.join("device/vendor")).ok())
        .filter_map(|v| u16::from_str_radix(v.trim().trim_start_matches("0x"), 16).ok())
        .collect()
}

fn main() {
    if std::env::var_os("LIBVA_DRIVER_NAME").is_none() {
        if let Some(driver) = libva_driver_for(&render_node_vendors()) {
            // SAFETY: no other thread exists yet.
            unsafe { std::env::set_var("LIBVA_DRIVER_NAME", driver) };
        }
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("record") => parse_record(&args[1..]).and_then(record),
        Some("stop") => stop(),
        Some("toggle") => {
            if StatusFile::running_pid().is_some() {
                stop()
            } else {
                parse_record(&args[1..]).and_then(record)
            }
        }
        Some("status") => {
            println!("{}", StatusFile::read_json());
            Ok(())
        }
        Some("-h" | "--help" | "help") | None => {
            print!("{USAGE}");
            Ok(())
        }
        Some(other) => Err(anyhow!("unknown command {other}\n\n{USAGE}")),
    };
    if let Err(e) = result {
        eprintln!("nativescreen: {e:#}");
        std::process::exit(1);
    }
}

fn stop() -> Result<()> {
    let Some(pid) = StatusFile::running_pid() else {
        eprintln!("nativescreen: not recording");
        return Ok(());
    };
    unsafe { libc::kill(pid as i32, libc::SIGINT) };
    // Wait until the recorder wrote the package and exited.
    for _ in 0..300 {
        if StatusFile::running_pid().is_none() {
            println!("{}", StatusFile::read_json());
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    bail!("recorder {pid} did not stop within 30 s")
}

fn token_path() -> PathBuf {
    let state = std::env::var_os("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/state"));
    state.join("nativescreen/portal-restore-token")
}

static PROCESS_START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();

/// With `NATIVESCREEN_DEBUG`, prints how long after start a step finished (startup latency).
pub fn debug_mark(step: &str) {
    if std::env::var_os("NATIVESCREEN_DEBUG").is_some() {
        let start = PROCESS_START.get_or_init(std::time::Instant::now);
        eprintln!("[{:>6.0} ms] {step}", start.elapsed().as_secs_f64() * 1000.0);
    }
}

#[tokio::main]
async fn record(args: RecordArgs) -> Result<()> {
    debug_mark("start");
    if let Some(pid) = StatusFile::running_pid() {
        bail!("already recording (pid {pid})");
    }
    let status = StatusFile::claim()?;
    if let Err(e) = encoder::preflight(args.system_audio, args.mic) {
        status.write(&Status::new("idle").message(format!("{e:#}")));
        return Err(e);
    }
    status.write(&Status::new("picking"));
    debug_mark("preflight done");

    let mut sigint = signal(SignalKind::interrupt())?;
    let mut sigterm = signal(SignalKind::terminate())?;

    // 1. Pick the screen. A remembered pick skips the dialog; a stale token falls back to the picker.
    let saved = if args.pick { None } else { std::fs::read_to_string(token_path()).ok() };
    let portal = tokio::select! {
        result = async {
            match capture::open_portal(saved.as_deref().map(str::trim), args.window).await {
                Ok(p) => Ok(p),
                Err(_) if saved.is_some() => capture::open_portal(None, args.window).await,
                Err(e) => Err(e),
            }
        } => result,
        _ = sigint.recv() => { status.write(&Status::new("idle")); return Ok(()) }
        _ = sigterm.recv() => { status.write(&Status::new("idle")); return Ok(()) }
    };
    let portal = match portal {
        Ok(p) => p,
        Err(e) => {
            status.write(&Status::new("idle").message(format!("{e:#}")));
            return Err(e);
        }
    };
    debug_mark("portal stream ready");
    if let Some(token) = &portal.restore_token {
        let path = token_path();
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        let _ = std::fs::write(&path, token);
    }

    // 2. Package and telemetry.
    std::fs::create_dir_all(&args.dir).with_context(|| format!("create {}", args.dir.display()))?;
    let package = bundle::create(&args.dir, chrono::Local::now())?;
    let recording_dir = package.join("recording");
    let session = Arc::new(session::Session::new(&recording_dir.join("telemetry"), args.typed_keys)?);
    let input_devices = if args.input { input::spawn(session.clone()) } else { 0 };

    // 3. Capture thread.
    let (stop_tx, stop_rx) = pipewire::channel::channel::<()>();
    let (events_tx, mut events) = tokio::sync::mpsc::unbounded_channel();
    let options = capture::CaptureOptions {
        recording_dir: recording_dir.clone(),
        system_audio: args.system_audio,
        microphone: args.mic,
        quality_qp: args.quality,
    };
    let node_id = portal.node_id;
    let fd = portal.fd.try_clone()?;
    let session_capture = session.clone();
    let capture_thread = std::thread::spawn(move || {
        if let Err(e) = capture::run(fd, node_id, session_capture, options, stop_rx, events_tx.clone()) {
            let _ = events_tx.send(capture::CaptureEvent::Failed(format!("{e:#}")));
            let _ = events_tx.send(capture::CaptureEvent::Finished { frames: 0, error: Some(format!("{e:#}")) });
        }
    });

    // 4. Wait for the first frame.
    let started = tokio::time::timeout(Duration::from_secs(10), events.recv()).await;
    let (width, height, max_fps, encoder) = match started {
        Ok(Some(capture::CaptureEvent::Started { width, height, max_fps, encoder })) => (width, height, max_fps, encoder),
        Ok(Some(capture::CaptureEvent::Failed(e))) => return fail(&status, &package, stop_tx, capture_thread, e),
        _ => return fail(&status, &package, stop_tx, capture_thread, "no frame from the screen within 10 s".into()),
    };
    debug_mark("first frame encoded");
    let started_at = chrono::Utc::now();
    status.write(
        &Status::new("recording")
            .package(&package)
            .started(started_at)
            .input_devices(input_devices)
            .encoder(&encoder),
    );
    eprintln!(
        "nativescreen: recording {width}x{height} with {encoder}{} into {}",
        if input_devices == 0 && args.input { " (no input devices readable: clicks/keys not recorded)" } else { "" },
        package.display()
    );

    // 5. Record until stopped or failed.
    let mut failure: Option<String> = None;
    tokio::select! {
        _ = sigint.recv() => {}
        _ = sigterm.recv() => {}
        event = events.recv() => {
            if let Some(capture::CaptureEvent::Failed(e)) = event { failure = Some(e) }
        }
    }
    let duration_ms = session.now_ms().unwrap_or(0.0);
    status.write(&Status::new("finishing").package(&package));
    session.stopping.store(true, Ordering::Relaxed);
    let _ = stop_tx.send(());

    let mut frames = 0;
    while let Some(event) = events.recv().await {
        match event {
            capture::CaptureEvent::Finished { frames: f, error } => {
                frames = f;
                if failure.is_none() {
                    failure = error;
                }
                break;
            }
            capture::CaptureEvent::Failed(e) if failure.is_none() => failure = Some(e),
            _ => {}
        }
    }
    let _ = capture_thread.join();
    session.flush();

    if frames == 0 {
        let _ = std::fs::remove_dir_all(&package);
        let message = failure.unwrap_or_else(|| "nothing was recorded".into());
        status.write(&Status::new("idle").message(message.clone()));
        bail!(message);
    }

    // 6. metadata.json + project.json.
    let (lx, ly, lw, lh) = portal.logical.unwrap_or((0, 0, width as i32, height as i32));
    let target = bundle::CaptureTarget {
        mode: if portal.is_window { "window" } else { "display" },
        display_id: 1,
        logical: (lx, ly, lw.max(1), lh.max(1)),
        pixel_size: (width & !1, height & !1),
        scale_factor: width as f64 / lw.max(1) as f64,
        refresh_rate: output_refresh(lx, ly)
            .or_else(|| (1.0..=240.0).contains(&max_fps).then_some(max_fps))
            .unwrap_or(60.0),
        app_name: None,
        window_title: None,
    };
    bundle::finish(
        &package,
        &target,
        duration_ms,
        &bundle::Tracks { system_audio: args.system_audio, microphone: args.mic },
        args.auto_zoom,
        chrono::Utc::now(),
    )?;
    let mut done = Status::new("idle").package(&package).frames(frames);
    if let Some(e) = &failure {
        done = done.message(format!("recording ended early: {e}"));
    }
    status.write(&done);
    println!("{}", package.display());
    Ok(())
}

/// Refresh rate of the output at logical position (x, y), from the compositor when it can tell
/// (`umbriel outputs`: `Position: x,y` and the mode marked `current`). The portal's frame rate is only a cap.
fn output_refresh(x: i32, y: i32) -> Option<f64> {
    let out = std::process::Command::new("umbriel").arg("outputs").output().ok()?;
    parse_output_refresh(&String::from_utf8_lossy(&out.stdout), x, y)
}

fn parse_output_refresh(text: &str, x: i32, y: i32) -> Option<f64> {
    let position = format!("Position: {x},{y}");
    let mut fallback = None;
    // Outputs start at a line without indentation.
    let mut outputs: Vec<Vec<&str>> = Vec::new();
    for line in text.lines() {
        if !line.starts_with(' ') && !line.trim().is_empty() {
            outputs.push(vec![line]);
        } else if let Some(last) = outputs.last_mut() {
            last.push(line);
        }
    }
    for lines in outputs {
        let hz = lines.iter().find(|l| l.contains("current")).and_then(|l| {
            let after = l.split('@').nth(1)?;
            after.trim().split_whitespace().next()?.parse::<f64>().ok()
        });
        if lines.iter().any(|l| l.trim() == position) {
            return hz;
        }
        if fallback.is_none() && lines.iter().any(|l| l.trim() == "Focused: yes") {
            fallback = hz;
        }
    }
    fallback
}

fn fail(
    status: &StatusFile,
    package: &std::path::Path,
    stop_tx: pipewire::channel::Sender<()>,
    thread: std::thread::JoinHandle<()>,
    message: String,
) -> Result<()> {
    let _ = stop_tx.send(());
    let _ = thread.join();
    let _ = std::fs::remove_dir_all(package);
    status.write(&Status::new("idle").message(message.clone()));
    Err(anyhow!(message))
}

#[cfg(test)]
mod tests {
    use super::{libva_driver_for, parse_output_refresh};

    #[test]
    fn pins_the_integrated_gpu_driver_only_on_hybrid_machines() {
        assert_eq!(libva_driver_for(&[0x1002, 0x10de]), Some("radeonsi"));
        assert_eq!(libva_driver_for(&[0x10de, 0x8086]), Some("iHD"));
        assert_eq!(libva_driver_for(&[0x1002]), None);
        assert_eq!(libva_driver_for(&[0x10de]), None);
    }

    const OUTPUTS: &str = "eDP-2 \"Panel\"\n  Focused: no\n  Position: 0,0\n  Modes:\n    2880x1800 @ 120.000 Hz (preferred, current)\n    2880x1800 @ 60.001 Hz (preferred)\nHDMI-A-1 \"TV\"\n  Focused: yes\n  Position: 1440,0\n  Modes:\n    3840x2160 @ 60.000 Hz (current)\n";

    #[test]
    fn refresh_of_the_recorded_output() {
        assert_eq!(parse_output_refresh(OUTPUTS, 0, 0), Some(120.0));
        assert_eq!(parse_output_refresh(OUTPUTS, 1440, 0), Some(60.0));
        // Unknown position: the focused output.
        assert_eq!(parse_output_refresh(OUTPUTS, 9, 9), Some(60.0));
    }
}
