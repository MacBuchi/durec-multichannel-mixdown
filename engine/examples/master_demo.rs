//! Reference-mastering dev tool: master a stereo WAV against a reference
//! track exactly like the app's export path does.
//!
//! ```sh
//! cargo run -p durecmix-engine --release --example master_demo -- \
//!     <target.wav> <reference.(wav|flac|mp3)> <out.wav> [ceiling_dbtp] [--no-limiter]
//! ```
//!
//! Output is 32-bit float WAV (headroom-safe for A/B and null tests). The
//! `--no-limiter` run exposes the pure matching stage (RMS + matching EQ +
//! width) for algorithm comparisons.

use durecmix_engine::mix::TrackParams;
use durecmix_engine::reference::analyze_reference;
use durecmix_engine::render::{render_io, LoudnessMode, OutputFormat, RenderSettings};
use durecmix_engine::sink::OutputHandle;
use durecmix_engine::wav::InputHandle;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let positional: Vec<&String> = args[1..].iter().filter(|a| !a.starts_with("--")).collect();
    if positional.len() < 3 {
        eprintln!(
            "usage: master_demo <target.wav> <reference> <out.wav> [ceiling_dbtp] [--no-limiter]"
        );
        std::process::exit(2);
    }
    let (target, reference, out) = (positional[0], positional[1], positional[2]);
    let ceiling: f64 = positional
        .get(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(-1.0);
    let limiter = !args.iter().any(|a| a == "--no-limiter");

    eprintln!("analyzing reference {reference} …");
    let profile = analyze_reference(&InputHandle::Path(reference.clone()), |_| {})
        .expect("reference analysis");
    eprintln!(
        "reference: {:.0} Hz, {:.1} s, mid RMS {:.1} dBFS",
        profile.sample_rate,
        profile.duration_seconds,
        20.0 * profile.mid_rms.log10()
    );

    // A stereo file mastered as-is: two hard-panned unity tracks reproduce
    // the file's L/R signal on the mix bus (constant-power pan hits gain 1.0
    // at the extremes).
    let tracks = vec![
        TrackParams::new(1, "L".to_string(), -1.0),
        TrackParams::new(2, "R".to_string(), 1.0),
    ];
    let settings = RenderSettings {
        loudness: LoudnessMode::None, // bypassed while mastering anyway
        format: OutputFormat::Wav32Float,
        limiter_enabled: limiter,
        ceiling_dbtp: ceiling,
        dither: false,
        ..RenderSettings::default()
    };

    eprintln!(
        "mastering {target} → {out} (limiter: {}, ceiling {ceiling} dBTP) …",
        if limiter { "on" } else { "OFF" }
    );
    let report = render_io(
        &InputHandle::Path(target.clone()),
        &tracks,
        &settings,
        Some(&profile),
        &OutputHandle::Path(out.clone()),
        |_| {},
    )
    .expect("mastering render");
    println!(
        "done: {:.1} LUFS-I, TP {:.2} dBTP, LRA {:.1} LU, mastering gain {:+.2} dB (source {:.1} LUFS)",
        report.integrated_lufs,
        report.true_peak_dbtp,
        report.lra_lu,
        report.mastering_gain_db,
        report.source_integrated_lufs,
    );
}
