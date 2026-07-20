//! Reference-track decoding and analysis.
//!
//! Decodes any Symphonia-supported format (WAV, FLAC, MP3, OGG/Vorbis) from
//! a path or a raw fd (Android SAF) and streams it through
//! [`MasteringAnalyzer`] to produce a [`ReferenceProfile`]. The file is never
//! buffered whole, so an hours-long reference works on a phone.

use std::fs::File;
use std::path::Path;

use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

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
    let mut format = symphonia::default::get_probe()
        .probe(
            &hint,
            stream,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|e| ref_err("unsupported reference format", e))?;

    // `default_track` falls back to the first track with a known codec, so a
    // container that flags nothing (plain WAV/MP3) still resolves.
    let track = format
        .default_track(TrackType::Audio)
        .ok_or_else(|| EngineError::Mastering("reference has no audio track".into()))?;
    let track_id = track.id;
    // Timing moved from the codec parameters onto the track in Symphonia 0.6.
    let total_frames = track.num_frames;
    let audio_params = track
        .codec_params
        .as_ref()
        .and_then(|p| p.audio())
        .ok_or_else(|| EngineError::Mastering("reference has no audio track".into()))?;
    let sample_rate = audio_params
        .sample_rate
        .ok_or_else(|| EngineError::Mastering("reference sample rate unknown".into()))?;
    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(audio_params, &AudioDecoderOptions::default())
        .map_err(|e| ref_err("unsupported reference codec", e))?;

    let mut analyzer = MasteringAnalyzer::new(sample_rate);
    let mut samples: Vec<f64> = Vec::new();
    let mut stereo: Vec<f64> = Vec::new();
    let mut decoded_frames: u64 = 0;
    let mut next_progress: u64 = 0;

    loop {
        let packet = match format.next_packet() {
            // Since 0.6 a clean end of stream is `Ok(None)` rather than an
            // unexpected-EOF I/O error. Chained/reset streams still end the
            // analysis — the profile is statistical, a partial one is fine.
            Ok(Some(p)) => p,
            Ok(None) => break,
            Err(SymError::ResetRequired) => break,
            Err(e) => return Err(ref_err("reference read failed", e)),
        };
        if packet.track_id != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            // A corrupt packet (common at MP3 stream edges) is skipped, not
            // fatal — the profile is statistical.
            Err(SymError::DecodeError(_)) => continue,
            Err(e) => return Err(ref_err("reference decode failed", e)),
        };

        let channels = decoded.spec().channels().count();
        if channels == 0 {
            continue;
        }
        // 0.6 sizes the destination itself, so the manual capacity juggling
        // the old SampleBuffer needed is gone. Conversion to f64 is implied.
        decoded.copy_to_vec_interleaved(&mut samples);
        let frames = samples.len() / channels;

        stereo.clear();
        stereo.reserve(frames * 2);
        match channels {
            1 => {
                for &s in &samples {
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
