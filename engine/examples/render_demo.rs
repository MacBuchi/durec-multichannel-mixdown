//! End-to-end smoke test: load a multichannel WAV, print its track metadata,
//! render a stereo mix and report the result.
//!
//! Usage: cargo run -p durecmix-engine --example render_demo <in.wav> <out.wav> [lufs_target]
//! With `lufs_target` (e.g. -16) the mix is normalised to integrated LUFS
//! with the −1 dBTP limiter; otherwise peak-normalised to −1 dBFS.

use durecmix_engine::ixml;
use durecmix_engine::render::{render_to_wav, LoudnessMode, OutputFormat, RenderSettings};
use durecmix_engine::session::Session;
use durecmix_engine::wav::WavReader;

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let input = args.next().expect("usage: render_demo <in.wav> <out.wav>");
    let output = args.next().expect("usage: render_demo <in.wav> <out.wav>");

    let reader = WavReader::open(&input)?;
    let spec = reader.spec();
    println!(
        "{input}: {} ch, {} Hz, {}-bit, {:.2} s, {} frames",
        spec.channels,
        spec.sample_rate,
        spec.bits_per_sample,
        reader.duration_seconds(),
        reader.num_frames()
    );

    let infos = reader.ixml().map(ixml::parse_tracks).unwrap_or_default();
    for t in &infos {
        println!(
            "  track {}: {} (pan {:+.1})",
            t.index,
            t.name,
            ixml::default_pan_for_name(&t.name)
        );
    }

    let session = Session::from_track_info(&infos);
    let loudness = match args.next() {
        Some(lufs) => LoudnessMode::LufsIntegrated(lufs.parse()?),
        None => LoudnessMode::PeakDbfs(-1.0),
    };
    let settings = RenderSettings {
        loudness,
        format: OutputFormat::Wav24,
        ..RenderSettings::default()
    };
    let report = render_to_wav(&input, &session.tracks, &settings, &output, |_| {})?;
    println!(
        "rendered {output}: raw peak {:.2} dBFS, applied {:+.2} dB, {:.2} s @ {} Hz",
        report.peak_dbfs_before,
        report.gain_applied_db,
        report.duration_seconds,
        report.sample_rate
    );
    println!(
        "  source {:.1} LUFS-I | delivered {:.1} LUFS-I, TP {:.2} dBTP, LRA {:.1} LU",
        report.source_integrated_lufs, report.integrated_lufs, report.true_peak_dbtp, report.lra_lu
    );
    Ok(())
}
