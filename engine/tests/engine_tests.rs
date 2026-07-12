use std::io::Cursor;

use durecmix_engine::dsp::{db_to_linear, linear_to_db, pan_gains, GAIN_FLOOR_DB};
use durecmix_engine::ixml::{
    clean_xml, default_pan_for_name, parse_tracks, stereo_pair_base, TrackInfo,
};
use durecmix_engine::mix::{MixBus, TrackParams};
use durecmix_engine::render::{render_to_wav, LoudnessMode, OutputFormat, RenderSettings};
use durecmix_engine::session::Session;
use durecmix_engine::wav::{SampleFormat, WavReader};
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

// ── dsp ─────────────────────────────────────────────────────────────────────

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
    };
    let mut last_progress = 0.0f32;
    let report = render_to_wav(&in_path, &tracks, &settings, &out_path, |p| {
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
    };
    render_to_wav(&in_path, &tracks, &settings, &out_path, |_| {}).unwrap();

    let mut r = hound::WavReader::open(&out_path).unwrap();
    let peak = r
        .samples::<f32>()
        .map(|s| s.unwrap().abs())
        .fold(0.0f32, f32::max);
    assert!(peak <= 1.0 + 1e-6);
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
