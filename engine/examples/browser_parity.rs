//! Does the browser write the same file as the app — on a *real* take?
//!
//! Usage: cargo run -p durecmix-engine --release --example browser_parity <in.wav>
//!
//! The equality tests in `engine/tests` prove this on synthetic fixtures: two
//! channels, a few seconds, a textbook WAV header. A real DUREC recording is
//! none of those things — 34 channels, 24-bit, around a gigabyte, iXML sitting
//! *behind* the audio payload, and RF64 sizes once it passes 4 GB. That is the
//! shape the PWA actually meets, and nothing had ever driven it through the
//! byte-block path until this example existed.
//!
//! Three comparisons, each between the way the app does it (a file loop) and
//! the way the browser has to (Dart slices the `Blob` and pushes):
//!
//! 1. the rendered file, byte for byte,
//! 2. the level scan that the export-level preview derives its gain from,
//! 3. the mastering analysis behind the mastered preview.
//!
//! Deliberately an example and not a test: it wants a multi-GB recording, and
//! automated tests must never touch those (see AGENTS.md).

use durecmix_engine::ixml;
use durecmix_engine::mix::HpfSlope;
use durecmix_engine::render::{
    analyze_mix_level, analyze_mix_mastering, render_to_file, LoudnessMode, MixScan, OutputFormat,
    RenderSettings, StreamRender,
};
use durecmix_engine::session::Session;
use durecmix_engine::wav::{self, InputHandle, WavReader};

/// What Dart pushes per bridge call (`range_render.dart`, `range_scan.dart`).
const BLOCK: usize = 4 * 1024 * 1024;

fn main() -> anyhow::Result<()> {
    let input = std::env::args()
        .nth(1)
        .expect("usage: browser_parity <in.wav>");

    let reader = WavReader::open(&input)?;
    let spec = reader.spec();
    let frames = reader.num_frames();
    println!(
        "{input}\n  {} ch · {} Hz · {}-bit · {:.1} s · {} frames",
        spec.channels,
        spec.sample_rate,
        spec.bits_per_sample,
        reader.duration_seconds(),
        frames
    );

    // The mix the app would start from, then bent out of shape on purpose: a
    // render where every track sits at unity would pass even if the two paths
    // disagreed about gain, pan or EQ.
    let infos = reader.ixml().map(ixml::parse_tracks).unwrap_or_default();
    let mut session = Session::from_track_info(&infos);
    for (i, t) in session.tracks.iter_mut().enumerate() {
        t.gain_db = -3.0 - (i % 7) as f64;
        if i % 3 == 0 {
            t.pan = if i % 2 == 0 { -0.7 } else { 0.6 };
        }
        if i % 5 == 0 {
            t.eq.hpf_enabled = true;
            t.eq.hpf_freq = 80.0;
            t.eq.hpf_slope = HpfSlope::Db24;
            t.eq.low.enabled = true;
            t.eq.low.gain_db = -2.5;
        }
        if i % 11 == 0 {
            t.muted = true; // metered but silent — the asymmetry in #115
        }
    }
    println!(
        "  {} tracks, mix bent (gain/pan/EQ/mute)",
        session.tracks.len()
    );

    // A trim that starts and ends mid-file, so the browser's "slice the bytes"
    // arithmetic has to agree with the file loop's seek.
    let trim_start = (spec.sample_rate as u64).min(frames / 4);
    let trim_end = frames
        .saturating_sub(spec.sample_rate as u64 * 2)
        .max(trim_start + 1);

    let mut failures = 0;
    for format in [OutputFormat::Wav24, OutputFormat::Flac24] {
        let settings = RenderSettings {
            loudness: LoudnessMode::LufsIntegrated(-16.0),
            format,
            limiter_enabled: true,
            dither: true,
            trim_start_frame: trim_start,
            trim_end_frame: Some(trim_end),
            fade_in_ms: 80.0,
            fade_out_ms: 80.0,
            ..RenderSettings::default()
        };
        failures += compare_render(&input, &session, &settings, format)?;
    }
    failures += compare_scans(&input, &session)?;

    if failures == 0 {
        println!("\n✓ the browser's paths match the app's on this take");
        Ok(())
    } else {
        anyhow::bail!("{failures} comparison(s) differed — see above")
    }
}

/// Locate the `data` payload and hand back the byte range the browser pushes.
fn payload_range(path: &str, settings: &RenderSettings, spec: &wav::WavSpec) -> (u64, u64, u64) {
    let bytes = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let file = std::fs::read(path).expect("read for chunk scan");
    let chunks = wav::scan_chunks(&file, 0, bytes)
        .expect("scan chunks")
        .chunks;
    let data = chunks.iter().find(|c| c.id == "data").expect("data chunk");
    let bpf = spec.bytes_per_frame() as u64;
    // No trim end means "to the end of the payload" — exactly what Dart does
    // when the user never set a trim point.
    let total = data.size / bpf;
    let start = data.offset + settings.trim_start_frame.min(total) * bpf;
    let end = data.offset + settings.trim_end_frame.unwrap_or(total).min(total) * bpf;
    (start, end, bpf)
}

