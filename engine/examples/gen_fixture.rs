//! Generate a small deterministic DUREC-like multichannel WAV for tests.
//!
//! Real DUREC recordings are multi-GB and must never be used in automated
//! tests; this fixture mimics their structure (24-bit PCM, iXML track list
//! with stereo pairs and monitor buses) at a few megabytes.
//!
//! Usage: `cargo run -p durecmix-engine --example gen_fixture [out.wav]`
//!
//! Layout (8 ch, 24-bit, 44.1 kHz, 5 s):
//!   1 Vocals    440 Hz sine at −12 dBFS
//!   2 Kick       55 Hz sine at −6 dBFS  (HPF test target)
//!   3 Keys L    330 Hz sine at −18 dBFS (stereo pair, pans hard L)
//!   4 Keys R    331 Hz sine at −18 dBFS (stereo pair, pans hard R)
//!   5 Gtr       220 Hz sine at −15 dBFS
//!   6 Bass      110 Hz sine at −9 dBFS
//!   7 Phones L 1000 Hz sine at −3 dBFS  (monitor bus, excluded in real mixes)
//!   8 Out L    1000 Hz sine at −3 dBFS  (monitor bus, excluded in real mixes)

use std::f64::consts::TAU;

const SAMPLE_RATE: u32 = 44_100;
const SECONDS: u32 = 5;
const CHANNELS: usize = 8;
const FULL_SCALE: f64 = 8_388_607.0; // 24-bit

const TRACKS: [(&str, f64, f64); CHANNELS] = [
    ("Vocals", 440.0, -12.0),
    ("Kick", 55.0, -6.0),
    ("Keys L", 330.0, -18.0),
    ("Keys R", 331.0, -18.0),
    ("Gtr", 220.0, -15.0),
    ("Bass", 110.0, -9.0),
    ("Phones L", 1000.0, -3.0),
    ("Out L", 1000.0, -3.0),
];

fn chunk(id: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + payload.len() + 1);
    out.extend_from_slice(id);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    if payload.len() % 2 == 1 {
        out.push(0);
    }
    out
}

fn ixml() -> String {
    let mut tracks = String::new();
    for (i, (name, _, _)) in TRACKS.iter().enumerate() {
        let idx = i + 1;
        tracks.push_str(&format!(
            "<TRACK><CHANNEL_INDEX>{idx}</CHANNEL_INDEX>\
             <INTERLEAVE_INDEX>{idx}</INTERLEAVE_INDEX>\
             <NAME>{name}</NAME></TRACK>"
        ));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><BWFXML>\
         <IXML_VERSION>1.5</IXML_VERSION><TRACK_LIST>\
         <TRACK_COUNT>{CHANNELS}</TRACK_COUNT>{tracks}</TRACK_LIST></BWFXML>"
    )
}

fn main() {
    let out_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "fixture_8ch.wav".into());

    let frames = (SAMPLE_RATE * SECONDS) as usize;
    let mut data = Vec::with_capacity(frames * CHANNELS * 3);
    for n in 0..frames {
        let t = n as f64 / SAMPLE_RATE as f64;
        for (_, freq, dbfs) in TRACKS {
            let amp = 10f64.powf(dbfs / 20.0);
            let sample = (amp * (TAU * freq * t).sin() * FULL_SCALE) as i32;
            data.extend_from_slice(&sample.to_le_bytes()[0..3]);
        }
    }

    let block_align = (CHANNELS * 3) as u16;
    let mut fmt = Vec::new();
    fmt.extend_from_slice(&1u16.to_le_bytes()); // PCM
    fmt.extend_from_slice(&(CHANNELS as u16).to_le_bytes());
    fmt.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    fmt.extend_from_slice(&(SAMPLE_RATE * block_align as u32).to_le_bytes());
    fmt.extend_from_slice(&block_align.to_le_bytes());
    fmt.extend_from_slice(&24u16.to_le_bytes());

    let mut body = Vec::new();
    body.extend_from_slice(b"WAVE");
    body.extend(chunk(b"fmt ", &fmt));
    body.extend(chunk(b"data", &data));
    body.extend(chunk(b"iXML", ixml().as_bytes()));

    let mut file = Vec::new();
    file.extend_from_slice(b"RIFF");
    file.extend_from_slice(&(body.len() as u32).to_le_bytes());
    file.extend(body);

    std::fs::write(&out_path, &file).expect("write fixture");
    println!(
        "wrote {out_path}: {CHANNELS} ch, 24-bit, {SAMPLE_RATE} Hz, {SECONDS} s ({} bytes)",
        file.len()
    );
    for (i, (name, freq, dbfs)) in TRACKS.iter().enumerate() {
        println!("  {}: {name} — {freq} Hz at {dbfs} dBFS", i + 1);
    }
}
