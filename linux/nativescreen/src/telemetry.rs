//! Telemetry records and append-only JSON Lines writers (spec/02 §3).
//!
//! Every line is written whole and flushed often, so a crash keeps everything before it.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CursorSample {
    pub t: f64,
    pub x: f64,
    pub y: f64,
    pub c: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClickEvent {
    pub t: f64,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub button: Option<String>,
    pub x: f64,
    pub y: f64,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub count: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub dx: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub dy: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyEvent {
    pub t: f64,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub modifiers: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub label: Option<String>,
}

/// Writes one JSON object per line. Flushes at most every 250 ms, and on drop.
pub struct JsonlWriter {
    inner: Mutex<(BufWriter<File>, Instant)>,
}

impl JsonlWriter {
    pub fn create(path: &Path) -> std::io::Result<Self> {
        let file = File::create(path)?;
        Ok(Self { inner: Mutex::new((BufWriter::new(file), Instant::now())) })
    }

    pub fn write<T: Serialize>(&self, value: &T) {
        let Ok(line) = serde_json::to_string(value) else { return };
        let mut guard = self.inner.lock().unwrap();
        let (writer, last_flush) = &mut *guard;
        let _ = writer.write_all(line.as_bytes());
        let _ = writer.write_all(b"\n");
        if last_flush.elapsed() > Duration::from_millis(250) {
            let _ = writer.flush();
            *last_flush = Instant::now();
        }
    }

    pub fn flush(&self) {
        let _ = self.inner.lock().unwrap().0.flush();
    }
}

impl Drop for JsonlWriter {
    fn drop(&mut self) {
        self.flush();
    }
}

/// Reads a `.jsonl` file, skipping lines that do not parse (a torn last line after a crash).
pub fn load_jsonl<T: for<'de> Deserialize<'de>>(path: &Path) -> Vec<T> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect()
}
