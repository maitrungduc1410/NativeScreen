//! Screen capture through the ScreenCast portal and PipeWire.
//!
//! The portal is asked for `CursorMode::METADATA`: the cursor is left out of the frames (NativeScreen
//! draws its own spring cursor in post, like `showsCursor = false` on macOS) and its position arrives as
//! `SPA_META_Cursor` on each buffer. That position, normalized to the frame, is `cursor.jsonl`.
//! Buffers that carry only a cursor move (empty chunk) update telemetry and are not encoded.

use std::cell::RefCell;
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use ashpd::desktop::PersistMode;
use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType, StartCastOptions};
use pipewire as pw;
use pw::spa;
use pw::spa::buffer::meta::MetaCursor;
use pw::spa::pod::{ChoiceValue, Object, Property, PropertyFlags, Value};
use pw::spa::utils::{Choice, ChoiceEnum, ChoiceFlags, Id};

use crate::cursor_kind::{Bitmap, CursorClassifier};
use crate::encoder::{Encoder, EncoderConfig};
use crate::session::Session;
use crate::telemetry::CursorSample;

pub struct PortalStream {
    pub node_id: u32,
    pub fd: OwnedFd,
    /// Logical (compositor) position and size of the stream.
    pub logical: Option<(i32, i32, i32, i32)>,
    pub is_window: bool,
    pub restore_token: Option<String>,
    // Kept alive for the whole capture: dropping them closes the portal session.
    _proxy: Screencast,
    _session: ashpd::desktop::Session<Screencast>,
}

/// Opens a ScreenCast session. With a restore token from an earlier pick, the portal reuses that source
/// without a dialog; otherwise it shows its picker.
pub async fn open_portal(restore_token: Option<&str>, allow_windows: bool) -> Result<PortalStream> {
    let proxy = Screencast::new().await.context("ScreenCast portal unavailable")?;
    let cursor_modes = proxy.available_cursor_modes().await.unwrap_or(CursorMode::HIDDEN);
    let cursor_mode = if cursor_modes.contains(CursorMode::METADATA) { CursorMode::METADATA } else { CursorMode::HIDDEN };
    let session = proxy.create_session(Default::default()).await.context("create portal session")?;
    let sources = if allow_windows { SourceType::MONITOR | SourceType::WINDOW } else { SourceType::MONITOR };
    proxy
        .select_sources(
            &session,
            SelectSourcesOptions::default()
                .set_cursor_mode(cursor_mode)
                .set_sources(sources)
                .set_multiple(false)
                .set_restore_token(restore_token)
                .set_persist_mode(PersistMode::ExplicitlyRevoked),
        )
        .await
        .context("select sources")?;
    let response = proxy
        .start(&session, None, StartCastOptions::default())
        .await
        .context("start screencast")?
        .response()
        .map_err(|e| anyhow!("screen selection cancelled or refused: {e}"))?;
    let stream = response.streams().first().cloned().ok_or_else(|| anyhow!("portal returned no stream"))?;
    let fd = proxy.open_pipe_wire_remote(&session, Default::default()).await.context("open PipeWire remote")?;
    let logical = match (stream.position(), stream.size()) {
        (pos, Some((w, h))) => {
            let (x, y) = pos.unwrap_or((0, 0));
            Some((x, y, w, h))
        }
        _ => None,
    };
    Ok(PortalStream {
        node_id: stream.pipe_wire_node_id(),
        fd,
        logical,
        is_window: stream.source_type() == Some(SourceType::WINDOW),
        restore_token: response.restore_token().map(str::to_owned),
        _proxy: proxy,
        _session: session,
    })
}

/// What the capture thread reports back.
pub enum CaptureEvent {
    /// First frame encoded: pixel size and frame rate the stream negotiated, and the encoder in use.
    Started { width: u32, height: u32, max_fps: f64, encoder: String },
    Failed(String),
    /// Capture ended; `frames` were encoded. The files are complete when this arrives.
    Finished { frames: u64, error: Option<String> },
}

pub struct CaptureOptions {
    pub recording_dir: PathBuf,
    pub system_audio: bool,
    pub microphone: bool,
    pub quality_qp: u32,
}

