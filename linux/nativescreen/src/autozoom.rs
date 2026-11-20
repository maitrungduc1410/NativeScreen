//! Auto-Zoom click clustering (spec/03). Same algorithm and constants as the macOS
//! `AutoZoomClusterGenerator` and the Windows port; checked against `conformance/cases/*/expected/autozoom.json`.

use serde::Serialize;

use crate::telemetry::{ClickEvent, KeyEvent};

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ZoomBlock {
    pub source_start_ms: f64,
    pub source_end_ms: f64,
    pub scale: f64,
    pub center_x: f64,
    pub center_y: f64,
}

const LEAD_IN_MS: f64 = 300.0;
const HOLD_AFTER_CLICK_MS: f64 = 2500.0;
const CLUSTER_GAP_MS: f64 = 2500.0;
const HOLD_AFTER_TYPING_MS: f64 = 1500.0;
const MIN_ZOOM_DURATION_MS: f64 = 2200.0;
/// Two zooms less than this far apart become one: a shorter gap only zooms out and straight back in.
pub const MERGE_GAP_MS: f64 = 2500.0;

pub fn generate_zooms(clicks: &[ClickEvent], keys: &[KeyEvent], duration_ms: f64, default_scale: f64) -> Vec<ZoomBlock> {
    let mut down: Vec<&ClickEvent> = clicks
        .iter()
        .filter(|c| c.kind == "down" && c.t < duration_ms - 1000.0)
        .collect();
    // Stable sort, like LINQ OrderBy.
    down.sort_by(|a, b| a.t.total_cmp(&b.t));
    if down.is_empty() {
        return Vec::new();
    }

    let max_end = f64::max(600.0, duration_ms - 800.0);
    let mut blocks = Vec::new();
    let mut start = f64::max(0.0, down[0].t - LEAD_IN_MS);
    let mut end = f64::min(max_end, down[0].t + HOLD_AFTER_CLICK_MS);
    let (mut cx, mut cy) = (down[0].x, down[0].y);
    let mut count = 1.0;

    for i in 1..down.len() {
        let click = down[i];
        let prev = down[i - 1];
        if click.t - prev.t <= CLUSTER_GAP_MS {
            end = f64::min(max_end, f64::max(end, click.t + HOLD_AFTER_CLICK_MS));
            cx += click.x;
            cy += click.y;
            count += 1.0;
        } else {
            end = extend_for_typing(start, end, keys, max_end);
            if end - start < MIN_ZOOM_DURATION_MS {
                end = f64::min(max_end, start + MIN_ZOOM_DURATION_MS);
            }
            blocks.push(make(start, end, default_scale, cx / count, cy / count));
            start = f64::max(end + 250.0, click.t - LEAD_IN_MS);
            end = f64::min(max_end, click.t + HOLD_AFTER_CLICK_MS);
            cx = click.x;
            cy = click.y;
            count = 1.0;
        }
    }

    end = extend_for_typing(start, end, keys, max_end);
    if end - start < MIN_ZOOM_DURATION_MS {
        end = f64::min(max_end, start + MIN_ZOOM_DURATION_MS);
    }
    if end > start + 400.0 {
        blocks.push(make(start, end, default_scale, cx / count, cy / count));
    }

    normalize_non_overlapping(merge_close(blocks), duration_ms)
}

fn merge_close(mut blocks: Vec<ZoomBlock>) -> Vec<ZoomBlock> {
    blocks.sort_by(|a, b| a.source_start_ms.total_cmp(&b.source_start_ms));
    let mut result: Vec<ZoomBlock> = Vec::new();
    for block in blocks {
        match result.last_mut() {
            Some(last) if block.source_start_ms - last.source_end_ms < MERGE_GAP_MS => {
                let last_ms = last.source_end_ms - last.source_start_ms;
                let block_ms = block.source_end_ms - block.source_start_ms;
                let total = f64::max(1.0, last_ms + block_ms);
                last.center_x = (last.center_x * last_ms + block.center_x * block_ms) / total;
                last.center_y = (last.center_y * last_ms + block.center_y * block_ms) / total;
                last.source_end_ms = f64::max(last.source_end_ms, block.source_end_ms);
            }
            _ => result.push(block),
        }
    }
    result
}

pub fn normalize_non_overlapping(mut zooms: Vec<ZoomBlock>, duration_ms: f64) -> Vec<ZoomBlock> {
    zooms.sort_by(|a, b| a.source_start_ms.total_cmp(&b.source_start_ms));
    let mut result: Vec<ZoomBlock> = Vec::new();
    for mut zoom in zooms {
        let min_start = result.last().map_or(0.0, |z| z.source_end_ms);
        zoom.source_start_ms = f64::max(min_start, zoom.source_start_ms);
        zoom.source_end_ms = f64::min(duration_ms, zoom.source_end_ms);
        if zoom.source_end_ms - zoom.source_start_ms >= 200.0 {
            result.push(zoom);
        }
    }
    result
}

fn make(start: f64, end: f64, scale: f64, x: f64, y: f64) -> ZoomBlock {
    ZoomBlock { source_start_ms: start, source_end_ms: end, scale, center_x: x, center_y: y }
}

fn extend_for_typing(start: f64, end: f64, keys: &[KeyEvent], max_end: f64) -> f64 {
    let mut current = end;
    for key in keys {
        if key.t >= start && key.t <= current + 800.0 {
            current = f64::min(max_end, f64::max(current, key.t + HOLD_AFTER_TYPING_MS));
        }
    }
    current
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::load_jsonl;
    use std::path::PathBuf;

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() <= 1e-4 || (a - b).abs() <= 1e-6 * b.abs()
    }

    /// Every conformance case: generated zooms match `expected/autozoom.json` (spec/08 §2.4 tolerances).
    #[test]
    fn matches_conformance_fixtures() {
        let cases = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../conformance/cases");
        let mut checked = 0;
        for entry in std::fs::read_dir(&cases).expect("conformance cases") {
            let case = entry.unwrap().path();
            let expected_path = case.join("expected/autozoom.json");
            let Ok(expected_text) = std::fs::read_to_string(&expected_path) else { continue };
            let expected: Vec<serde_json::Value> = serde_json::from_str(&expected_text).unwrap();
            let recording = case.join("project.nativescreen/recording");
            let meta: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(recording.join("metadata.json")).unwrap()).unwrap();
            let duration = meta["durationMs"].as_f64().unwrap();
            let clicks: Vec<ClickEvent> = load_jsonl(&recording.join("telemetry/clicks.jsonl"));
            let keys: Vec<KeyEvent> = load_jsonl(&recording.join("telemetry/keys.jsonl"));
            let scale = expected.first().and_then(|z| z["scale"].as_f64()).unwrap_or(2.0);
            let got = generate_zooms(&clicks, &keys, duration, scale);
            assert_eq!(got.len(), expected.len(), "zoom count in {}", case.display());
            for (g, e) in got.iter().zip(&expected) {
                assert!(close(g.source_start_ms, e["sourceStartMs"].as_f64().unwrap()), "start in {}", case.display());
                assert!(close(g.source_end_ms, e["sourceEndMs"].as_f64().unwrap()), "end in {}", case.display());
                assert!(close(g.center_x, e["manualCenterX"].as_f64().unwrap()), "x in {}", case.display());
                assert!(close(g.center_y, e["manualCenterY"].as_f64().unwrap()), "y in {}", case.display());
                assert!(close(g.scale, e["scale"].as_f64().unwrap()));
            }
            checked += 1;
        }
        assert!(checked > 0, "no fixtures found");
    }
}
