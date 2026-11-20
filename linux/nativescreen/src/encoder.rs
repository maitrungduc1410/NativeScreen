//! Hardware video encode and audio capture with GStreamer (spec/platforms/linux-pipewire-vaapi.md).
//!
//! Screen frames come from the PipeWire capture thread through `appsrc` with their own PTS (recording
//! clock, first frame = 0). System audio (default sink monitor) and the microphone are PipeWire sources
//! inside the same pipeline; a `valve` drops their buffers until the first video frame, and a pad offset
//! moves video onto the pipeline running time of that moment, so audio and video share one start.
//!
//! - `display.mp4`: H.264 (VA-API when present, else x264) + system audio AAC 48 kHz stereo, fragmented MP4 (2 s).
//! - `microphone.m4a`: AAC 48 kHz mono, fragmented MP4.

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;

pub struct EncoderConfig<'a> {
    pub package_recording: &'a Path,
    pub width: u32,
    pub height: u32,
    /// GStreamer raw format name of the frames pushed (`BGRx`, `RGBA`...).
    pub format: &'a str,
    pub system_audio: bool,
    pub microphone: bool,
    /// 0 to 51; lower is better quality and larger files.
    pub quality_qp: u32,
}

pub struct Encoder {
    pipeline: gst::Pipeline,
    appsrc: gst_app::AppSrc,
    valves: Vec<gst::Element>,
    started: bool,
    pub encoder_name: String,
}

fn has(element: &str) -> bool {
    gst::ElementFactory::find(element).is_some()
}

/// Fails before the screen picker opens when a needed GStreamer element is missing.
pub fn preflight(system_audio: bool, microphone: bool) -> Result<()> {
    gst::init()?;
    let mut missing = Vec::new();
    for (element, package) in [("mp4mux", "gst-plugins-good"), ("h264parse", "gst-plugins-bad"), ("appsrc", "gst-plugins-base")] {
        if !has(element) {
            missing.push(format!("{element} ({package})"));
        }
    }
    if !(has("vah264enc") && has("vapostproc")) && !has("x264enc") {
        missing.push("vah264enc (gst-plugin-va) or x264enc (gst-plugins-ugly)".into());
    }
    if system_audio || microphone {
        for (element, package) in [("pipewiresrc", "gst-plugin-pipewire"), ("fdkaacenc", "gst-plugins-bad"), ("valve", "gstreamer")] {
            if !has(element) {
                missing.push(format!("{element} ({package})"));
            }
        }
    }
    if missing.is_empty() { Ok(()) } else { bail!("missing GStreamer elements: {}", missing.join(", ")) }
}

fn quote(path: &Path) -> String {
    format!("\"{}\"", path.display().to_string().replace('\\', "\\\\").replace('"', "\\\""))
}

impl Encoder {
    pub fn new(cfg: &EncoderConfig) -> Result<Self> {
        gst::init()?;
        if !has("mp4mux") {
            bail!("GStreamer element mp4mux is missing: install gst-plugins-good");
        }
        // Even sizes: H.264 4:2:0 needs them.
        let (w, h) = (cfg.width & !1, cfg.height & !1);
        let (convert, encoder_name) = if has("vah264enc") && has("vapostproc") {
            (
                format!("vapostproc add-borders=true ! video/x-raw(memory:VAMemory),format=NV12,width={w},height={h}"),
                format!("vah264enc rate-control=cqp qpi={q} qpp={q} qpb={q} key-int-max=120", q = cfg.quality_qp),
            )
        } else if has("x264enc") {
            (
                format!("videoconvert ! videoscale add-borders=true ! video/x-raw,format=I420,width={w},height={h}"),
                format!("x264enc speed-preset=veryfast pass=quant quantizer={} key-int-max=120", cfg.quality_qp),
            )
        } else {
            bail!("no H.264 encoder: install gst-plugin-va (VA-API) or gst-plugins-ugly (x264)");
        };

        let display = cfg.package_recording.join("display.mp4");
        let mut desc = format!(
            "appsrc name=video is-live=true format=time do-timestamp=false block=false max-buffers=2 leaky-type=downstream \
               caps=video/x-raw,format={fmt},width={sw},height={sh},framerate=0/1 \
             ! queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream \
             ! {convert} ! {encoder_name} ! h264parse ! queue ! mux.video_0 \
             mp4mux name=mux fragment-duration=2000 ! filesink location={display} ",
            fmt = cfg.format,
            sw = cfg.width,
            sh = cfg.height,
            display = quote(&display),
        );
        if cfg.system_audio {
            desc.push_str(
                "pipewiresrc name=sysaudio stream-properties=\"props,stream.capture.sink=true,media.role=Screen\" do-timestamp=true \
                 ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 \
                 ! valve name=sysvalve drop=true ! fdkaacenc ! queue ! mux.audio_0 ",
            );
        }
        if cfg.microphone {
            let mic = cfg.package_recording.join("microphone.m4a");
            desc.push_str(&format!(
                "pipewiresrc name=mic do-timestamp=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 \
                 ! valve name=micvalve drop=true ! fdkaacenc ! queue ! mp4mux fragment-duration=2000 ! filesink location={} ",
                quote(&mic)
            ));
        }

        let pipeline = gst::parse::launch(&desc)
            .with_context(|| format!("build pipeline: {desc}"))?
            .downcast::<gst::Pipeline>()
            .map_err(|_| anyhow!("not a pipeline"))?;
        let appsrc = pipeline
            .by_name("video")
            .and_then(|e| e.downcast::<gst_app::AppSrc>().ok())
            .ok_or_else(|| anyhow!("appsrc missing"))?;
        let valves = ["sysvalve", "micvalve"].iter().filter_map(|n| pipeline.by_name(n)).collect();
        pipeline.set_state(gst::State::Playing).context("start pipeline")?;
        Ok(Self { pipeline, appsrc, valves, started: false, encoder_name: encoder_name.split(' ').next().unwrap_or("").into() })
    }

