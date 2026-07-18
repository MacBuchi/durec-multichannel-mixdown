use std::io::Cursor;

use durecmix_engine::chain::{ChainConfig, MixChain};
use durecmix_engine::dsp::biquad::{Biquad, BiquadCoeffs, BUTTERWORTH_2ND_Q, BUTTERWORTH_4TH_Q};
use durecmix_engine::dsp::dither::TpdfDither;
use durecmix_engine::dsp::limiter::{LimiterParams, TruePeakLimiter};
use durecmix_engine::dsp::{db_to_linear, linear_to_db, pan_gains, GAIN_FLOOR_DB};
use durecmix_engine::ixml::{
    clean_xml, default_pan_for_name, parse_tracks, stereo_pair_base, TrackInfo,
};
use durecmix_engine::mix::{EqBand, HpfSlope, MixBus, TrackEq, TrackParams};
use durecmix_engine::render::{render_to_file, LoudnessMode, OutputFormat, RenderSettings};
use durecmix_engine::session::Session;
use durecmix_engine::wav::{self, InputHandle, SampleFormat, WavReader};
use durecmix_engine::EngineError;

// ── test WAV builders ───────────────────────────────────────────────────────

fn chunk(id: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(id);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    if payload.len() % 2 == 1 {
        out.push(0);
    }
    out
}

fn fmt_payload(format_tag: u16, channels: u16, sample_rate: u32, bits: u16) -> Vec<u8> {
    let block_align = channels * bits / 8;
    let mut p = Vec::new();
    p.extend_from_slice(&format_tag.to_le_bytes());
    p.extend_from_slice(&channels.to_le_bytes());
    p.extend_from_slice(&sample_rate.to_le_bytes());
    p.extend_from_slice(&(sample_rate * block_align as u32).to_le_bytes());
    p.extend_from_slice(&block_align.to_le_bytes());
    p.extend_from_slice(&bits.to_le_bytes());
    p
}

/// Interleaved 16-bit PCM RIFF WAV with an optional iXML chunk after data.
fn wav16(channels: u16, sample_rate: u32, samples: &[i16], ixml: Option<&str>) -> Vec<u8> {
    let data: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    let mut body = Vec::new();
    body.extend_from_slice(b"WAVE");
    body.extend(chunk(b"fmt ", &fmt_payload(1, channels, sample_rate, 16)));
    body.extend(chunk(b"data", &data));
    if let Some(x) = ixml {
        body.extend(chunk(b"iXML", x.as_bytes()));
    }
    let mut out = Vec::new();
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend(body);
    out
}

/// 24-bit PCM RIFF WAV from raw i32 sample values (−8388608..8388607).
fn wav24(channels: u16, sample_rate: u32, samples: &[i32]) -> Vec<u8> {
    let mut data = Vec::new();
    for s in samples {
        data.extend_from_slice(&s.to_le_bytes()[0..3]);
    }
    let mut body = Vec::new();
    body.extend_from_slice(b"WAVE");
    body.extend(chunk(b"fmt ", &fmt_payload(1, channels, sample_rate, 24)));
    body.extend(chunk(b"data", &data));
    let mut out = Vec::new();
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend(body);
    out
}

/// RF64 file: data chunk size is 0xFFFFFFFF, real size lives in ds64.
fn rf64_16(channels: u16, sample_rate: u32, samples: &[i16]) -> Vec<u8> {
    let data: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    let mut ds64 = Vec::new();
    ds64.extend_from_slice(&0u64.to_le_bytes()); // riff size (unused here)
    ds64.extend_from_slice(&(data.len() as u64).to_le_bytes()); // data size
    ds64.extend_from_slice(&0u64.to_le_bytes()); // sample count
    ds64.extend_from_slice(&0u32.to_le_bytes()); // table length

    let mut body = Vec::new();
    body.extend_from_slice(b"WAVE");
    body.extend(chunk(b"ds64", &ds64));
    body.extend(chunk(b"fmt ", &fmt_payload(1, channels, sample_rate, 16)));
    body.extend_from_slice(b"data");
    body.extend_from_slice(&u32::MAX.to_le_bytes());
    body.extend_from_slice(&data);
    if data.len() % 2 == 1 {
        body.push(0);
    }

    let mut out = Vec::new();
    out.extend_from_slice(b"RF64");
    out.extend_from_slice(&u32::MAX.to_le_bytes());
    out.extend(body);
    out
}

const DUREC_IXML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<BWFXML><IXML_VERSION>1.5</IXML_VERSION>
<TRACK_LIST><TRACK_COUNT>3</TRACK_COUNT>
<TRACK><CHANNEL_INDEX>2</CHANNEL_INDEX><INTERLEAVE_INDEX>2</INTERLEAVE_INDEX><NAME>Drums OH L</NAME></TRACK>
<TRACK><CHANNEL_INDEX>1</CHANNEL_INDEX><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME>Vocals</NAME></TRACK>
<TRACK><CHANNEL_INDEX>3</CHANNEL_INDEX><INTERLEAVE_INDEX>3</INTERLEAVE_INDEX><NAME>Drums OH R</NAME></TRACK>
</TRACK_LIST></BWFXML>"#;

// ── ixml ────────────────────────────────────────────────────────────────────

#[test]
fn clean_xml_strips_junk_prefix() {
    let dirty = format!("garbage\x00\x01{DUREC_IXML}");
    let cleaned = clean_xml(&dirty);
    assert!(cleaned.starts_with("<?xml"));
    assert!(!cleaned.contains('\x00'));
}

#[test]
fn clean_xml_without_xml_marker_returns_empty() {
    assert_eq!(clean_xml("no xml here"), "");
    assert_eq!(clean_xml(""), "");
}

#[test]
fn clean_xml_preserves_utf8_names() {
    let xml = "<?xml version=\"1.0\"?><NAME>Gesang Männer</NAME>";
    assert!(clean_xml(xml).contains("Männer"));
}

#[test]
fn parse_tracks_reads_durec_ixml_sorted_by_index() {
    let tracks = parse_tracks(DUREC_IXML);
    assert_eq!(
        tracks,
        vec![
            TrackInfo {
                index: 1,
                name: "Vocals".into()
            },
            TrackInfo {
                index: 2,
                name: "Drums OH L".into()
            },
            TrackInfo {
                index: 3,
                name: "Drums OH R".into()
            },
        ]
    );
}

#[test]
fn parse_tracks_handles_padded_chunk_payload() {
    let padded = format!("\x00\x00{DUREC_IXML}\x00\x00\x00");
    assert_eq!(parse_tracks(&padded).len(), 3);
}

#[test]
fn parse_tracks_malformed_returns_empty() {
    assert!(parse_tracks("<?xml version=\"1.0\"?><OPEN>").is_empty());
    assert!(parse_tracks("").is_empty());
}

#[test]
fn pan_heuristic_matches_old_tool() {
    assert_eq!(default_pan_for_name("Drums OH L"), -1.0);
    assert_eq!(default_pan_for_name("Drums OH R"), 1.0);
    assert_eq!(default_pan_for_name("Vocals"), 0.0);
    assert_eq!(default_pan_for_name("REAL"), 0.0); // suffix must be " R"
}

#[test]
fn stereo_pair_base_detects_pairs() {
    assert_eq!(stereo_pair_base("OH L"), Some("OH"));
    assert_eq!(stereo_pair_base("OH R"), Some("OH"));
    assert_eq!(stereo_pair_base("Vocals"), None);
}

// ── dsp: biquads ────────────────────────────────────────────────────────────

/// RMS of a sine pushed through a filter, skipping the first second so the
/// transient settles — cross-checks `process` against `magnitude_at`.
fn filtered_sine_gain_db(coeffs: BiquadCoeffs, sr: f64, freq: f64) -> f64 {
    let mut bq = Biquad::new(coeffs);
    let n = (sr * 2.0) as usize;
    let skip = (sr) as usize;
    let mut sum = 0.0;
    for i in 0..n {
        let x = (std::f64::consts::TAU * freq * i as f64 / sr).sin();
        let y = bq.process(x);
        if i >= skip {
            sum += y * y;
        }
    }
    let rms = (sum / (n - skip) as f64).sqrt();
    linear_to_db(rms / std::f64::consts::FRAC_1_SQRT_2)
}

#[test]
fn hpf_response_spot_checks() {
    let sr = 44_100.0;
    // 12 dB/oct (Butterworth 2nd order): −3 dB at fc, ~−12 dB one octave below.
    let c = BiquadCoeffs::highpass(sr, 100.0, BUTTERWORTH_2ND_Q);
    assert!((linear_to_db(c.magnitude_at(sr, 100.0)) + 3.0).abs() < 0.2);
    assert!((linear_to_db(c.magnitude_at(sr, 50.0)) + 12.0).abs() < 1.0);
    assert!(linear_to_db(c.magnitude_at(sr, 1000.0)).abs() < 0.1);
    // time-domain agreement with the closed-form response
    assert!(
        (filtered_sine_gain_db(c, sr, 50.0) - linear_to_db(c.magnitude_at(sr, 50.0))).abs() < 0.3
    );

    // 24 dB/oct: two cascaded sections with 4th-order Butterworth Qs.
    let c1 = BiquadCoeffs::highpass(sr, 100.0, BUTTERWORTH_4TH_Q[0]);
    let c2 = BiquadCoeffs::highpass(sr, 100.0, BUTTERWORTH_4TH_Q[1]);
    let mag_db = |f: f64| linear_to_db(c1.magnitude_at(sr, f) * c2.magnitude_at(sr, f));
    assert!((mag_db(100.0) + 3.0).abs() < 0.2); // Butterworth: −3 dB at fc
    assert!((mag_db(50.0) + 24.0).abs() < 1.5);
    assert!(mag_db(1000.0).abs() < 0.1);
}

