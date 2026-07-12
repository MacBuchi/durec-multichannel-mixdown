//! Print the analysis of a recording: per-channel peaks and detected BPM.
//!
//! Usage: cargo run -p durecmix-engine --release --example analyze_demo <in.wav>

use durecmix_engine::analysis;

fn main() -> anyhow::Result<()> {
    let input = std::env::args()
        .nth(1)
        .expect("usage: analyze_demo <in.wav>");
    let a = analysis::analyze(&input, 100)?;
    println!("{input}: {} channels", a.waveforms.len());
    match a.bpm {
        Some(bpm) => println!("  detected tempo: {bpm} BPM"),
        None => println!("  no clear tempo"),
    }
    Ok(())
}
