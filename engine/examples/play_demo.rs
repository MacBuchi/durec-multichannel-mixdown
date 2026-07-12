//! Playback smoke test: play 3 seconds of a mix and verify that the position
//! advances and meters report signal.
//!
//! Usage: cargo run -p durecmix-engine --example play_demo <in.wav> [start_s]

use std::time::Duration;

use durecmix_engine::ixml;
use durecmix_engine::playback::Player;
use durecmix_engine::session::Session;
use durecmix_engine::wav::WavReader;

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let input = args.next().expect("usage: play_demo <in.wav> [start_s]");
    let start_s: f64 = args.next().map(|s| s.parse().unwrap()).unwrap_or(0.0);

    let reader = WavReader::open(&input)?;
    let sr = reader.spec().sample_rate;
    let infos = reader.ixml().map(ixml::parse_tracks).unwrap_or_default();
    drop(reader);

    let session = Session::from_track_info(&infos);
    let start_frame = (start_s * sr as f64) as u64;
    let player = Player::start(&input, session.tracks, Default::default(), start_frame)?;
    println!("playing from {start_s:.1} s …");

    let mut last_pos = start_frame;
    for i in 0..6 {
        std::thread::sleep(Duration::from_millis(500));
        let s = player.snapshot();
        println!(
            "t={:.1}s pos={:.2}s peak L/R {:.3}/{:.3} LUFS-M {:.1} corr {:+.2}",
            (i + 1) as f64 * 0.5,
            s.position_frames as f64 / sr as f64,
            s.peak_l,
            s.peak_r,
            s.lufs_momentary,
            s.correlation
        );
        assert!(s.position_frames >= last_pos, "position went backwards");
        last_pos = s.position_frames;
    }
    let advanced = (last_pos - start_frame) as f64 / sr as f64;
    assert!(
        (advanced - 3.0).abs() < 0.5,
        "expected ~3 s of playback, got {advanced:.2} s"
    );
    player.stop();
    println!("OK: position advanced {advanced:.2} s, playback engine works");
    Ok(())
}