#[test]
fn peaking_gain_and_symmetry() {
    let sr = 48_000.0;
    let boost = BiquadCoeffs::peaking(sr, 1000.0, 6.0, 1.0);
    assert!((linear_to_db(boost.magnitude_at(sr, 1000.0)) - 6.0).abs() < 0.05);
    assert!(linear_to_db(boost.magnitude_at(sr, 20.0)).abs() < 0.1);
    assert!(linear_to_db(boost.magnitude_at(sr, 15_000.0)).abs() < 0.2);
    // A −6 dB cut is the exact complement of a +6 dB boost.
    let cut = BiquadCoeffs::peaking(sr, 1000.0, -6.0, 1.0);
    for f in [250.0, 500.0, 1000.0, 2000.0, 8000.0] {
        let product = boost.magnitude_at(sr, f) * cut.magnitude_at(sr, f);
        assert!((product - 1.0).abs() < 1e-9, "not complementary at {f} Hz");
    }
}

#[test]
fn shelf_response() {
    let sr = 44_100.0;
    let low = BiquadCoeffs::low_shelf(sr, 120.0, 6.0, BUTTERWORTH_2ND_Q);
    assert!((linear_to_db(low.magnitude_at(sr, 20.0)) - 6.0).abs() < 0.2);
    assert!(linear_to_db(low.magnitude_at(sr, 5000.0)).abs() < 0.1);
    let high = BiquadCoeffs::high_shelf(sr, 8000.0, -9.0, BUTTERWORTH_2ND_Q);
    assert!((linear_to_db(high.magnitude_at(sr, 20_000.0)) + 9.0).abs() < 0.3);
    assert!(linear_to_db(high.magnitude_at(sr, 200.0)).abs() < 0.1);
}