    /// Running time of the pipeline now, in ns.
    fn running_time(&self) -> Option<u64> {
        let clock = self.pipeline.clock()?;
        let base = self.pipeline.base_time()?;
        Some(clock.time().nseconds().saturating_sub(base.nseconds()))
    }

    /// At the first frame: puts video on the pipeline's running time (frame PTS + now) and opens the audio
    /// valves, so audio and video both start at this moment. The muxer keeps that common start as zero.
    fn start_audio(&mut self) {
        let running = self.running_time().unwrap_or(0);
        if let Some(pad) = self.appsrc.static_pad("src") {
            pad.set_offset(running as i64);
        }
        for valve in &self.valves {
            valve.set_property("drop", false);
        }
    }

    /// Pushes one frame. `pts_ns` is on the recording clock (first frame = 0).
    pub fn push(&mut self, pts_ns: u64, frame: Vec<u8>) -> Result<()> {
        if !self.started {
            self.started = true;
            self.start_audio();
        }
        let mut buffer = gst::Buffer::from_mut_slice(frame);
        buffer.get_mut().unwrap().set_pts(gst::ClockTime::from_nseconds(pts_ns));
        self.appsrc.push_buffer(buffer).map_err(|e| anyhow!("push frame: {e:?}"))?;
        Ok(())
    }

    /// Fatal pipeline error since the last call, if any.
    pub fn poll_error(&self) -> Option<String> {
        let bus = self.pipeline.bus()?;
        while let Some(msg) = bus.pop_filtered(&[gst::MessageType::Error]) {
            if let gst::MessageView::Error(err) = msg.view() {
                return Some(format!("{} ({:?})", err.error(), err.debug()));
            }
        }
        None
    }

    /// Ends every stream and waits until the files are complete.
    pub fn finish(self) -> Result<()> {
        self.appsrc.end_of_stream().ok();
        for name in ["sysaudio", "mic"] {
            if let Some(src) = self.pipeline.by_name(name) {
                src.send_event(gst::event::Eos::new());
            }
        }
        let bus = self.pipeline.bus().ok_or_else(|| anyhow!("no bus"))?;
        let result = match bus.timed_pop_filtered(
            gst::ClockTime::from_seconds(15),
            &[gst::MessageType::Eos, gst::MessageType::Error],
        ) {
            Some(msg) => match msg.view() {
                gst::MessageView::Eos(_) => Ok(()),
                gst::MessageView::Error(err) => Err(anyhow!("encoder: {} ({:?})", err.error(), err.debug())),
                _ => Ok(()),
            },
            None => Err(anyhow!("encoder did not finish within 15 s")),
        };
        self.pipeline.set_state(gst::State::Null).ok();
        std::thread::sleep(Duration::from_millis(50));
        result
    }
}
