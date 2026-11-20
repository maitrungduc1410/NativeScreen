//! Click, scroll and keystroke telemetry from evdev (`/dev/input/event*`).
//!
//! Wayland gives no client a global view of input, so this reads the kernel devices directly. It needs
//! read access to them (membership of the `input` group); without it the recording still works and only
//! the cursor track is written. Touchpad taps are resolved by libinput in user space and never reach
//! evdev as button events, so one- and two-finger taps are recognized here.

use std::sync::Arc;
use std::time::Instant;

use evdev::{AbsoluteAxisCode, Device, EventSummary, KeyCode, RelativeAxisCode};

use crate::session::Session;
use crate::telemetry::{ClickEvent, KeyEvent};

/// Opens every readable mouse, touchpad and keyboard and reads it on its own thread.
/// Returns how many devices are being read.
pub fn spawn(session: Arc<Session>) -> usize {
    let mut count = 0;
    for (_path, device) in evdev::enumerate() {
        let Some(keys) = device.supported_keys() else { continue };
        let is_pointer = keys.contains(KeyCode::BTN_LEFT) || keys.contains(KeyCode::BTN_TOUCH);
        let is_keyboard = keys.contains(KeyCode::KEY_A) && keys.contains(KeyCode::KEY_SPACE);
        if !is_pointer && !is_keyboard {
            continue;
        }
        let is_touchpad = keys.contains(KeyCode::BTN_TOOL_FINGER)
            && device.supported_absolute_axes().is_some_and(|a| a.contains(AbsoluteAxisCode::ABS_X));
        let session = session.clone();
        count += 1;
        std::thread::spawn(move || read_device(device, session, is_touchpad));
    }
    count
}

#[derive(Default)]
struct Modifiers {
    caps: bool,
    meta: bool,
    shift: bool,
    alt: bool,
    ctrl: bool,
}

struct ClickTracker {
    last_down: Option<(Instant, &'static str, f64, f64, u32)>,
}

impl ClickTracker {
    /// 1 for a single click, 2 for the second click of a double click, and so on.
    fn count(&mut self, button: &'static str, x: f64, y: f64) -> u32 {
        let now = Instant::now();
        let count = match self.last_down {
            Some((at, b, px, py, n))
                if b == button && now.duration_since(at).as_millis() < 500 && (x - px).abs() < 0.01 && (y - py).abs() < 0.01 =>
            {
                n + 1
            }
            _ => 1,
        };
        self.last_down = Some((now, button, x, y, count));
        count
    }
}

/// One- or two-finger touch that lifts quickly without moving: a tap-to-click.
struct TapTracker {
    started: Option<Instant>,
    fingers: u32,
    need_start: bool,
    start_pos: (i32, i32),
    pos: (i32, i32),
    moved: bool,
}

fn read_device(mut device: Device, session: Arc<Session>, is_touchpad: bool) {
    let mut mods = Modifiers::default();
    let mut clicks = ClickTracker { last_down: None };
    let mut tap = TapTracker { started: None, fingers: 0, need_start: false, start_pos: (0, 0), pos: (0, 0), moved: false };
    // Touchpads report about 30 units per mm; a tap moves less than ~1.5 mm.
    let tap_slop = 45;
    loop {
        let events = match device.fetch_events() {
            Ok(events) => events.collect::<Vec<_>>(),
            Err(_) => return,
        };
        if session.is_stopping() {
            return;
        }
        for event in events {
            let Some(t) = session.now_ms() else { continue };
            match event.destructure() {
                EventSummary::Key(_, code, value) => {
                    if is_touchpad {
                        match (code, value) {
                            (KeyCode::BTN_TOOL_FINGER, 1) => tap.fingers = tap.fingers.max(1),
                            (KeyCode::BTN_TOOL_DOUBLETAP, 1) => tap.fingers = tap.fingers.max(2),
                            (KeyCode::BTN_TOOL_TRIPLETAP, 1) => tap.fingers = tap.fingers.max(3),
                            (KeyCode::BTN_TOUCH, 1) => {
                                tap.started = Some(Instant::now());
                                tap.need_start = true;
                                tap.moved = false;
                            }
                            (KeyCode::BTN_TOUCH, 0) => {
                                if let Some(started) = tap.started.take() {
                                    let quick = started.elapsed().as_millis() < 200;
                                    if quick && !tap.moved && tap.fingers <= 2 {
                                        let button = if tap.fingers == 2 { "right" } else { "left" };
                                        click(&session, &mut clicks, t, button, true);
                                        click(&session, &mut clicks, t + 1.0, button, false);
                                    }
                                }
                                tap.fingers = 0;
                            }
                            _ => {}
                        }
                    }
                    if let Some(button) = mouse_button(code) {
                        if value == 1 || value == 0 {
                            click(&session, &mut clicks, t, button, value == 1);
                        }
                        continue;
                    }
                    key(&session, &mut mods, t, code, value);
                }
                EventSummary::AbsoluteAxis(_, axis, value) if is_touchpad => match axis {
                    AbsoluteAxisCode::ABS_X => tap.pos.0 = value,
                    AbsoluteAxisCode::ABS_Y => tap.pos.1 = value,
                    _ => {}
                },
                EventSummary::Synchronization(..) if is_touchpad && tap.started.is_some() => {
                    // The frame that carried touch-down also carried its position: that is the start point.
                    if tap.need_start {
                        tap.start_pos = tap.pos;
                        tap.need_start = false;
                    } else if (tap.pos.0 - tap.start_pos.0).abs() > tap_slop || (tap.pos.1 - tap.start_pos.1).abs() > tap_slop {
                        tap.moved = true;
                    }
                }
                EventSummary::RelativeAxis(_, axis, value) => {
                    let (dx, dy) = match axis {
                        RelativeAxisCode::REL_WHEEL => (0.0, value as f64 * 10.0),
                        RelativeAxisCode::REL_HWHEEL => (value as f64 * 10.0, 0.0),
                        _ => continue,
                    };
                    let (x, y) = position(&session);
                    session.clicks_log.write(&ClickEvent {
                        t,
                        kind: "scroll".into(),
                        button: None,
                        x,
                        y,
                        count: None,
                        dx: Some(dx),
                        dy: Some(dy),
                    });
                }
                _ => {}
            }
        }
    }
}

fn position(session: &Session) -> (f64, f64) {
    session.cursor.lock().unwrap().unwrap_or((0.5, 0.5))
}

fn mouse_button(code: KeyCode) -> Option<&'static str> {
    match code {
        KeyCode::BTN_LEFT => Some("left"),
        KeyCode::BTN_RIGHT => Some("right"),
        KeyCode::BTN_MIDDLE | KeyCode::BTN_SIDE | KeyCode::BTN_EXTRA => Some("other"),
        _ => None,
    }
}

