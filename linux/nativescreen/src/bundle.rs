//! `.nativescreen` package layout (spec/02 §1). Creates the folders before capture and writes
//! `recording/metadata.json` and `project.json` once capture stopped; `recording/` is immutable after that.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{Value, json};

use crate::autozoom;
use crate::telemetry::{ClickEvent, KeyEvent, load_jsonl};

/// What was captured, for `metadata.json`'s `captureTarget`.
#[derive(Debug, Clone)]
pub struct CaptureTarget {
    /// `display` or `window`.
    pub mode: &'static str,
    pub display_id: u64,
    pub logical: (i32, i32, i32, i32),
    pub pixel_size: (u32, u32),
    pub scale_factor: f64,
    pub refresh_rate: f64,
    pub app_name: Option<String>,
    pub window_title: Option<String>,
}

pub struct Tracks {
    pub system_audio: bool,
    pub microphone: bool,
}

/// `<dir>/Recording yyyy-MM-dd HH.mm.ss.nativescreen`, with ` 2`, ` 3`... when taken.
pub fn create(dir: &Path, now: chrono::DateTime<chrono::Local>) -> Result<PathBuf> {
    let base = format!("Recording {}", now.format("%Y-%m-%d %H.%M.%S"));
    let mut path = dir.join(format!("{base}.nativescreen"));
    let mut index = 2;
    while path.exists() {
        path = dir.join(format!("{base} {index}.nativescreen"));
        index += 1;
    }
    std::fs::create_dir_all(path.join("recording/telemetry")).context("create package")?;
    std::fs::create_dir_all(path.join("assets"))?;
    Ok(path)
}