struct State {
    width: u32,
    height: u32,
    format: Option<&'static str>,
    max_fps: f64,
    encoder: Option<Encoder>,
    frames: u64,
    last_cursor: Option<(i32, i32)>,
    classifier: CursorClassifier,
    cursor_kind: &'static str,
    failed: bool,
}

fn gst_format(format: spa::param::video::VideoFormat) -> Option<&'static str> {
    use spa::param::video::VideoFormat as F;
    Some(match format {
        F::BGRx => "BGRx",
        F::BGRA => "BGRA",
        F::RGBx => "RGBx",
        F::RGBA => "RGBA",
        F::xRGB => "xRGB",
        F::xBGR => "xBGR",
        F::ARGB => "ARGB",
        F::ABGR => "ABGR",
        _ => return None,
    })
}

fn serialize(object: Object) -> Vec<u8> {
    spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &Value::Object(object))
        .expect("serialize pod")
        .0
        .into_inner()
}

fn prop(key: u32, value: Value) -> Property {
    Property { key, flags: PropertyFlags::empty(), value }
}

fn enum_format() -> Vec<u8> {
    use spa::param::format::{FormatProperties, MediaSubtype, MediaType};
    use spa::param::video::VideoFormat;
    let obj = spa::pod::object!(
        spa::utils::SpaTypes::ObjectParamFormat,
        spa::param::ParamType::EnumFormat,
        spa::pod::property!(FormatProperties::MediaType, Id, MediaType::Video),
        spa::pod::property!(FormatProperties::MediaSubtype, Id, MediaSubtype::Raw),
        spa::pod::property!(
            FormatProperties::VideoFormat,
            Choice,
            Enum,
            Id,
            VideoFormat::BGRx,
            VideoFormat::BGRx,
            VideoFormat::BGRA,
            VideoFormat::RGBx,
            VideoFormat::RGBA,
            VideoFormat::xRGB,
            VideoFormat::xBGR
        ),
        spa::pod::property!(
            FormatProperties::VideoSize,
            Choice,
            Range,
            Rectangle,
            spa::utils::Rectangle { width: 1920, height: 1080 },
            spa::utils::Rectangle { width: 1, height: 1 },
            spa::utils::Rectangle { width: 8192, height: 8192 }
        ),
        spa::pod::property!(
            FormatProperties::VideoFramerate,
            Choice,
            Range,
            Fraction,
            spa::utils::Fraction { num: 60, denom: 1 },
            spa::utils::Fraction { num: 0, denom: 1 },
            spa::utils::Fraction { num: 1000, denom: 1 }
        ),
    );
    serialize(obj)
}

fn cursor_meta_size(w: i32, h: i32) -> i32 {
    (std::mem::size_of::<spa::sys::spa_meta_cursor>() + std::mem::size_of::<spa::sys::spa_meta_bitmap>()) as i32 + w * h * 4
}

/// Buffers in shared memory (we copy every frame into the encoder), a header, and cursor metadata.
fn buffer_params() -> Vec<Vec<u8>> {
    let data_types = (1 << spa::sys::SPA_DATA_MemFd) | (1 << spa::sys::SPA_DATA_MemPtr);
    let buffers = Object {
        type_: spa::sys::SPA_TYPE_OBJECT_ParamBuffers,
        id: spa::sys::SPA_PARAM_Buffers,
        properties: vec![prop(
            spa::sys::SPA_PARAM_BUFFERS_dataType,
            Value::Choice(ChoiceValue::Int(Choice(ChoiceFlags::empty(), ChoiceEnum::Flags { default: data_types, flags: vec![] }))),
        )],
    };
    let header = Object {
        type_: spa::sys::SPA_TYPE_OBJECT_ParamMeta,
        id: spa::sys::SPA_PARAM_Meta,
        properties: vec![
            prop(spa::sys::SPA_PARAM_META_type, Value::Id(Id(spa::sys::SPA_META_Header))),
            prop(spa::sys::SPA_PARAM_META_size, Value::Int(std::mem::size_of::<spa::sys::spa_meta_header>() as i32)),
        ],
    };
    let cursor = Object {
        type_: spa::sys::SPA_TYPE_OBJECT_ParamMeta,
        id: spa::sys::SPA_PARAM_Meta,
        properties: vec![
            prop(spa::sys::SPA_PARAM_META_type, Value::Id(Id(spa::sys::SPA_META_Cursor))),
            prop(
                spa::sys::SPA_PARAM_META_size,
                Value::Choice(ChoiceValue::Int(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range { default: cursor_meta_size(64, 64), min: cursor_meta_size(1, 1), max: cursor_meta_size(512, 512) },
                ))),
            ),
        ],
    };
    vec![serialize(buffers), serialize(header), serialize(cursor)]
}