fn click(session: &Session, clicks: &mut ClickTracker, t: f64, button: &'static str, down: bool) {
    let (x, y) = position(session);
    let count = if down {
        clicks.count(button, x, y)
    } else {
        clicks.last_down.map_or(1, |(_, _, _, _, n)| n)
    };
    session.clicks_log.write(&ClickEvent {
        t,
        kind: if down { "down" } else { "up" }.into(),
        button: Some(button.into()),
        x,
        y,
        count: Some(count),
        dx: None,
        dy: None,
    });
}

fn key(session: &Session, mods: &mut Modifiers, t: f64, code: KeyCode, value: i32) {
    let pressed = value == 1;
    match code {
        KeyCode::KEY_LEFTSHIFT | KeyCode::KEY_RIGHTSHIFT => mods.shift = value != 0,
        KeyCode::KEY_LEFTCTRL | KeyCode::KEY_RIGHTCTRL => mods.ctrl = value != 0,
        KeyCode::KEY_LEFTALT | KeyCode::KEY_RIGHTALT => mods.alt = value != 0,
        KeyCode::KEY_LEFTMETA | KeyCode::KEY_RIGHTMETA => mods.meta = value != 0,
        KeyCode::KEY_CAPSLOCK => {
            if pressed {
                mods.caps = !mods.caps;
            }
        }
        _ => {
            // Key down only; auto-repeat (value 2) is not a new keystroke.
            if pressed {
                session.keys_log.write(&stroke(t, mods, key_name(code), session.typed_keys));
            }
        }
    }
}

/// Same vocabulary and modifier order as the macOS and Windows recorders.
fn stroke(t: f64, mods: &Modifiers, key: Option<String>, typed_keys: bool) -> KeyEvent {
    let mut modifiers = Vec::new();
    if mods.caps {
        modifiers.push("CapsLock");
    }
    if mods.meta {
        modifiers.push("Meta");
    }
    if mods.shift {
        modifiers.push("Shift");
    }
    if mods.alt {
        modifiers.push("Alt");
    }
    if mods.ctrl {
        modifiers.push("Ctrl");
    }
    let special = key.as_deref().is_some_and(is_special_standalone);
    let shortcut = mods.meta || mods.alt || mods.ctrl || special;
    if !shortcut && !typed_keys {
        return KeyEvent { t, kind: "typing".into(), modifiers: None, key: None, label: None };
    }
    let mut parts: Vec<String> = modifiers
        .iter()
        .map(|m| match *m {
            "Meta" => "Super".to_string(),
            "CapsLock" => "Caps".to_string(),
            other => other.to_string(),
        })
        .collect();
    if let Some(k) = &key {
        parts.push(key_label(k).to_string());
    }
    let label = parts.join(" ");
    KeyEvent {
        t,
        kind: if shortcut { "shortcut" } else { "typing" }.into(),
        modifiers: if modifiers.is_empty() { None } else { Some(modifiers.iter().map(|m| m.to_string()).collect()) },
        key,
        label: if label.is_empty() { None } else { Some(label) },
    }
}

