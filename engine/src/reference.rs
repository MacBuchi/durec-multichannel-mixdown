//! Reference-track decoding and analysis.
//!
//! Decodes any Symphonia-supported format (WAV, FLAC, MP3, OGG/Vorbis) from
//! a path or a raw fd (Android SAF) and streams it through
//! [`MasteringAnalyzer`] to produce a [`ReferenceProfile`]. The file is never
//! buffered whole, so an hours-long reference works on a phone.

use std::fs::File;
use std::path::Path;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::error::{EngineError, Result};
use crate::mastering::{MasteringAnalyzer, ReferenceProfile};
use crate::wav::InputHandle;

fn ref_err(what: &str, e: impl std::fmt::Display) -> EngineError {
    EngineError::Mastering(format!("{what}: {e}"))
}

/// Decode `input` and analyze it into a reference profile. `progress` is
/// called with 0..=1 (only when the container reports its length).
pub fn analyze_reference(
    input: &InputHandle,
    mut progress: impl FnMut(f32),
) -> Result<ReferenceProfile> {
    let mut hint = Hint::new();
    let file = match input {
        InputHandle::Path(p) => {
            if let Some(ext) = Path::new(p).extension().and_then(|e| e.to_str()) {
                hint.with_extension(ext);
            }
            File::open(p)?
        }
        #[cfg(unix)]
        InputHandle::Fd(fd) => {
            use std::os::fd::FromRawFd;
            // Safety: the platform layer hands us exclusive ownership of a
            // freshly opened descriptor (same contract as WAV loading).
            unsafe { File::from_raw_fd(*fd) }
        }
        #[cfg(not(unix))]
        InputHandle::Fd(_) => {
            return Err(EngineError::Mastering(
                "fd input is only supported on unix platforms".into(),
            ))
        }
    };

    let stream = MediaSourceStream::new(Box::new(file), Default::default());
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            stream,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| ref_err("unsupported reference format", e))?;
    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| EngineError::Mastering("reference has no audio track".into()))?;
    let track_id = track.id;
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| EngineError::Mastering("reference sample rate unknown".into()))?;
    let total_frames = track.codec_params.n_frames;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| ref_err("unsupported reference codec", e))?;

    let mut analyzer = MasteringAnalyzer::new(sample_rate);
    let mut sample_buf: Option<SampleBuffer<f64>> = None;
    let mut stereo: Vec<f64> = Vec::new();
    let mut decoded_frames: u64 = 0;
    let mut next_progress: u64 = 0;

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            // Symphonia signals a clean end of stream as an unexpected-EOF
            // I/O error; chained/reset streams end the analysis too.
            Err(SymError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(SymError::ResetRequired) => break,
            Err(e) => return Err(ref_err("reference read failed", e)),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            // A corrupt packet (common at MP3 stream edges) is skipped, not
            // fatal — the profile is statistical.
            Err(SymError::DecodeError(_)) => continue,
            Err(e) => return Err(ref_err("reference decode failed", e)),
        };

        let spec = *decoded.spec();
        let channels = spec.channels.count();
        if channels == 0 {
            continue;
        }
        let buf = sample_buf
            .get_or_insert_with(|| SampleBuffer::<f64>::new(decoded.capacity() as u64, spec));
        if buf.capacity() < decoded.capacity() * channels {
            *buf = SampleBuffer::<f64>::new(decoded.capacity() as u64, spec);
        }
        buf.copy_interleaved_ref(decoded);
        let samples = buf.samples();
        let frames = samples.len() / channels;

        stereo.clear();
        stereo.reserve(frames * 2);
        match channels {
            1 => {
                for &s in samples {
                    stereo.push(s);
                    stereo.push(s);
                }
            }
            // For >2 channels use the first two (front L/R) — surround
            // references are exotic and the profile is statistical.
            _ => {
                for fr in samples.chunks_exact(channels) {
                    stereo.push(fr[0]);
                    stereo.push(fr[1]);
                }
            }
        }
        analyzer.push(&stereo);
        decoded_frames += frames as u64;

        if let Some(total) = total_frames {
            if decoded_frames >= next_progress && total > 0 {
                progress((decoded_frames as f64 / total as f64).min(1.0) as f32);
                next_progress = decoded_frames + sample_rate as u64;
            }
        }
    }

    if decoded_frames == 0 {
        return Err(EngineError::Mastering(
            "could not decode any audio from the reference".into(),
        ));
    }
    progress(1.0);
    Ok(ReferenceProfile::from_stats(&analyzer.finish()))
}
