//! State shared by the capture thread, the input threads and the main thread during one recording.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use crate::telemetry::JsonlWriter;

pub struct Session {
    /// The recording clock: set when the first video frame is accepted. Every timestamp
    /// (video PTS, telemetry `t`) is measured from it, so they share one zero (spec/02 §2).
    pub t0: OnceLock<Instant>,
    /// Latest cursor position, normalized to the captured area. Clicks take their position from it.
    pub cursor: Mutex<Option<(f64, f64)>>,
    pub cursor_log: JsonlWriter,
    pub clicks_log: JsonlWriter,
    pub keys_log: JsonlWriter,
    pub stopping: AtomicBool,
    /// Record the identity of plain typed keys, not only that typing happened (spec/02 §3.3).
    pub typed_keys: bool,
}

impl Session {
    pub fn new(telemetry: &Path, typed_keys: bool) -> std::io::Result<Self> {
        std::fs::File::create(telemetry.join("window.jsonl"))?;
        Ok(Self {
            t0: OnceLock::new(),
            cursor: Mutex::new(None),
            cursor_log: JsonlWriter::create(&telemetry.join("cursor.jsonl"))?,
            clicks_log: JsonlWriter::create(&telemetry.join("clicks.jsonl"))?,
            keys_log: JsonlWriter::create(&telemetry.join("keys.jsonl"))?,
            stopping: AtomicBool::new(false),
            typed_keys,
        })
    }

    /// Milliseconds since the first frame, or `None` before it.
    pub fn now_ms(&self) -> Option<f64> {
        self.t0.get().map(|t0| t0.elapsed().as_secs_f64() * 1000.0)
    }

    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::Relaxed)
    }

    pub fn flush(&self) {
        self.cursor_log.flush();
        self.clicks_log.flush();
        self.keys_log.flush();
    }
}