/// Runs the PipeWire stream until `stop` receives a message. Blocks the calling thread.
pub fn run(
    fd: OwnedFd,
    node_id: u32,
    session: Arc<Session>,
    options: CaptureOptions,
    stop: pw::channel::Receiver<()>,
    events: tokio::sync::mpsc::UnboundedSender<CaptureEvent>,
) -> Result<()> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None)?;
    let context = pw::context::ContextBox::new(mainloop.loop_(), None)?;
    let core = context.connect_fd(fd, None)?;
    let stream = pw::stream::StreamBox::new(
        &core,
        "nativescreen",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )?;

    let state = Rc::new(RefCell::new(State {
        width: 0,
        height: 0,
        format: None,
        max_fps: 60.0,
        encoder: None,
        frames: 0,
        last_cursor: None,
        classifier: CursorClassifier::load(),
        cursor_kind: "arrow",
        failed: false,
    }));

    let mainloop_ref = mainloop.clone();
    let _stop = stop.attach(mainloop.loop_(), move |_| mainloop_ref.quit());

    let st_param = state.clone();
    let st_process = state.clone();
    let events_process = events.clone();
    let events_state = events.clone();
    let session_process = session.clone();
    let _listener = stream
        .add_local_listener_with_user_data(())
        .state_changed(move |_, _, _old, new| {
            if let pw::stream::StreamState::Error(message) = new {
                let _ = events_state.send(CaptureEvent::Failed(format!("PipeWire stream error: {message}")));
            }
        })
        .param_changed(move |stream, _, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut info = spa::param::video::VideoInfoRaw::default();
            if info.parse(param).is_err() {
                return;
            }
            let mut st = st_param.borrow_mut();
            st.width = info.size().width;
            st.height = info.size().height;
            st.format = gst_format(info.format());
            let max = info.max_framerate();
            st.max_fps = if max.denom > 0 && max.num > 0 { max.num as f64 / max.denom as f64 } else { 60.0 };
            let params = buffer_params();
            let mut pods: Vec<&spa::pod::Pod> = params.iter().filter_map(|b| spa::pod::Pod::from_bytes(b)).collect();
            let _ = stream.update_params(&mut pods);
        })
        .process(move |stream, _| {
            let Some(mut buffer) = stream.dequeue_buffer() else { return };
            let mut st = st_process.borrow_mut();
            if st.failed || session_process.is_stopping() {
                return;
            }
            let (width, height) = (st.width, st.height);

            let meta = buffer.find_meta::<MetaCursor>().filter(|c| c.id() != 0);
            let cursor = meta.map(|c| (c.position().x, c.position().y));
            // The bitmap comes only when the picture changed; the kind holds until the next one.
            if let Some(bitmap) = meta.and_then(|c| c.bitmap().map(|b| (b, c.hotspot()))) {
                let (bmp, hot) = bitmap;
                let size = bmp.size();
                let alpha_index = match bmp.format() {
                    spa::param::video::VideoFormat::ARGB | spa::param::video::VideoFormat::ABGR => 0,
                    _ => 3,
                };
                if let Some(pixels) = bmp.bitmap_data() {
                    let kind = st.classifier.classify(&Bitmap {
                        width: size.width,
                        height: size.height,
                        stride: bmp.stride().unsigned_abs() as usize,
                        alpha_index,
                        pixels,
                        hotspot: (hot.x, hot.y),
                    });
                    if std::env::var_os("NATIVESCREEN_DEBUG").is_some() {
                        eprintln!(
                            "nativescreen: cursor bitmap {}x{} {:?} hotspot {},{} -> {kind} (distance {:.3})",
                            size.width,
                            size.height,
                            bmp.format(),
                            hot.x,
                            hot.y,
                            st.classifier.last_distance
                        );
                    }
                    if kind != st.cursor_kind {
                        st.cursor_kind = kind;
                        st.last_cursor = None; // write a sample with the new kind even if it did not move
                    }
                }
            }

            let datas = buffer.datas_mut();
            let Some(data) = datas.first_mut() else { return };
            let chunk_size = data.chunk().size() as usize;
            let stride = data.chunk().stride().unsigned_abs() as usize;
            let offset = data.chunk().offset() as usize;
            let corrupted = data.chunk().flags().contains(spa::buffer::ChunkFlags::CORRUPTED);
            let has_frame = chunk_size > 0 && !corrupted && width > 0;

            if has_frame && st.encoder.is_none() {
                let Some(format) = st.format else {
                    st.failed = true;
                    let _ = events_process.send(CaptureEvent::Failed("unsupported pixel format".into()));
                    return;
                };
                let cfg = EncoderConfig {
                    package_recording: &options.recording_dir,
                    width,
                    height,
                    format,
                    system_audio: options.system_audio,
                    microphone: options.microphone,
                    quality_qp: options.quality_qp,
                };
                crate::debug_mark("first frame received");
                match Encoder::new(&cfg) {
                    Ok(encoder) => {
                        let _ = session_process.t0.set(std::time::Instant::now());
                        let _ = events_process.send(CaptureEvent::Started {
                            width,
                            height,
                            max_fps: st.max_fps,
                            encoder: encoder.encoder_name.clone(),
                        });
                        st.encoder = Some(encoder);
                    }
                    Err(e) => {
                        st.failed = true;
                        let _ = events_process.send(CaptureEvent::Failed(format!("{e:#}")));
                        return;
                    }
                }
            }

            // Telemetry: one cursor line whenever the position changes.
            if let (Some((cx, cy)), Some(t)) = (cursor, session_process.now_ms()) {
                if st.last_cursor != Some((cx, cy)) && width > 0 && height > 0 {
                    st.last_cursor = Some((cx, cy));
                    let x = cx as f64 / width as f64;
                    let y = cy as f64 / height as f64;
                    *session_process.cursor.lock().unwrap() = Some((x, y));
                    session_process.cursor_log.write(&CursorSample { t, x, y, c: st.cursor_kind.into() });
                }
            }

            if !has_frame {
                return;
            }
            let Some(bytes) = data.data() else { return };
            let row = width as usize * 4;
            let needed = row * height as usize;
            let Some(t0) = session_process.t0.get().copied() else { return };
            let pts = t0.elapsed().as_nanos() as u64;
            // One copy out of the shared-memory buffer, handed to GStreamer as is. Padded rows are packed tight.
            let frame: Vec<u8> = if stride == row && offset + needed <= bytes.len() {
                bytes[offset..offset + needed].to_vec()
            } else {
                let mut packed = vec![0u8; needed];
                for y in 0..height as usize {
                    let src = offset + y * stride;
                    if src + row > bytes.len() {
                        break;
                    }
                    packed[y * row..(y + 1) * row].copy_from_slice(&bytes[src..src + row]);
                }
                packed
            };
            if let Some(encoder) = st.encoder.as_mut() {
                if let Err(e) = encoder.push(pts, frame) {
                    st.failed = true;
                    let _ = events_process.send(CaptureEvent::Failed(format!("{e:#}")));
                    return;
                }
                if let Some(err) = encoder.poll_error() {
                    st.failed = true;
                    let _ = events_process.send(CaptureEvent::Failed(err));
                    return;
                }
            }
            st.frames += 1;
        })
        .register()?;

    let format = enum_format();
    let mut params = [spa::pod::Pod::from_bytes(&format).ok_or_else(|| anyhow!("format pod"))?];
    stream.connect(
        spa::utils::Direction::Input,
        Some(node_id),
        pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
        &mut params,
    )?;

    mainloop.run();

    let _ = stream.disconnect();
    let (encoder, frames) = {
        let mut st = state.borrow_mut();
        (st.encoder.take(), st.frames)
    };
    let error = match encoder {
        Some(encoder) => encoder.finish().err().map(|e| format!("{e:#}")),
        None => Some("no frame was captured".into()),
    };
    let _ = events.send(CaptureEvent::Finished { frames, error });
    Ok(())
}