fn compare_render(
    input: &str,
    session: &Session,
    settings: &RenderSettings,
    format: OutputFormat,
) -> anyhow::Result<u32> {
    let dir = std::env::temp_dir();
    let native_path = dir.join(format!("durecmix_parity_{format:?}.bin"));
    println!("\n{format:?}");

    let t0 = std::time::Instant::now();
    let native_report = render_to_file(
        input,
        &session.tracks,
        settings,
        native_path.to_str().unwrap(),
        |_| {},
    )?;
    let native = std::fs::read(&native_path)?;
    println!(
        "  file loop:  {:>12} bytes in {:.1} s",
        native.len(),
        t0.elapsed().as_secs_f64()
    );

    let reader = WavReader::open(input)?;
    let spec = reader.spec();
    drop(reader);
    let (start, end, bpf) = payload_range(input, settings, &spec);
    let range_frames = (end - start) / bpf;

    // The fmt chunk as Dart passes it.
    let head = std::fs::read(input)?;
    let chunks = wav::scan_chunks(&head, 0, head.len() as u64)?.chunks;
    let fmt = chunks.iter().find(|c| c.id == "fmt ").expect("fmt chunk");
    let fmt_chunk = &head[fmt.offset as usize..][..fmt.size as usize];
    let payload = &head[start as usize..end as usize];

    let t1 = std::time::Instant::now();
    let mut render = StreamRender::new(
        wav::spec_from_fmt_chunk(fmt_chunk)?,
        range_frames,
        session.tracks.clone(),
        settings.clone(),
        None,
    )?;
    for block in payload.chunks(BLOCK) {
        render.push_pass1(block)?;
    }
    render.start_pass2()?;
    let mut body = Vec::new();
    for block in payload.chunks(BLOCK) {
        body.extend_from_slice(&render.push_pass2(block)?);
    }
    let out = render.finish()?;
    let mut streamed = out.head;
    streamed.extend_from_slice(&body);
    streamed.extend_from_slice(&out.tail);
    println!(
        "  byte blocks:{:>12} bytes in {:.1} s",
        streamed.len(),
        t1.elapsed().as_secs_f64()
    );

    let _ = std::fs::remove_file(&native_path);
    if streamed == native {
        println!("  ✓ byte-identical");
        return Ok(0);
    }
    if streamed.len() != native.len() {
        println!("  ✗ LENGTH differs: {} vs {}", streamed.len(), native.len());
    } else {
        let at = streamed
            .iter()
            .zip(&native)
            .position(|(a, b)| a != b)
            .unwrap_or(0);
        println!(
            "  ✗ first difference at byte {at} ({:#04x} vs {:#04x}); report gain {:+.3} vs {:+.3} dB",
            streamed[at], native[at], out.report.gain_applied_db, native_report.gain_applied_db
        );
    }
    Ok(1)
}

/// The two analyses the preview depends on — the level the export-level
/// preview scales by, and the mastering plan's spectral input.
fn compare_scans(input: &str, session: &Session) -> anyhow::Result<u32> {
    let settings = RenderSettings {
        loudness: LoudnessMode::LufsIntegrated(-16.0),
        ..RenderSettings::default()
    };
    let handle = InputHandle::Path(input.to_string());
    println!("\nanalyses");

    let by_file = analyze_mix_level(&handle, &session.tracks, &settings, |_| {})?;
    let stats_file = analyze_mix_mastering(&handle, &session.tracks, &settings, |_| {})?;

    let reader = WavReader::open(input)?;
    let spec = reader.spec();
    drop(reader);
    let (start, end, bpf) = payload_range(input, &settings, &spec);
    let file = std::fs::read(input)?;
    let chunks = wav::scan_chunks(&file, 0, file.len() as u64)?.chunks;
    let fmt = chunks.iter().find(|c| c.id == "fmt ").expect("fmt chunk");
    let spec_parsed = wav::spec_from_fmt_chunk(&file[fmt.offset as usize..][..fmt.size as usize])?;
    let payload = &file[start as usize..end as usize];
    let range_frames = (end - start) / bpf;

    let mut failures = 0;

    let mut level_scan =
        MixScan::new(spec_parsed, range_frames, &session.tracks, &settings, false)?;
    for block in payload.chunks(BLOCK) {
        level_scan.push(block)?;
    }
    let by_push = level_scan.finish_level();
    if by_file.peak == by_push.peak
        && (by_file.integrated_lufs - by_push.integrated_lufs).abs() < 1e-9
    {
        println!(
            "  ✓ level scan matches (peak {:.6}, {:.3} LUFS)",
            by_push.peak, by_push.integrated_lufs
        );
    } else {
        println!(
            "  ✗ level scan differs: peak {:.9} vs {:.9}, LUFS {:.9} vs {:.9}",
            by_push.peak, by_file.peak, by_push.integrated_lufs, by_file.integrated_lufs
        );
        failures += 1;
    }

    let mut stats_scan = MixScan::new(spec_parsed, range_frames, &session.tracks, &settings, true)?;
    for block in payload.chunks(BLOCK) {
        stats_scan.push(block)?;
    }
    let stats_push = stats_scan.finish_stats()?;
    let worst = stats_file
        .mid_spectrum
        .iter()
        .zip(&stats_push.mid_spectrum)
        .map(|(a, b)| (a - b).abs())
        .fold(0.0f64, |worst, d| worst.max(d));
    if worst < 1e-6 && (stats_file.mid_rms - stats_push.mid_rms).abs() < 1e-9 {
        println!("  ✓ mastering analysis matches (worst bin Δ {worst:.3e})");
    } else {
        println!("  ✗ mastering analysis differs: worst bin Δ {worst:.3e}");
        failures += 1;
    }
    Ok(failures)
}