fn is_special_standalone(key: &str) -> bool {
    matches!(
        key,
        "Delete" | "ForwardDelete" | "ArrowLeft" | "ArrowRight" | "ArrowUp" | "ArrowDown" | "Home" | "End" | "PageUp" | "PageDown"
    ) || (key.starts_with('F') && key.len() <= 3 && key[1..].parse::<u8>().is_ok_and(|n| (1..=12).contains(&n)))
}

fn key_label(key: &str) -> &str {
    match key {
        "Delete" => "Backspace",
        "ForwardDelete" => "Delete",
        "Escape" => "Esc",
        "ArrowUp" => "↑",
        "ArrowDown" => "↓",
        "ArrowLeft" => "←",
        "ArrowRight" => "→",
        other => other,
    }
}

/// Physical key to the shared key name (US layout for printable keys).
fn key_name(code: KeyCode) -> Option<String> {
    let name = match code {
        KeyCode::KEY_ENTER | KeyCode::KEY_KPENTER => "Enter",
        KeyCode::KEY_TAB => "Tab",
        KeyCode::KEY_SPACE => "Space",
        KeyCode::KEY_BACKSPACE => "Delete",
        KeyCode::KEY_DELETE => "ForwardDelete",
        KeyCode::KEY_ESC => "Escape",
        KeyCode::KEY_LEFT => "ArrowLeft",
        KeyCode::KEY_RIGHT => "ArrowRight",
        KeyCode::KEY_UP => "ArrowUp",
        KeyCode::KEY_DOWN => "ArrowDown",
        KeyCode::KEY_HOME => "Home",
        KeyCode::KEY_END => "End",
        KeyCode::KEY_PAGEUP => "PageUp",
        KeyCode::KEY_PAGEDOWN => "PageDown",
        KeyCode::KEY_MINUS => "-",
        KeyCode::KEY_EQUAL => "=",
        KeyCode::KEY_LEFTBRACE => "[",
        KeyCode::KEY_RIGHTBRACE => "]",
        KeyCode::KEY_BACKSLASH => "\\",
        KeyCode::KEY_SEMICOLON => ";",
        KeyCode::KEY_APOSTROPHE => "'",
        KeyCode::KEY_GRAVE => "`",
        KeyCode::KEY_COMMA => ",",
        KeyCode::KEY_DOT => ".",
        KeyCode::KEY_SLASH => "/",
        _ => {
            let raw = format!("{code:?}");
            let rest = raw.strip_prefix("KEY_")?;
            let fkey = rest.strip_prefix('F').and_then(|n| n.parse::<u8>().ok()).filter(|n| (1..=12).contains(n));
            if fkey.is_some() || (rest.len() == 1 && rest.chars().all(|c| c.is_ascii_alphanumeric())) {
                return Some(rest.to_string());
            }
            return None;
        }
    };
    Some(name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcut_and_typing_vocabulary() {
        let mods = Modifiers { ctrl: true, shift: true, ..Default::default() };
        let ev = stroke(10.0, &mods, key_name(KeyCode::KEY_P), false);
        assert_eq!(ev.kind, "shortcut");
        assert_eq!(ev.modifiers.as_deref(), Some(&["Shift".to_string(), "Ctrl".to_string()][..]));
        assert_eq!(ev.label.as_deref(), Some("Shift Ctrl P"));

        let plain = stroke(11.0, &Modifiers::default(), key_name(KeyCode::KEY_A), false);
        assert_eq!(plain.kind, "typing");
        assert!(plain.key.is_none(), "typed key identity is off by default");

        let arrow = stroke(12.0, &Modifiers::default(), key_name(KeyCode::KEY_LEFT), false);
        assert_eq!(arrow.kind, "shortcut");
        assert_eq!(arrow.label.as_deref(), Some("←"));
        assert_eq!(key_name(KeyCode::KEY_F5).as_deref(), Some("F5"));
        assert_eq!(key_name(KeyCode::KEY_7).as_deref(), Some("7"));
    }
}