#[test]
fn biquad_stability_with_extreme_params() {
    let sr = 44_100.0;
    // Constructor clamps keep even absurd inputs stable.
    let cases = [
        BiquadCoeffs::highpass(sr, -50.0, 0.0),
        BiquadCoeffs::highpass(sr, 1e9, 1e9),
        BiquadCoeffs::peaking(sr, 0.0, 1e6, -5.0),
        BiquadCoeffs::low_shelf(sr, 1e9, -1e6, 1e9),
        BiquadCoeffs::high_shelf(sr, -1.0, 1e6, 0.0),
    ];
    for (i, c) in cases.iter().enumerate() {
        let mut bq = Biquad::new(*c);
        let mut x = 123456789u64;
        for _ in 0..44_100 {
            // xorshift* noise in −1..1
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            let noise =
                (x.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0;
            let y = bq.process(noise);
            assert!(y.is_finite(), "case {i} produced non-finite output");
            assert!(y.abs() < 1e6, "case {i} diverged");
        }
    }
}

// ── dsp: gain/pan ───────────────────────────────────────────────────────────

// ── chain ───────────────────────────────────────────────────────────────────

/// Deterministic pseudo-noise in −1..1 (xorshift*).
fn noise(seed: &mut u64) -> f64 {
    *seed ^= *seed >> 12;
    *seed ^= *seed << 25;
    *seed ^= *seed >> 27;
    (seed.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
}

#[test]
fn chain_matches_mixbus_when_eq_off() {
    let tracks = vec![
        TrackParams::new(1, "Vocals", 0.0),
        {
            let mut t = TrackParams::new(2, "OH L", -1.0);
            t.gain_db = -6.0;
            t
        },
        {
            let mut t = TrackParams::new(3, "OH R", 1.0);
            t.polarity_invert = true;
            t
        },
        {
            let mut t = TrackParams::new(4, "Talkback", 0.0);
            t.in_mix = false;
            t
        },
    ];
    let n_ch = 4;
    let mut seed = 42u64;
    let input: Vec<f64> = (0..n_ch * 1024).map(|_| noise(&mut seed)).collect();

    let bus = MixBus::new(&tracks, n_ch);
    let mut chain = MixChain::new(
        &tracks,
        n_ch,
        &ChainConfig {
            sample_rate: 44_100,
        },
    );
    let mut out_bus = Vec::new();
    let mut out_chain = Vec::new();
    bus.process(&input, &mut out_bus);
    chain.process(&input, &mut out_chain);
    assert_eq!(out_bus, out_chain); // bit-identical with EQ bypassed
}

#[test]
fn chain_hpf_attenuates_low_channel() {
    let sr = 44_100u32;
    let mut low_track = TrackParams::new(1, "Kick", 0.0);
    low_track.eq.hpf_enabled = true;
    low_track.eq.hpf_freq = 80.0;
    low_track.eq.hpf_slope = HpfSlope::Db24;
    let mid_track = TrackParams::new(2, "Vocals", 0.0);
    let tracks = vec![low_track, mid_track];

    // ch1: 50 Hz sine, ch2: 1 kHz sine — interleaved 2-channel input.
    let frames = sr as usize * 2;
    let mut input = Vec::with_capacity(frames * 2);
    for n in 0..frames {
        let t = n as f64 / sr as f64;
        input.push((std::f64::consts::TAU * 50.0 * t).sin());
        input.push((std::f64::consts::TAU * 1000.0 * t).sin());
    }

    // Reference without HPF.
    let mut plain = tracks.clone();
    plain[0].eq = TrackEq::default();
    let mut ref_chain = MixChain::new(&plain, 2, &ChainConfig { sample_rate: sr });
    let mut eq_chain = MixChain::new(&tracks, 2, &ChainConfig { sample_rate: sr });
    let mut out_ref = Vec::new();
    let mut out_eq = Vec::new();
    ref_chain.process(&input, &mut out_ref);
    eq_chain.process(&input, &mut out_eq);

    // Compare RMS of the second half (filter settled). Both tracks are
    // centred, so the left channel carries both; isolate by frequency via
    // the difference signal: out_ref − out_eq ≈ the removed 50 Hz content.
    let half = out_ref.len() / 2;
    let rms = |v: &[f64]| (v.iter().map(|s| s * s).sum::<f64>() / v.len() as f64).sqrt();
    let removed: Vec<f64> = out_ref[half..]
        .iter()
        .zip(&out_eq[half..])
        .map(|(a, b)| a - b)
        .collect();
    // The 50 Hz channel (RMS 1/√2 · pan 1/√2 = 0.5) is attenuated > 18 dB by
    // an 80 Hz 24 dB/oct HPF, so the removed content is nearly the whole
    // 50 Hz signal and the kept mix retains the full 1 kHz content.
    assert!(rms(&removed) > 0.4, "HPF removed too little 50 Hz content");
    let leftover_low = rms(&out_eq[half..]) - 0.5; // 1 kHz contributes 0.5 RMS
    assert!(
        leftover_low.abs() < 0.06,
        "unexpected residual after HPF: {leftover_low}"
    );
}

#[test]
fn chain_state_adoption_is_click_free() {
    let sr = 44_100u32;
    let mk_track = |gain_db: f64| {
        let mut t = TrackParams::new(1, "Bass", 0.0);
        t.eq.low = EqBand {
            enabled: true,
            freq: 120.0,
            gain_db,
            q: 0.707,
        };
        t
    };
    let cfg = ChainConfig { sample_rate: sr };
    let mut chain = MixChain::new(&[mk_track(6.0)], 1, &cfg);

    // Feed a loud low sine, then swap parameters mid-stream.
    let sine = |n0: usize, frames: usize| -> Vec<f64> {
        (n0..n0 + frames)
            .map(|n| 0.9 * (std::f64::consts::TAU * 60.0 * n as f64 / sr as f64).sin())
            .collect()
    };
    let mut out_a = Vec::new();
    chain.process(&sine(0, 4096), &mut out_a);

    let mut swapped = MixChain::new(&[mk_track(5.5)], 1, &cfg);
    swapped.adopt_state_from(&chain);
    let mut out_b = Vec::new();
    swapped.process(&sine(4096, 4096), &mut out_b);

    // No discontinuity at the boundary or inside the blocks: consecutive
    // samples of a 60 Hz sine at 44.1 kHz can never jump by more than ~0.02
    // plus what the 0.5 dB coefficient step explains.
    let mut prev = out_a[out_a.len() - 2]; // left channel, last frame
    for fr in out_b.chunks_exact(2) {
        assert!(
            (fr[0] - prev).abs() < 0.05,
            "click at parameter swap: {} -> {}",
            prev,
            fr[0]
        );
        prev = fr[0];
    }
}

#[test]
fn session_v1_json_loads_with_default_eq() {
    // Literal v1 on-disk format (pre-EQ).
    let v1 = r#"{
      "version": 1,
      "tracks": [{
        "index": 1, "name": "Vocals", "gain_db": -3.0, "pan": 0.0,
        "polarity_invert": false, "muted": false, "solo": false, "in_mix": true
      }],
      "settings": { "loudness": { "PeakDbfs": -1.0 }, "format": "Wav24" }
    }"#;
    let session: Session = serde_json::from_str(v1).unwrap();
    assert_eq!(session.tracks[0].gain_db, -3.0);
    assert!(!session.tracks[0].eq.is_active());
    assert_eq!(session.tracks[0].eq.hpf_freq, 80.0);
}

// ── dsp: limiter ────────────────────────────────────────────────────────────

/// fs/4 sine sampled at 45° phase: every sample is ±(amp/√2), but the
/// reconstructed waveform peaks at amp — the classic inter-sample peak.
fn intersample_peak_signal(amp: f64, frames: usize) -> Vec<f64> {
    let mut v = Vec::with_capacity(frames * 2);
    for n in 0..frames {
        let s = amp * (std::f64::consts::TAU * 0.25 * n as f64 + std::f64::consts::FRAC_PI_4).sin();
        v.push(s);
        v.push(s);
    }
    v
}

fn measure_true_peak_dbtp(stereo: &[f64], sr: u32) -> f64 {
    let mut ebu = ebur128::EbuR128::new(2, sr, ebur128::Mode::TRUE_PEAK).expect("ebur128");
    ebu.add_frames_f64(stereo).unwrap();
    let tp = ebu.true_peak(0).unwrap().max(ebu.true_peak(1).unwrap());
    linear_to_db(tp)
}

#[test]
fn limiter_holds_true_peak_ceiling_on_intersample_peaks() {
    let sr = 44_100;
    // Sample peak −1.9 dBFS but true peak ≈ +1.1 dBTP.
    let input = intersample_peak_signal(db_to_linear(1.1, -120.0), sr as usize);
    let mut lim = TruePeakLimiter::new(LimiterParams::default(), sr);
    let mut out = Vec::new();
    lim.process(&input, &mut out);
    lim.flush(&mut out);
    assert_eq!(out.len(), input.len());
    let tp = measure_true_peak_dbtp(&out, sr);
    assert!(tp <= -1.0 + 1e-3, "ceiling violated: {tp} dBTP");
    assert!(tp >= -1.6, "over-limiting: {tp} dBTP");
    assert!(lim.max_gain_reduction_db() > 1.5);
}

#[test]
fn limiter_is_transparent_below_ceiling() {
    let sr = 44_100;
    let frames = sr as usize / 2;
    let mut input = Vec::with_capacity(frames * 2);
    for n in 0..frames {
        let s = 0.5 * (std::f64::consts::TAU * 440.0 * n as f64 / sr as f64).sin();
        input.push(s);
        input.push(s * 0.8);
    }
    let mut lim = TruePeakLimiter::new(LimiterParams::default(), sr);
    let mut out = Vec::new();
    // Odd block sizes exercise the priming/flush bookkeeping.
    for chunk in input.chunks(2 * 733) {
        lim.process(chunk, &mut out);
    }
    lim.flush(&mut out);
    assert_eq!(out.len(), input.len());
    for (i, (a, b)) in input.iter().zip(&out).enumerate() {
        assert!((a - b).abs() < 1e-9, "sample {i} altered: {a} vs {b}");
    }
    assert!(lim.max_gain_reduction_db() < 1e-9);
}

#[test]
fn limiter_output_is_sample_aligned_and_length_preserving() {
    let sr = 44_100;
    let frames = 10_000usize;
    let k = 6321usize; // impulse position
    let mut input = vec![0.0f64; frames * 2];
    input[2 * k] = 0.5;
    input[2 * k + 1] = -0.5;
    let mut lim = TruePeakLimiter::new(LimiterParams::default(), sr);
    let mut out = Vec::new();
    for chunk in input.chunks(2 * 997) {
        lim.process(chunk, &mut out);
    }
    lim.flush(&mut out);
    assert_eq!(out.len(), input.len());
    let (pos, _) = out
        .chunks_exact(2)
        .enumerate()
        .max_by(|a, b| a.1[0].abs().partial_cmp(&b.1[0].abs()).unwrap())
        .unwrap();
    assert_eq!(pos, k, "impulse moved");
    assert!(out[2 * k] > 0.4 && out[2 * k + 1] < -0.4);
}

#[test]
fn limiter_release_recovers() {
    let sr = 44_100;
    let params = LimiterParams {
        release_ms: 50.0,
        ..LimiterParams::default()
    };
    // 100 ms burst at +3 dBTP demand, then 500 ms of −20 dBFS signal.
    let mut input = intersample_peak_signal(db_to_linear(3.0, -120.0), sr as usize / 10);
    for n in 0..sr as usize / 2 {
        let s = 0.1 * (std::f64::consts::TAU * 440.0 * n as f64 / sr as f64).sin();
        input.push(s);
        input.push(s);
    }
    let mut lim = TruePeakLimiter::new(params, sr);
    let mut out = Vec::new();
    lim.process(&input, &mut out);
    lim.flush(&mut out);
    // Compare the very tail against the raw input: gain must be back to ~1.
    let tail_in = &input[input.len() - 2000..];
    let tail_out = &out[out.len() - 2000..];
    for (a, b) in tail_in.iter().zip(tail_out) {
        assert!((a - b).abs() < 1e-3, "release did not recover: {a} vs {b}");
    }
}

// ── dsp: dither ─────────────────────────────────────────────────────────────

#[test]
fn tpdf_dither_statistics() {
    let mut d = TpdfDither::default();
    let n = 200_000;
    let mut sum = 0.0;
    let mut sum_sq = 0.0;
    for _ in 0..n {
        let v = d.sample();
        assert!(v > -1.0 && v < 1.0);
        sum += v;
        sum_sq += v * v;
    }
    let mean: f64 = sum / n as f64;
    let var = sum_sq / n as f64 - mean * mean;
    assert!(mean.abs() < 0.01, "mean {mean}");
    // Triangular PDF on (−1,1): variance = 1/6.
    assert!((var - 1.0 / 6.0).abs() < 1.0 / 60.0, "variance {var}");
}

// ── dsp: gain/pan basics ────────────────────────────────────────────────────

#[test]
fn db_to_linear_basics() {
    assert_eq!(db_to_linear(0.0, GAIN_FLOOR_DB), 1.0);
    assert!((db_to_linear(-6.0, GAIN_FLOOR_DB) - 0.5011872).abs() < 1e-6);
    assert!((db_to_linear(6.0, GAIN_FLOOR_DB) - 1.9952623).abs() < 1e-6);
}

#[test]
fn db_to_linear_floor_is_silence() {
    assert_eq!(db_to_linear(-60.0, GAIN_FLOOR_DB), 0.0);
    assert_eq!(db_to_linear(-90.0, GAIN_FLOOR_DB), 0.0);
    assert!(db_to_linear(-59.9, GAIN_FLOOR_DB) > 0.0);
}

#[test]
fn linear_to_db_roundtrip() {
    assert!((linear_to_db(1.0)).abs() < 1e-12);
    assert_eq!(linear_to_db(0.0), f64::NEG_INFINITY);
    assert!((linear_to_db(db_to_linear(-12.0, GAIN_FLOOR_DB)) + 12.0).abs() < 1e-9);
}

#[test]
fn pan_law_is_constant_power() {
    let (l, r) = pan_gains(0.0);
    // −3 dB centre
    assert!((l - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);
    assert!((r - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);
    assert_eq!(pan_gains(-1.0).0, 1.0);
    assert!(pan_gains(-1.0).1.abs() < 1e-12);
    assert!(pan_gains(1.0).0.abs() < 1e-12);
    assert_eq!(pan_gains(1.0).1, 1.0);
    // power sums to 1 everywhere
    for i in 0..=20 {
        let p = -1.0 + i as f64 * 0.1;
        let (l, r) = pan_gains(p);
        assert!((l * l + r * r - 1.0).abs() < 1e-12, "pan {p}");
    }
}

// ── wav reader ──────────────────────────────────────────────────────────────

#[test]
fn reads_16bit_riff_with_ixml() {
    let samples: Vec<i16> = vec![0, 16384, -16384, 32767, -32768, 0];
    let bytes = wav16(2, 48000, &samples, Some(DUREC_IXML));
    let mut r = WavReader::new(Cursor::new(bytes)).unwrap();

    let spec = r.spec();
    assert_eq!(spec.channels, 2);
    assert_eq!(spec.sample_rate, 48000);
    assert_eq!(spec.bits_per_sample, 16);
    assert_eq!(spec.sample_format, SampleFormat::Int);
    assert_eq!(r.num_frames(), 3);
    assert_eq!(parse_tracks(r.ixml().unwrap()).len(), 3);

    let mut buf = Vec::new();
    let n = r.read_frames(&mut buf, 1024).unwrap();
    assert_eq!(n, 3);
    assert_eq!(buf[0], 0.0);
    assert!((buf[1] - 0.5).abs() < 1e-9);
    assert!((buf[2] + 0.5).abs() < 1e-9);
    assert!((buf[3] - 32767.0 / 32768.0).abs() < 1e-9);
    assert_eq!(buf[4], -1.0);
}

#[test]
fn reads_24bit_samples_exactly() {
    let raw: Vec<i32> = vec![0, 8_388_607, -8_388_608, 4_194_304];
    let bytes = wav24(1, 44100, &raw);
    let mut r = WavReader::new(Cursor::new(bytes)).unwrap();
    let mut buf = Vec::new();
    r.read_frames(&mut buf, 16).unwrap();
    assert_eq!(buf[0], 0.0);
    assert!((buf[1] - 8_388_607.0 / 8_388_608.0).abs() < 1e-12);
    assert_eq!(buf[2], -1.0);
    assert!((buf[3] - 0.5).abs() < 1e-12);
}

#[test]
fn reads_rf64_with_ds64_data_size() {
    let samples: Vec<i16> = (0..8).map(|i| i * 1000).collect();
    let bytes = rf64_16(2, 96000, &samples);
    let mut r = WavReader::new(Cursor::new(bytes)).unwrap();
    assert_eq!(r.spec().sample_rate, 96000);
    assert_eq!(r.num_frames(), 4);
    let mut buf = Vec::new();
    assert_eq!(r.read_frames(&mut buf, 100).unwrap(), 4);
}

#[test]
fn seek_and_blockwise_reads() {
    let samples: Vec<i16> = (0..1000).map(|i| (i % 100) as i16).collect();
    let bytes = wav16(2, 48000, &samples, None);
    let mut r = WavReader::new(Cursor::new(bytes)).unwrap();
    let mut buf = Vec::new();

    let mut total = 0;
    loop {
        let n = r.read_frames(&mut buf, 128).unwrap();
        if n == 0 {
            break;
        }
        total += n;
    }
    assert_eq!(total, 500);

    r.seek_to_frame(499).unwrap();
    assert_eq!(r.read_frames(&mut buf, 10).unwrap(), 1);
    r.seek_to_frame(0).unwrap();
    assert_eq!(r.read_frames(&mut buf, 10).unwrap(), 10);
}

#[test]
fn rejects_non_wav() {
    let Err(err) = WavReader::new(Cursor::new(b"not a wav file at all".to_vec())) else {
        panic!("expected NotWav error");
    };
    assert!(matches!(err, EngineError::NotWav));
}

#[test]
fn rejects_unsupported_format_tag() {
    let mut body = Vec::new();
    body.extend_from_slice(b"WAVE");
    body.extend(chunk(b"fmt ", &fmt_payload(0x0055, 2, 48000, 16))); // MP3 tag
    body.extend(chunk(b"data", &[0u8; 4]));
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(body.len() as u32).to_le_bytes());
    bytes.extend(body);
    let Err(err) = WavReader::new(Cursor::new(bytes)) else {
        panic!("expected UnsupportedFormat error");
    };
    assert!(matches!(err, EngineError::UnsupportedFormat(_)));
}

// ── mix bus ─────────────────────────────────────────────────────────────────

fn track(index: u32, gain_db: f64, pan: f64) -> TrackParams {
    TrackParams {
        gain_db,
        pan,
        ..TrackParams::new(index, format!("T{index}"), pan)
    }
}

#[test]
fn mixes_hard_panned_track() {
    // one channel, hard left, unity gain
    let bus = MixBus::new(&[track(1, 0.0, -1.0)], 2);
    let input = [0.5, 0.25, -0.5, -0.25]; // 2 frames, 2 channels
    let mut out = Vec::new();
    bus.process(&input, &mut out);
    assert_eq!(out, vec![0.5, 0.0, -0.5, 0.0]);
}

#[test]
fn centre_pan_applies_minus_3db() {
    let bus = MixBus::new(&[track(1, 0.0, 0.0)], 1);
    let mut out = Vec::new();
    bus.process(&[1.0], &mut out);
    assert!((out[0] - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);
    assert!((out[1] - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);
}

#[test]
fn solo_excludes_other_tracks() {
    let mut t1 = track(1, 0.0, -1.0);
    let t2 = track(2, 0.0, 1.0);
    t1.solo = true;
    let bus = MixBus::new(&[t1, t2], 2);
    let mut out = Vec::new();
    bus.process(&[0.8, 0.6], &mut out);
    assert_eq!(out, vec![0.8, 0.0]); // only track 1 (hard L) audible
}

#[test]
fn mute_and_in_mix_exclude_tracks() {
    let mut t1 = track(1, 0.0, -1.0);
    t1.muted = true;
    let mut t2 = track(2, 0.0, 1.0);
    t2.in_mix = false;
    let bus = MixBus::new(&[t1, t2], 2);
    assert!(bus.is_silent());
}

#[test]
fn polarity_invert_flips_sign() {
    let mut t = track(1, 0.0, -1.0);
    t.polarity_invert = true;
    let bus = MixBus::new(&[t], 1);
    let mut out = Vec::new();
    bus.process(&[0.5], &mut out);
    assert_eq!(out[0], -0.5);
}

#[test]
fn fader_floor_is_silent_and_out_of_range_ignored() {
    let silent = track(1, -60.0, 0.0);
    let out_of_range = track(9, 0.0, 0.0); // file only has 2 channels
    let bus = MixBus::new(&[silent, out_of_range], 2);
    assert!(bus.is_silent());
}

#[test]
fn gain_is_applied() {
    let bus = MixBus::new(&[track(1, -6.0, -1.0)], 1);
    let mut out = Vec::new();
    bus.process(&[1.0], &mut out);
    assert!((out[0] - 0.5011872).abs() < 1e-6);
}

// ── render ──────────────────────────────────────────────────────────────────

#[test]
fn renders_peak_normalised_wav() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.wav");

    // 2 channels: ch1 = 0.25 sine-ish ramp, ch2 silent
    let samples: Vec<i16> = (0..2000)
        .flat_map(|i| {
            let v = ((i as f64 / 100.0).sin() * 0.25 * 32767.0) as i16;
            [v, 0]
        })
        .collect();
    std::fs::write(&in_path, wav16(2, 48000, &samples, None)).unwrap();

    let tracks = vec![track(1, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::PeakDbfs(-1.0),
        format: OutputFormat::Wav24,
        // Exact sample-peak semantics: keep the limiter out of the way.
        limiter_enabled: false,
        ..RenderSettings::default()
    };
    let mut last_progress = 0.0f32;
    let report = render_to_file(&in_path, &tracks, &settings, &out_path, |p| {
        assert!(p >= last_progress);
        last_progress = p;
    })
    .unwrap();
    assert_eq!(last_progress, 1.0);
    assert_eq!(report.sample_rate, 48000);

    // Read back and confirm the peak sits at −1 dBFS (0.891).
    let mut r = hound::WavReader::open(&out_path).unwrap();
    assert_eq!(r.spec().channels, 2);
    assert_eq!(r.spec().bits_per_sample, 24);
    let peak = r
        .samples::<i32>()
        .map(|s| (s.unwrap() as f64 / 8_388_608.0).abs())
        .fold(0.0f64, f64::max);
    let target = 10f64.powf(-1.0 / 20.0);
    assert!((peak - target).abs() < 1e-3, "peak {peak} target {target}");
}

#[test]
fn render_without_normalisation_prevents_clipping() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.wav");

    // Two loud channels summed at centre would clip without protection.
    let samples: Vec<i16> = (0..500).flat_map(|_| [30000i16, 30000]).collect();
    std::fs::write(&in_path, wav16(2, 44100, &samples, None)).unwrap();

    let tracks = vec![track(1, 0.0, 0.0), track(2, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::None,
        format: OutputFormat::Wav32Float,
        // Static clip protection only engages when the limiter is off.
        limiter_enabled: false,
        ..RenderSettings::default()
    };
    render_to_file(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();

    let mut r = hound::WavReader::open(&out_path).unwrap();
    let peak = r
        .samples::<f32>()
        .map(|s| s.unwrap().abs())
        .fold(0.0f32, f32::max);
    assert!(peak <= 1.0 + 1e-6);
}

#[test]
fn lufs_target_hit_within_half_lu() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.wav");

    // 10 s of a −20 dBFS 997 Hz sine, mono channel panned centre.
    let sr = 48_000u32;
    let samples: Vec<i16> = (0..sr as usize * 10)
        .map(|n| {
            (0.1 * (std::f64::consts::TAU * 997.0 * n as f64 / sr as f64).sin() * 32767.0) as i16
        })
        .collect();
    std::fs::write(&in_path, wav16(1, sr, &samples, None)).unwrap();

    let tracks = vec![track(1, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::LufsIntegrated(-16.0),
        format: OutputFormat::Wav32Float,
        ..RenderSettings::default()
    };
    let report = render_to_file(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();

    // Report says the target was hit…
    assert!(
        (report.integrated_lufs + 16.0).abs() < 0.5,
        "report LUFS {}",
        report.integrated_lufs
    );
    assert!((report.gain_applied_db - (-16.0 - report.source_integrated_lufs)).abs() < 0.1);

    // …and an independent measurement of the file agrees.
    let mut r = hound::WavReader::open(&out_path).unwrap();
    let all: Vec<f64> = r.samples::<f32>().map(|s| s.unwrap() as f64).collect();
    let mut ebu = ebur128::EbuR128::new(2, sr, ebur128::Mode::I).unwrap();
    ebu.add_frames_f64(&all).unwrap();
    let measured = ebu.loudness_global().unwrap();
    assert!((measured + 16.0).abs() < 0.5, "file LUFS {measured}");
    assert!((measured - report.integrated_lufs).abs() < 0.1);
}

#[test]
fn lufs_target_engages_limiter() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.wav");

    // Quiet but peaky source: pushing it up to −8 LUFS forces peaks over
    // −1 dBTP, so the limiter must act.
    let sr = 44_100u32;
    let samples: Vec<i16> = (0..sr as usize * 6)
        .map(|n| {
            let t = n as f64 / sr as f64;
            let burst = if (t * 2.0).fract() < 0.05 { 1.0 } else { 0.1 };
            (0.3 * burst * (std::f64::consts::TAU * 220.0 * t).sin() * 32767.0) as i16
        })
        .collect();
    std::fs::write(&in_path, wav16(1, sr, &samples, None)).unwrap();

    let tracks = vec![track(1, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::LufsIntegrated(-8.0),
        format: OutputFormat::Wav32Float,
        ..RenderSettings::default()
    };
    let report = render_to_file(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();
    assert!(
        report.gain_applied_db > 6.0,
        "gain {}",
        report.gain_applied_db
    );
    assert!(
        report.true_peak_dbtp <= -1.0 + 0.05,
        "TP {} dBTP",
        report.true_peak_dbtp
    );
    assert!(report.lra_lu >= 0.0);
    // Output length unchanged by limiter latency handling.
    let r = hound::WavReader::open(&out_path).unwrap();
    assert_eq!(r.duration() as usize, samples.len());
}

#[test]
fn dithered_16bit_render_reaches_both_codes() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.wav");

    // A constant level that falls between two 16-bit codes after the mix
    // bus (pan centre = 1/√2): without dither it sticks to one code.
    let sr = 44_100u32;
    let samples: Vec<i32> = (0..sr as usize).map(|_| 3_000_000i32).collect();
    std::fs::write(&in_path, wav24(1, sr, &samples)).unwrap();

    let tracks = vec![track(1, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::None,
        format: OutputFormat::Wav16,
        limiter_enabled: false,
        ..RenderSettings::default()
    };
    let report = render_to_file(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();
    assert_eq!(report.gain_applied_db, 0.0);

    let mut r = hound::WavReader::open(&out_path).unwrap();
    let left: Vec<i16> = r.samples::<i16>().map(|s| s.unwrap()).step_by(2).collect();
    let distinct: std::collections::HashSet<i16> = left.iter().copied().collect();
    assert!(distinct.len() >= 2, "dither missing: {distinct:?}");
    // The dithered average reconstructs the in-between value (±0.1 LSB).
    let expected = 3_000_000.0 / 8_388_607.0 * std::f64::consts::FRAC_1_SQRT_2 * 32767.0;
    let mean = left.iter().map(|&v| v as f64).sum::<f64>() / left.len() as f64;
    assert!(
        (mean - expected).abs() < 0.1,
        "mean {mean} expected {expected}"
    );
}

// ── trim / fade / bpm ───────────────────────────────────────────────────────

#[test]
fn trim_renders_exact_range_with_fades() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.wav");

    // 4 s ramp signal so positions are identifiable: sample n = n / N.
    let sr = 44_100u32;
    let n_total = sr as usize * 4;
    let samples: Vec<i16> = (0..n_total)
        .map(|n| ((n as f64 / n_total as f64) * 30000.0) as i16)
        .collect();
    std::fs::write(&in_path, wav16(1, sr, &samples, None)).unwrap();

    let start = sr as u64; // 1 s
    let end = 3 * sr as u64; // 3 s
    let tracks = vec![track(1, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::None,
        format: OutputFormat::Wav32Float,
        limiter_enabled: false,
        trim_start_frame: start,
        trim_end_frame: Some(end),
        fade_in_ms: 80.0,
        fade_out_ms: 80.0,
        ..RenderSettings::default()
    };
    let report = render_to_file(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();
    assert!((report.duration_seconds - 2.0).abs() < 1e-9);

    let mut r = hound::WavReader::open(&out_path).unwrap();
    let out: Vec<f32> = r.samples::<f32>().map(|s| s.unwrap()).collect();
    assert_eq!(out.len() / 2, (end - start) as usize);

    let fade_frames = (0.080 * sr as f64) as usize;
    let pan = std::f64::consts::FRAC_1_SQRT_2;
    let expected_mid = |i: usize| (samples[start as usize + i] as f64 / 32768.0) * pan;
    // Edges faded to (near) zero.
    assert!(out[0].abs() < 1e-6, "fade-in start not silent");
    assert!(out[out.len() - 2].abs() < 1e-3, "fade-out end not silent");
    // Middle untouched and taken from the right source position.
    let mid = (end - start) as usize / 2;
    assert!(
        (out[2 * mid] as f64 - expected_mid(mid)).abs() < 1e-4,
        "wrong content at middle"
    );
    // Just after the fade-in the signal is back at full level.
    let post_fade = fade_frames + 10;
    assert!(
        (out[2 * post_fade] as f64 - expected_mid(post_fade)).abs() < 1e-4,
        "fade-in extends too far"
    );
}

#[test]
fn bpm_detected_from_click_track() {
    let dir = tempfile::tempdir().unwrap();
    for &(bpm, name) in &[(120.0f64, "a.wav"), (143.0, "b.wav")] {
        let in_path = dir.path().join(name);
        let sr = 44_100u32;
        let n_total = sr as usize * 12;
        let beat_frames = (60.0 / bpm * sr as f64) as usize;
        // Decaying click on every beat over 12 s.
        let samples: Vec<i16> = (0..n_total)
            .map(|n| {
                let since = n % beat_frames;
                if since < 800 {
                    let env = 1.0 - since as f64 / 800.0;
                    (env * 25000.0 * (std::f64::consts::TAU * 1000.0 * n as f64 / sr as f64).sin())
                        as i16
                } else {
                    0
                }
            })
            .collect();
        std::fs::write(&in_path, wav16(1, sr, &samples, None)).unwrap();

        let analysis = durecmix_engine::analysis::analyze(&in_path, 100).unwrap();
        let detected = analysis.bpm.expect("no BPM detected");
        assert!(
            (detected - bpm).abs() <= 2.0,
            "expected ~{bpm} BPM, got {detected}"
        );
    }
}

#[test]
fn bpm_none_for_steady_tone() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("tone.wav");
    let sr = 44_100u32;
    let samples: Vec<i16> = (0..sr as usize * 12)
        .map(|n| {
            (0.5 * (std::f64::consts::TAU * 440.0 * n as f64 / sr as f64).sin() * 32767.0) as i16
        })
        .collect();
    std::fs::write(&in_path, wav16(1, sr, &samples, None)).unwrap();
    let analysis = durecmix_engine::analysis::analyze(&in_path, 100).unwrap();
    assert_eq!(analysis.bpm, None);
}

// ── encoded formats ─────────────────────────────────────────────────────────

#[test]
fn flac_export_decodes_to_same_audio() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.flac");

    // ~1.3 s of a −6 dBFS 440 Hz sine; the odd length exercises the final
    // partial FLAC frame.
    let sr = 44_100u32;
    let n_samples = 58_000usize;
    let samples: Vec<i16> = (0..n_samples)
        .map(|n| {
            (0.5 * (std::f64::consts::TAU * 440.0 * n as f64 / sr as f64).sin() * 32767.0) as i16
        })
        .collect();
    std::fs::write(&in_path, wav16(1, sr, &samples, None)).unwrap();

    let tracks = vec![track(1, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::None,
        format: OutputFormat::Flac24,
        limiter_enabled: false,
        ..RenderSettings::default()
    };
    let report = render_to_file(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();
    assert!((report.duration_seconds - n_samples as f64 / sr as f64).abs() < 1e-6);

    // Decode with an independent decoder (claxon) and compare sample-exact
    // against the expected mix output (source × centre pan 1/√2, 24-bit).
    let mut reader = claxon::FlacReader::open(&out_path).unwrap();
    let info = reader.streaminfo();
    assert_eq!(info.sample_rate, sr);
    assert_eq!(info.channels, 2);
    assert_eq!(info.bits_per_sample, 24);
    let decoded: Vec<i32> = reader.samples().map(|s| s.unwrap()).collect();
    assert_eq!(decoded.len() / 2, n_samples);
    let pan = std::f64::consts::FRAC_1_SQRT_2;
    for &i in &[0usize, 1, 12_345, 40_000, n_samples - 1] {
        let expected = ((samples[i] as f64 / 32768.0) * pan * 8_388_607.0).round() as i32;
        assert!(
            (decoded[2 * i] - expected).abs() <= 1,
            "sample {i}: {} vs {expected}",
            decoded[2 * i]
        );
        assert_eq!(decoded[2 * i], decoded[2 * i + 1]); // centre pan: L == R
    }
}

#[test]
fn mp3_export_produces_valid_stream() {
    let dir = tempfile::tempdir().unwrap();
    let in_path = dir.path().join("in.wav");
    let out_path = dir.path().join("out.mp3");

    let sr = 44_100u32;
    let samples: Vec<i16> = (0..sr as usize * 2)
        .map(|n| {
            (0.5 * (std::f64::consts::TAU * 440.0 * n as f64 / sr as f64).sin() * 32767.0) as i16
        })
        .collect();
    std::fs::write(&in_path, wav16(1, sr, &samples, None)).unwrap();

    let tracks = vec![track(1, 0.0, 0.0)];
    let settings = RenderSettings {
        loudness: LoudnessMode::PeakDbfs(-1.0),
        format: OutputFormat::Mp3,
        ..RenderSettings::default()
    };
    render_to_file(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();

    let bytes = std::fs::read(&out_path).unwrap();
    // 2 s at 320 kbps CBR ≈ 80 KB; require a sane ballpark.
    assert!(bytes.len() > 60_000, "suspiciously small: {}", bytes.len());
    assert!(bytes.len() < 120_000, "suspiciously large: {}", bytes.len());
    // Stream must begin with an MPEG frame sync (0xFF Ex) or an ID3 tag.
    let starts_ok = bytes.starts_with(b"ID3") || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0);
    assert!(
        starts_ok,
        "no MP3 header: {:02X} {:02X}",
        bytes[0], bytes[1]
    );
}

// ── session ─────────────────────────────────────────────────────────────────

#[test]
fn session_roundtrip_and_merge() {
    let dir = tempfile::tempdir().unwrap();
    let info = vec![
        TrackInfo {
            index: 1,
            name: "Vocals".into(),
        },
        TrackInfo {
            index: 2,
            name: "Git L".into(),
        },
    ];
    let mut session = Session::from_track_info(&info);
    assert_eq!(session.tracks[1].pan, -1.0); // " L" heuristic applied
    session.tracks[0].gain_db = -6.0;
    session.tracks[0].solo = true;

    let path = dir.path().join("take1.durecmix.json");
    session.save(&path).unwrap();
    let loaded = Session::load(&path).unwrap();
    assert_eq!(loaded, session);

    // Re-scan where Vocals moved to channel 3 and a new track appeared.
    let fresh = vec![
        TrackInfo {
            index: 1,
            name: "Git L".into(),
        },
        TrackInfo {
            index: 3,
            name: "Vocals".into(),
        },
        TrackInfo {
            index: 4,
            name: "Bass".into(),
        },
    ];
    let merged = loaded.merged_with(&fresh);
    let vocals = merged.tracks.iter().find(|t| t.name == "Vocals").unwrap();
    assert_eq!(vocals.index, 3);
    assert_eq!(vocals.gain_db, -6.0);
    assert!(vocals.solo);
    let bass = merged.tracks.iter().find(|t| t.name == "Bass").unwrap();
    assert_eq!(bass.gain_db, 0.0);
}

#[test]
fn fresh_session_excludes_monitor_feeds() {
    let info: Vec<TrackInfo> = [
        "Vocals",
        "In Ear 2 R",
        "Phones L",
        "Bass_Out", // console stem — stays in
        "Line Out 1",
        "Talkback",
        "Kick",
    ]
    .iter()
    .enumerate()
    .map(|(i, n)| TrackInfo {
        index: i as u32 + 1,
        name: (*n).into(),
    })
    .collect();
    let session = Session::from_track_info(&info);
    let in_mix: Vec<bool> = session.tracks.iter().map(|t| t.in_mix).collect();
    assert_eq!(in_mix, vec![true, false, false, true, false, false, true]);
}

#[test]
fn session_legacy_sibling_path_derivation() {
    let p = Session::legacy_sibling_path(std::path::Path::new("/x/Take 01.wav"));
    assert_eq!(p, std::path::PathBuf::from("/x/Take 01.durecmix.json"));
}

#[test]
fn session_migrates_from_legacy_sibling() {
    let dir = tempfile::tempdir().unwrap();
    let wav_path = dir.path().join("take1.wav");
    let container_path = dir.path().join("container").join("take1.durecmix.json");

    // Neither file exists: fresh recording.
    assert!(Session::load_or_migrate(&container_path, &wav_path).is_none());

    // Only the legacy sibling exists: it is picked up.
    let mut legacy = Session::from_track_info(&[TrackInfo {
        index: 1,
        name: "Vocals".into(),
    }]);
    legacy.tracks[0].gain_db = -3.0;
    legacy
        .save(&Session::legacy_sibling_path(&wav_path))
        .unwrap();
    let migrated = Session::load_or_migrate(&container_path, &wav_path).unwrap();
    assert_eq!(migrated.tracks[0].gain_db, -3.0);

    // Once the container session exists, it wins over the legacy file.
    let mut primary = migrated;
    primary.tracks[0].gain_db = -9.0;
    primary.save(&container_path).unwrap();
    let loaded = Session::load_or_migrate(&container_path, &wav_path).unwrap();
    assert_eq!(loaded.tracks[0].gain_db, -9.0);
}

#[test]
fn session_save_creates_parent_dirs() {
    let dir = tempfile::tempdir().unwrap();
    let deep = dir.path().join("a").join("b").join("s.durecmix.json");
    Session::default().save(&deep).unwrap();
    assert!(deep.is_file());
}

// ── analysis ────────────────────────────────────────────────────────────────

#[test]
fn waveform_buckets_capture_envelope() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wave.wav");
    // 2 channels, 100 frames: ch1 ramps up positive, ch2 constant -0.5
    let samples: Vec<i16> = (0..100).flat_map(|i| [(i * 300) as i16, -16384]).collect();
    std::fs::write(&path, wav16(2, 48000, &samples, None)).unwrap();

    let waves = durecmix_engine::analysis::analyze_waveforms(&path, 10).unwrap();
    assert_eq!(waves.len(), 2);
    assert_eq!(waves[0].min.len(), 10);
    assert_eq!(waves[0].max.len(), 10);
    // ch1 max grows monotonically across buckets
    assert!(waves[0].max[9] > waves[0].max[0]);
    // ch2 is flat at -0.5: min ≈ -0.5, max ≤ 0
    assert!((waves[1].min[5] + 0.5).abs() < 1e-3);
    assert!(waves[1].max[5] <= 0.0);
    // peaks
    assert!((waves[1].peak_dbfs - (-6.02)).abs() < 0.1);
}

#[test]
fn waveform_bucket_count_smaller_than_frames() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tiny.wav");
    let samples: Vec<i16> = vec![1000, 2000, 3000]; // 3 mono frames
    std::fs::write(&path, wav16(1, 48000, &samples, None)).unwrap();
    // more buckets than frames must not panic; trailing buckets stay 0
    let waves = durecmix_engine::analysis::analyze_waveforms(&path, 8).unwrap();
    assert_eq!(waves[0].max.len(), 8);
}

// ── probe (browser metadata) ────────────────────────────────────────────────

#[test]
fn probe_reads_spec_duration_and_ixml_track_count() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("take.wav");
    let samples: Vec<i16> = vec![0; 3 * 44100]; // 3 ch × 1 s
    std::fs::write(&path, wav16(3, 44100, &samples, Some(DUREC_IXML))).unwrap();

    let info = wav::probe(&InputHandle::Path(path.to_str().unwrap().into())).unwrap();
    assert_eq!(info.channels, 3);
    assert_eq!(info.sample_rate, 44100);
    assert_eq!(info.bits_per_sample, 16);
    assert_eq!(info.num_frames, 44100);
    assert!((info.duration_seconds - 1.0).abs() < 1e-9);
    assert_eq!(info.ixml_track_count, 3);
}

#[test]
fn probe_without_ixml_reports_zero_tracks() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("plain.wav");
    std::fs::write(&path, wav16(2, 48000, &[0i16; 96000], None)).unwrap();

    let info = wav::probe(&InputHandle::Path(path.to_str().unwrap().into())).unwrap();
    assert_eq!(info.channels, 2);
    assert_eq!(info.ixml_track_count, 0);
}

#[test]
fn probe_rejects_non_wav() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("not_audio.wav");
    std::fs::write(&path, b"this is definitely not a RIFF file").unwrap();
    assert!(wav::probe(&InputHandle::Path(path.to_str().unwrap().into())).is_err());
}

// ── dsp: mid/side FIR stage ─────────────────────────────────────────────────

/// Direct O(n·taps) reference: split to M/S, convolve each with its FIR
/// (centre-aligned, i.e. group delay compensated), recombine to L/R.
fn direct_ms_conv(stereo: &[f64], fir_mid: &[f64], fir_side: &[f64]) -> Vec<f64> {
    let frames = stereo.len() / 2;
    let latency = (fir_mid.len() - 1) / 2;
    let sample = |buf: &[(f64, f64)], idx: i64| -> (f64, f64) {
        if idx < 0 || idx as usize >= buf.len() {
            (0.0, 0.0)
        } else {
            buf[idx as usize]
        }
    };
    let ms: Vec<(f64, f64)> = stereo
        .chunks_exact(2)
        .map(|fr| ((fr[0] + fr[1]) * 0.5, (fr[0] - fr[1]) * 0.5))
        .collect();
    let mut out = Vec::with_capacity(stereo.len());
    for n in 0..frames as i64 {
        let (mut m, mut s) = (0.0, 0.0);
        for (k, (&hm, &hs)) in fir_mid.iter().zip(fir_side).enumerate() {
            let (im, is) = sample(&ms, n + latency as i64 - k as i64);
            m += hm * im;
            s += hs * is;
        }
        out.push(m + s);
        out.push(m - s);
    }
    out
}

/// Odd-length deterministic pseudo-random FIR for tests.
fn test_fir(len: usize, seed: u64) -> Vec<f64> {
    assert_eq!(len % 2, 1);
    let mut s = seed;
    (0..len).map(|_| noise(&mut s) / len as f64).collect()
}

#[test]
fn fir_stage_impulse_reproduces_taps() {
    use durecmix_engine::dsp::fir::MsFirStage;
    let taps = test_fir(15, 7);
    let mut stage = MsFirStage::new(&taps, &taps);
    assert_eq!(stage.latency_frames(), 7);
    let frames = 100usize;
    let mut input = vec![0.0f64; frames * 2];
    input[0] = 1.0; // left-channel impulse at frame 0
    let mut out = Vec::new();
    stage.process(&input, &mut out);
    stage.flush(&mut out);
    assert_eq!(out.len(), input.len());
    // Identical mid/side filters act per-channel: out_l[n] = taps[n + latency].
    let latency = stage.latency_frames();
    for (n, fr) in out.chunks_exact(2).enumerate() {
        let expected = taps.get(n + latency).copied().unwrap_or(0.0);
        assert!(
            (fr[0] - expected).abs() < 1e-12,
            "left sample {n}: {} vs {expected}",
            fr[0]
        );
        assert!(
            fr[1].abs() < 1e-12,
            "right sample {n} not silent: {}",
            fr[1]
        );
    }
}

#[test]
fn fir_stage_matches_direct_convolution() {
    use durecmix_engine::dsp::fir::MsFirStage;
    let fir_mid = test_fir(31, 1);
    let fir_side = test_fir(31, 2);
    let mut seed = 99u64;
    let input: Vec<f64> = (0..500 * 2).map(|_| noise(&mut seed)).collect();
    let expected = direct_ms_conv(&input, &fir_mid, &fir_side);
    let mut stage = MsFirStage::new(&fir_mid, &fir_side);
    let mut out = Vec::new();
    for chunk in input.chunks(2 * 17) {
        stage.process(chunk, &mut out);
    }
    stage.flush(&mut out);
    assert_eq!(out.len(), expected.len());
    for (i, (a, b)) in out.iter().zip(&expected).enumerate() {
        assert!((a - b).abs() < 1e-9, "sample {i}: {a} vs {b}");
    }
}

#[test]
fn fir_stage_is_block_size_invariant() {
    use durecmix_engine::dsp::fir::MsFirStage;
    let fir_mid = test_fir(4095, 3);
    let fir_side = test_fir(4095, 4);
    let mut seed = 5u64;
    let input: Vec<f64> = (0..30_000 * 2).map(|_| noise(&mut seed)).collect();
    let mut reference = Vec::new();
    let mut stage = MsFirStage::new(&fir_mid, &fir_side);
    stage.process(&input, &mut reference);
    stage.flush(&mut reference);
    assert_eq!(reference.len(), input.len());
    for block in [2, 997 * 2, 4096 * 2, 65_536 * 2] {
        let mut stage = MsFirStage::new(&fir_mid, &fir_side);
        let mut out = Vec::new();
        for chunk in input.chunks(block) {
            stage.process(chunk, &mut out);
        }
        stage.flush(&mut out);
        assert_eq!(out, reference, "block size {block} diverges");
    }
}

#[test]
fn fir_stage_flushes_input_shorter_than_latency() {
    use durecmix_engine::dsp::fir::MsFirStage;
    let fir_mid = test_fir(4095, 8);
    let fir_side = test_fir(4095, 9);
    let mut seed = 11u64;
    let input: Vec<f64> = (0..100 * 2).map(|_| noise(&mut seed)).collect();
    let expected = direct_ms_conv(&input, &fir_mid, &fir_side);
    let mut stage = MsFirStage::new(&fir_mid, &fir_side);
    let mut out = Vec::new();
    stage.process(&input, &mut out);
    stage.flush(&mut out);
    assert_eq!(out.len(), input.len());
    for (i, (a, b)) in out.iter().zip(&expected).enumerate() {
        assert!((a - b).abs() < 1e-9, "sample {i}: {a} vs {b}");
    }
}

#[test]
fn fir_stage_single_tap_is_transparent() {
    use durecmix_engine::dsp::fir::MsFirStage;
    let mut seed = 21u64;
    let input: Vec<f64> = (0..2_000 * 2).map(|_| noise(&mut seed)).collect();
    let mut stage = MsFirStage::new(&[1.0], &[1.0]);
    assert_eq!(stage.latency_frames(), 0);
    let mut out = Vec::new();
    stage.process(&input, &mut out);
    stage.flush(&mut out);
    assert_eq!(out.len(), input.len());
    for (i, (a, b)) in input.iter().zip(&out).enumerate() {
        assert!((a - b).abs() < 1e-12, "sample {i} altered: {a} vs {b}");
    }
}

// ── mastering: analysis + matching design ───────────────────────────────────

use durecmix_engine::mastering::{
    design_mastering, MasteringAnalyzer, MasteringStats, ReferenceProfile, ANALYSIS_FFT,
    PROFILE_VERSION,
};

/// Interleaved stereo noise with independent mid/side beds:
/// l = mid + side, r = mid − side.
fn ms_noise(frames: usize, mid_amp: f64, side_amp: f64, seed: u64) -> Vec<f64> {
    let mut s = seed;
    let mut out = Vec::with_capacity(frames * 2);
    for _ in 0..frames {
        let m = mid_amp * noise(&mut s);
        let sd = side_amp * noise(&mut s);
        out.push(m + sd);
        out.push(m - sd);
    }
    out
}

fn analyze(stereo: &[f64], sr: u32) -> MasteringStats {
    let mut an = MasteringAnalyzer::new(sr);
    for chunk in stereo.chunks(2 * 4801) {
        an.push(chunk);
    }
    an.finish()
}

/// Mean dB of a spectrum over a frequency band.
fn band_db(spectrum: &[f64], sr: u32, lo_hz: f64, hi_hz: f64) -> f64 {
    let bin_hz = sr as f64 / ANALYSIS_FFT as f64;
    let lo = (lo_hz / bin_hz).ceil() as usize;
    let hi = ((hi_hz / bin_hz).floor() as usize).min(spectrum.len() - 1);
    let mean = spectrum[lo..=hi].iter().sum::<f64>() / (hi - lo + 1) as f64;
    linear_to_db(mean)
}

#[test]
fn mastering_analyzer_selects_loud_pieces() {
    let sr = 8000u32;
    let piece = (15.0 * sr as f64) as usize;
    // Two loud pieces, one quiet piece: the quiet one must not dilute the RMS.
    let mut input = ms_noise(piece * 2, 0.5, 0.0, 1);
    input.extend(ms_noise(piece, 0.05, 0.0, 2));
    let stats = analyze(&input, sr);
    // Uniform noise in [−1,1) has RMS 1/√3.
    let expected = 0.5 / 3f64.sqrt();
    assert!(
        (linear_to_db(stats.mid_rms) - linear_to_db(expected)).abs() < 0.1,
        "loud-piece mid RMS off: {} vs {expected}",
        stats.mid_rms
    );
    assert!(stats.side_rms < 1e-9, "l==r input must have zero side");
    assert!((stats.duration_seconds - 45.0).abs() < 0.01);
}

#[test]
fn mastering_matches_reference_tone_level_and_width() {
    let sr = 44_100u32;
    let frames = 30 * sr as usize;
    let target = ms_noise(frames, 0.3, 0.03, 10);
    // Reference: quieter, wider, and tilted — high shelf +6 dB at 4 kHz on
    // both channels (i.e. on mid and side alike).
    let mut reference = ms_noise(frames, 0.15, 0.06, 20);
    let coeffs = BiquadCoeffs::high_shelf(sr as f64, 4000.0, 6.0, BUTTERWORTH_2ND_Q);
    let (mut bl, mut br) = (Biquad::new(coeffs), Biquad::new(coeffs));
    for fr in reference.chunks_exact_mut(2) {
        fr[0] = bl.process(fr[0]);
        fr[1] = br.process(fr[1]);
    }

    let target_stats = analyze(&target, sr);
    let ref_stats = analyze(&reference, sr);
    let profile = ReferenceProfile::from_stats(&ref_stats);
    let plan = design_mastering(&target_stats, &profile).expect("design");
    assert!(plan.gain_db < 0.0, "quieter reference must reduce gain");

    let mut stage = durecmix_engine::dsp::fir::MsFirStage::new(&plan.fir_mid, &plan.fir_side);
    let mut out = Vec::new();
    for chunk in target.chunks(2 * 65_536) {
        stage.process(chunk, &mut out);
    }
    stage.flush(&mut out);
    assert_eq!(out.len(), target.len());
    let out_stats = analyze(&out, sr);

    // Loudness and width land on the reference.
    let rms_err = linear_to_db(out_stats.mid_rms) - linear_to_db(ref_stats.mid_rms);
    assert!(rms_err.abs() < 0.5, "mid RMS off by {rms_err} dB");
    let width_err = linear_to_db(out_stats.side_rms / out_stats.mid_rms)
        - linear_to_db(ref_stats.side_rms / ref_stats.mid_rms);
    assert!(width_err.abs() < 1.0, "width off by {width_err} dB");

    // Tonality: third-octave-ish bands from 60 Hz to 18 kHz within ±1 dB.
    let mut f = 60.0f64;
    while f < 18_000.0 {
        let hi = (f * 1.26).min(18_000.0);
        let err = band_db(&out_stats.mid_spectrum, sr, f, hi)
            - band_db(&ref_stats.mid_spectrum, sr, f, hi);
        assert!(err.abs() < 1.0, "band {f:.0}-{hi:.0} Hz off by {err:.2} dB");
        f = hi;
    }
}

#[test]
fn mastering_low_rate_reference_never_boosts_above_its_nyquist() {
    let tgt_sr = 96_000u32;
    let ref_sr = 44_100u32;
    let target_stats = analyze(&ms_noise(20 * tgt_sr as usize, 0.3, 0.03, 30), tgt_sr);
    let ref_stats = analyze(&ms_noise(20 * ref_sr as usize, 0.3, 0.03, 31), ref_sr);
    let profile = ReferenceProfile::from_stats(&ref_stats);
    let plan = design_mastering(&target_stats, &profile).expect("design");
    // Response above the reference Nyquist must not exceed the response just
    // below it (held-value rule: cut allowed, boost not).
    let resp = {
        // reuse the engine's own grid via a probe: impulse through the FIR
        let mut spec = vec![0.0f64; ANALYSIS_FFT];
        spec[..plan.fir_mid.len()].copy_from_slice(&plan.fir_mid);
        spec
    };
    // Measure via analyzer-grid FFT of the taps.
    let mut an = MasteringAnalyzer::new(tgt_sr);
    let stereo: Vec<f64> = resp.iter().flat_map(|&v| [v, v]).collect();
    an.push(&stereo);
    let taps_spec = an.finish();
    let below = band_db(&taps_spec.mid_spectrum, tgt_sr, 15_000.0, 20_000.0);
    let above = band_db(&taps_spec.mid_spectrum, tgt_sr, 25_000.0, 46_000.0);
    assert!(
        above <= below + 1.0,
        "boost above reference Nyquist: {above:.2} dB vs {below:.2} dB"
    );
}

#[test]
fn mastering_mono_reference_preserves_target_width() {
    let sr = 44_100u32;
    let target = ms_noise(20 * sr as usize, 0.25, 0.1, 40);
    let reference = ms_noise(20 * sr as usize, 0.2, 0.0, 41); // mono
    let target_stats = analyze(&target, sr);
    let ref_stats = analyze(&reference, sr);
    let plan =
        design_mastering(&target_stats, &ReferenceProfile::from_stats(&ref_stats)).expect("design");
    let mut stage = durecmix_engine::dsp::fir::MsFirStage::new(&plan.fir_mid, &plan.fir_side);
    let mut out = Vec::new();
    stage.process(&target, &mut out);
    stage.flush(&mut out);
    let out_stats = analyze(&out, sr);
    let rms_err = linear_to_db(out_stats.mid_rms) - linear_to_db(ref_stats.mid_rms);
    assert!(rms_err.abs() < 0.5, "mid RMS off by {rms_err} dB");
    // Width must survive, not collapse toward the mono reference.
    let width_err = linear_to_db(out_stats.side_rms / out_stats.mid_rms) - linear_to_db(0.1 / 0.25);
    assert!(width_err.abs() < 1.0, "width changed by {width_err} dB");
}

#[test]
fn mastering_mono_target_stays_finite_and_silent_side() {
    let sr = 44_100u32;
    let target = ms_noise(20 * sr as usize, 0.25, 0.0, 50); // mono target
    let reference = ms_noise(20 * sr as usize, 0.2, 0.08, 51); // wide reference
    let target_stats = analyze(&target, sr);
    let plan = design_mastering(
        &target_stats,
        &ReferenceProfile::from_stats(&analyze(&reference, sr)),
    )
    .expect("design");
    assert!(plan.fir_mid.iter().all(|t| t.is_finite()));
    assert!(plan.fir_side.iter().all(|t| t.is_finite()));
    let mut stage = durecmix_engine::dsp::fir::MsFirStage::new(&plan.fir_mid, &plan.fir_side);
    let mut out = Vec::new();
    stage.process(&target, &mut out);
    stage.flush(&mut out);
    let out_stats = analyze(&out, sr);
    assert!(out_stats.side_rms < 1e-6, "mono target grew a side channel");
}

#[test]
fn reference_profile_serde_and_validation() {
    let sr = 44_100u32;
    let stats = analyze(&ms_noise(16 * sr as usize, 0.2, 0.05, 60), sr);
    let profile = ReferenceProfile::from_stats(&stats);
    assert_eq!(profile.version, PROFILE_VERSION);
    let json = serde_json::to_string(&profile).unwrap();
    let back: ReferenceProfile = serde_json::from_str(&json).unwrap();
    assert_eq!(profile, back);

    // Wrong version and silent reference are rejected.
    let mut bad = profile.clone();
    bad.version = PROFILE_VERSION + 1;
    assert!(design_mastering(&stats, &bad).is_err());
    let mut silent = profile.clone();
    silent.mid_rms = 0.0;
    assert!(design_mastering(&stats, &silent).is_err());

    // A too-short target is rejected.
    let short = analyze(&ms_noise(100, 0.2, 0.0, 61), sr);
    assert!(design_mastering(&short, &profile).is_err());
}

// ── mastering: reference decoding ───────────────────────────────────────────

use durecmix_engine::reference::analyze_reference;
use durecmix_engine::sink::{OutputHandle, StereoSink};

fn write_ref_fixture(path: &std::path::Path, format: OutputFormat, stereo: &[f64], sr: u32) {
    let mut sink = StereoSink::create(
        &OutputHandle::Path(path.to_str().unwrap().into()),
        format,
        sr,
    )
    .unwrap();
    for chunk in stereo.chunks(2 * 65_536) {
        sink.write_block(chunk, None).unwrap();
    }
    sink.finalize().unwrap();
}

fn f32_spectrum(spec: &[f32]) -> Vec<f64> {
    spec.iter().map(|&v| v as f64).collect()
}

#[test]
fn reference_decodes_wav_flac_mp3_consistently() {
    let sr = 44_100u32;
    let stereo = ms_noise(16 * sr as usize, 0.2, 0.05, 70);
    let dir = tempfile::tempdir().unwrap();
    let wav = dir.path().join("ref.wav");
    let flac = dir.path().join("ref.flac");
    let mp3 = dir.path().join("ref.mp3");
    write_ref_fixture(&wav, OutputFormat::Wav24, &stereo, sr);
    write_ref_fixture(&flac, OutputFormat::Flac24, &stereo, sr);
    write_ref_fixture(&mp3, OutputFormat::Mp3, &stereo, sr);

    let mut last = 0.0f32;
    let p_wav = analyze_reference(&InputHandle::Path(wav.to_str().unwrap().into()), |p| {
        assert!(p >= last, "progress went backwards");
        last = p;
    })
    .expect("wav");
    assert_eq!(p_wav.sample_rate, sr);
    assert!((p_wav.duration_seconds - 16.0).abs() < 0.1);
    assert!((last - 1.0).abs() < 1e-6, "progress did not reach 1.0");
    // Decoding must agree with a direct in-memory analysis (24-bit quantised).
    let direct = ReferenceProfile::from_stats(&analyze(&stereo, sr));
    assert!((linear_to_db(p_wav.mid_rms) - linear_to_db(direct.mid_rms)).abs() < 0.01);
    assert!((linear_to_db(p_wav.side_rms) - linear_to_db(direct.side_rms)).abs() < 0.01);

    let p_flac =
        analyze_reference(&InputHandle::Path(flac.to_str().unwrap().into()), |_| {}).expect("flac");
    assert!((linear_to_db(p_flac.mid_rms) - linear_to_db(p_wav.mid_rms)).abs() < 0.05);

    let p_mp3 =
        analyze_reference(&InputHandle::Path(mp3.to_str().unwrap().into()), |_| {}).expect("mp3");
    // White noise is MP3's worst case: LAME's ~20 kHz cutoff removes real
    // signal power here (real music has far less HF energy).
    assert!(
        (linear_to_db(p_mp3.mid_rms) - linear_to_db(p_wav.mid_rms)).abs() < 0.6,
        "mp3 RMS drifted: {} vs {}",
        p_mp3.mid_rms,
        p_wav.mid_rms
    );
    // Spectra agree within codec tolerance below the MP3 rolloff.
    let (wav_spec, mp3_spec) = (
        f32_spectrum(&p_wav.mid_spectrum),
        f32_spectrum(&p_mp3.mid_spectrum),
    );
    let mut f = 100.0f64;
    while f < 12_000.0 {
        let hi = (f * 2.0).min(12_000.0);
        let err = band_db(&mp3_spec, sr, f, hi) - band_db(&wav_spec, sr, f, hi);
        assert!(
            err.abs() < 1.0,
            "mp3 band {f:.0}-{hi:.0} Hz off by {err:.2} dB"
        );
        f = hi;
    }
}

#[cfg(unix)]
#[test]
fn reference_decodes_from_raw_fd() {
    use std::os::fd::IntoRawFd;
    let sr = 44_100u32;
    let stereo = ms_noise(16 * sr as usize, 0.2, 0.05, 71);
    let dir = tempfile::tempdir().unwrap();
    let wav = dir.path().join("ref.wav");
    write_ref_fixture(&wav, OutputFormat::Wav24, &stereo, sr);
    let by_path =
        analyze_reference(&InputHandle::Path(wav.to_str().unwrap().into()), |_| {}).unwrap();
    let fd = std::fs::File::open(&wav).unwrap().into_raw_fd();
    let by_fd = analyze_reference(&InputHandle::Fd(fd), |_| {}).unwrap();
    assert_eq!(by_path.mid_spectrum, by_fd.mid_spectrum);
    assert_eq!(by_path.mid_rms, by_fd.mid_rms);
}

#[test]
fn reference_rejects_non_audio() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("junk.mp3");
    std::fs::write(&path, vec![0u8; 4096]).unwrap();
    assert!(analyze_reference(&InputHandle::Path(path.to_str().unwrap().into()), |_| {}).is_err());
}
