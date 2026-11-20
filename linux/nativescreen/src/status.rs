//! `$XDG_RUNTIME_DIR/nativescreen/status.json`: the recorder state for shells and `nativescreen stop`.
//!
//! `state` is `picking` (portal dialog open), `recording`, `finishing` (writing the package) or `idle`.
//! `pid` is set while a recorder process owns the file; readers check that the process is alive.

use std::path::{Path, PathBuf};

use anyhow::Result;
use serde_json::{Value, json};

fn dir() -> PathBuf {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    runtime.join("nativescreen")
}

fn path() -> PathBuf {
    dir().join("status.json")
}

pub struct Status(Value);

impl Status {
    pub fn new(state: &str) -> Self {
        Self(json!({ "state": state }))
    }
    pub fn message(mut self, message: String) -> Self {
        self.0["message"] = json!(message);
        self
    }
    pub fn package(mut self, package: &Path) -> Self {
        self.0["package"] = json!(package.display().to_string());
        self
    }
    pub fn started(mut self, at: chrono::DateTime<chrono::Utc>) -> Self {
        self.0["startedAtMs"] = json!(at.timestamp_millis());
        self
    }
    pub fn input_devices(mut self, n: usize) -> Self {
        self.0["inputDevices"] = json!(n);
        self
    }
    pub fn encoder(mut self, name: &str) -> Self {
        self.0["encoder"] = json!(name);
        self
    }
    pub fn frames(mut self, n: u64) -> Self {
        self.0["frames"] = json!(n);
        self
    }
}

pub struct StatusFile {
    pid: u32,
}

impl StatusFile {
    /// Takes the status file for this process.
    pub fn claim() -> Result<Self> {
        std::fs::create_dir_all(dir())?;
        Ok(Self { pid: std::process::id() })
    }

    /// Writes atomically. Every state but `idle` carries this process id.
    pub fn write(&self, status: &Status) {
        let mut value = status.0.clone();
        if value["state"] != "idle" {
            value["pid"] = json!(self.pid);
        }
        let tmp = dir().join(".status.json.tmp");
        if std::fs::write(&tmp, value.to_string()).is_ok() {
            let _ = std::fs::rename(&tmp, path());
        }
    }

    /// The recorder process that owns the status file, if it is still alive.
    pub fn running_pid() -> Option<u32> {
        let value: Value = serde_json::from_str(&std::fs::read_to_string(path()).ok()?).ok()?;
        let pid = value["pid"].as_u64()? as u32;
        let alive = unsafe { libc::kill(pid as i32, 0) } == 0;
        let ours = std::fs::read_to_string(format!("/proc/{pid}/comm")).is_ok_and(|c| c.trim() == "nativescreen");
        (alive && ours).then_some(pid)
    }

    /// The status as JSON; a dead recorder's leftover state reads as `idle`.
    pub fn read_json() -> String {
        let Some(mut value) = std::fs::read_to_string(path()).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok()) else {
            return json!({ "state": "idle" }).to_string();
        };
        if value.get("pid").is_some() && Self::running_pid().is_none() {
            value["state"] = json!("idle");
            value.as_object_mut().unwrap().remove("pid");
        }
        value.to_string()
    }
}