fn iso(now: chrono::DateTime<chrono::Utc>) -> String {
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub fn finish(
    package: &Path,
    target: &CaptureTarget,
    duration_ms: f64,
    tracks: &Tracks,
    auto_zoom: bool,
    now: chrono::DateTime<chrono::Utc>,
) -> Result<()> {
    let recording = package.join("recording");
    let duration = duration_ms.max(1000.0);
    let (lx, ly, lw, lh) = target.logical;
    let mut capture = json!({
        "mode": target.mode,
        "displayId": target.display_id,
        "logicalBounds": { "x": lx, "y": ly, "width": lw, "height": lh },
        "pixelSize": { "width": target.pixel_size.0, "height": target.pixel_size.1 },
        "scaleFactor": target.scale_factor,
        "refreshRate": target.refresh_rate,
        "windowBorderRadius": 0,
    });
    if let Some(name) = &target.app_name {
        capture["appName"] = json!(name);
    }
    if let Some(title) = &target.window_title {
        capture["windowTitle"] = json!(title);
    }
    let metadata = json!({
        "formatVersion": "1.0.0",
        "appVersion": env!("CARGO_PKG_VERSION"),
        "platform": "linux",
        "createdAt": iso(now),
        "durationMs": duration,
        "captureTarget": capture,
        "tracks": {
            "displayVideo": "display.mp4",
            "webcamVideo": null,
            "microphoneAudio": if tracks.microphone { json!("microphone.m4a") } else { Value::Null },
            "systemAudio": if tracks.system_audio { json!("display.mp4") } else { Value::Null },
            "cursorTelemetry": "telemetry/cursor.jsonl",
            "clicksTelemetry": "telemetry/clicks.jsonl",
            "keysTelemetry": "telemetry/keys.jsonl",
            "windowTelemetry": "telemetry/window.jsonl",
        }
    });
    write_json(&recording.join("metadata.json"), &metadata)?;

    let clicks: Vec<ClickEvent> = load_jsonl(&recording.join("telemetry/clicks.jsonl"));
    let keys: Vec<KeyEvent> = load_jsonl(&recording.join("telemetry/keys.jsonl"));
    let zooms = if auto_zoom { autozoom::generate_zooms(&clicks, &keys, duration, 1.8) } else { Vec::new() };
    let name = target
        .app_name
        .clone()
        .unwrap_or_else(|| package.file_stem().unwrap_or_default().to_string_lossy().into_owned());
    let project = project_json(&name, duration, &zooms, now)?;
    write_project_json(package, &project)
}

/// The default look (the template is the macOS defaults), one slice over the whole recording, and the auto-zooms.
pub fn project_json(name: &str, duration_ms: f64, zooms: &[autozoom::ZoomBlock], now: chrono::DateTime<chrono::Utc>) -> Result<Value> {
    let mut project: Value = serde_json::from_str(include_str!("../assets/project-template.json"))?;
    project["id"] = json!(uuid::Uuid::new_v4().to_string().to_uppercase());
    project["name"] = json!(name);
    project["createdAt"] = json!(iso(now));
    project["updatedAt"] = json!(iso(now));
    let slice = &mut project["timeline"]["slices"][0];
    slice["id"] = json!(uuid::Uuid::new_v4().to_string().to_uppercase());
    slice["sourceStartMs"] = json!(0.0);
    slice["sourceEndMs"] = json!(duration_ms);
    project["timeline"]["zooms"] = Value::Array(
        zooms
            .iter()
            .map(|z| {
                json!({
                    "disabled": false,
                    "id": uuid::Uuid::new_v4().to_string().to_uppercase(),
                    "instantAnimation": false,
                    "loupe": { "bevelRatio": 0.2, "chromaticAberration": 0.5, "radius01": 0.35 },
                    "manualCenter01": { "x": z.center_x, "y": z.center_y },
                    "mode": "follow-cursor",
                    "presentation": "screen",
                    "scale": z.scale,
                    "sourceStartMs": z.source_start_ms,
                    "sourceEndMs": z.source_end_ms,
                })
            })
            .collect(),
    );
    Ok(project)
}

fn write_json(path: &Path, value: &Value) -> Result<()> {
    std::fs::write(path, serde_json::to_string_pretty(value)?).with_context(|| format!("write {}", path.display()))
}

/// Replaces project.json in one step (write then rename), so a crash leaves the old or the new file.
pub fn write_project_json(package: &Path, value: &Value) -> Result<()> {
    let tmp = package.join(".project.json.tmp");
    write_json(&tmp, value)?;
    std::fs::rename(&tmp, package.join("project.json"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_readable_package() {
        let dir = std::env::temp_dir().join(format!("ns-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let package = create(&dir, chrono::Local::now()).unwrap();
        std::fs::write(
            package.join("recording/telemetry/clicks.jsonl"),
            "{\"t\":1000,\"type\":\"down\",\"button\":\"left\",\"x\":0.5,\"y\":0.25,\"count\":1}\n",
        )
        .unwrap();
        let target = CaptureTarget {
            mode: "display",
            display_id: 1,
            logical: (0, 0, 1920, 1200),
            pixel_size: (2880, 1800),
            scale_factor: 1.5,
            refresh_rate: 60.0,
            app_name: None,
            window_title: None,
        };
        finish(&package, &target, 8000.0, &Tracks { system_audio: true, microphone: false }, true, chrono::Utc::now()).unwrap();
        let meta: Value = serde_json::from_str(&std::fs::read_to_string(package.join("recording/metadata.json")).unwrap()).unwrap();
        assert_eq!(meta["platform"], "linux");
        assert_eq!(meta["tracks"]["systemAudio"], "display.mp4");
        assert!(meta["tracks"]["microphoneAudio"].is_null());
        let project: Value = serde_json::from_str(&std::fs::read_to_string(package.join("project.json")).unwrap()).unwrap();
        assert_eq!(project["timeline"]["slices"][0]["sourceEndMs"], 8000.0);
        let zooms = project["timeline"]["zooms"].as_array().unwrap();
        assert_eq!(zooms.len(), 1);
        assert_eq!(zooms[0]["manualCenter01"]["x"], 0.5);

        // The shared schema every platform validates project.json against.
        let schema_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/schemas/project.schema.json");
        let schema: Value = serde_json::from_str(&std::fs::read_to_string(schema_path).unwrap()).unwrap();
        let validator = jsonschema::validator_for(&schema).unwrap();
        let errors: Vec<String> = validator.iter_errors(&project).map(|e| format!("{} at {}", e, e.instance_path())).collect();
        assert!(errors.is_empty(), "project.json does not match spec/schemas/project.schema.json: {errors:#?}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
