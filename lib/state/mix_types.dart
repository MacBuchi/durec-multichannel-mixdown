import '../src/rust/api/mixer.dart' as rust;

/// Mutable UI-side copy of one EQ band.
class EqBandUi {
  EqBandUi({
    required this.enabled,
    required this.freq,
    required this.gainDb,
    required this.q,
  });

  factory EqBandUi.fromApi(rust.ApiEqBand b) =>
      EqBandUi(enabled: b.enabled, freq: b.freq, gainDb: b.gainDb, q: b.q);

  bool enabled;
  double freq;
  double gainDb;
  double q;

  rust.ApiEqBand toApi() =>
      rust.ApiEqBand(enabled: enabled, freq: freq, gainDb: gainDb, q: q);
}

/// Mutable UI-side copy of one track's HPF + 3-band EQ.
class TrackEqUi {
  TrackEqUi({
    required this.hpfEnabled,
    required this.hpfFreq,
    required this.hpfSlope,
    required this.low,
    required this.mid,
    required this.high,
  });

  factory TrackEqUi.fromApi(rust.ApiTrackEq eq) => TrackEqUi(
    hpfEnabled: eq.hpfEnabled,
    hpfFreq: eq.hpfFreq,
    hpfSlope: eq.hpfSlope,
    low: EqBandUi.fromApi(eq.low),
    mid: EqBandUi.fromApi(eq.mid),
    high: EqBandUi.fromApi(eq.high),
  );

  bool hpfEnabled;
  double hpfFreq;
  rust.ApiHpfSlope hpfSlope;
  final EqBandUi low;
  final EqBandUi mid;
  final EqBandUi high;

  bool get isActive => hpfEnabled || low.enabled || mid.enabled || high.enabled;

  rust.ApiTrackEq toApi() => rust.ApiTrackEq(
    hpfEnabled: hpfEnabled,
    hpfFreq: hpfFreq,
    hpfSlope: hpfSlope,
    low: low.toApi(),
    mid: mid.toApi(),
    high: high.toApi(),
  );
}

/// Mutable UI-side copy of one track's mix parameters.
class TrackUi {
  TrackUi({
    required this.index,
    required this.name,
    required this.eq,
    this.gainDb = 0.0,
    this.pan = 0.0,
    this.polarityInvert = false,
    this.muted = false,
    this.solo = false,
    this.inMix = true,
  });

  factory TrackUi.fromApi(rust.ApiTrack t) => TrackUi(
    index: t.index,
    name: t.name,
    eq: TrackEqUi.fromApi(t.eq),
    gainDb: t.gainDb,
    pan: t.pan,
    polarityInvert: t.polarityInvert,
    muted: t.muted,
    solo: t.solo,
    inMix: t.inMix,
  );

  final int index;
  final String name;
  final TrackEqUi eq;
  double gainDb;
  double pan;
  bool polarityInvert;
  bool muted;
  bool solo;
  bool inMix;

  rust.ApiTrack toApi() => rust.ApiTrack(
    index: index,
    name: name,
    gainDb: gainDb,
    pan: pan,
    polarityInvert: polarityInvert,
    muted: muted,
    solo: solo,
    inMix: inMix,
    eq: eq.toApi(),
  );
}

/// Display names of the output formats (app bar, dialogs, export target
/// bar in the browser's selection mode).
const formatLabels = {
  rust.ApiFormat.wav16: 'WAV 16',
  rust.ApiFormat.wav24: 'WAV 24',
  rust.ApiFormat.wav32Float: 'WAV 32f',
  rust.ApiFormat.flac16: 'FLAC 16',
  rust.ApiFormat.flac24: 'FLAC 24',
  rust.ApiFormat.mp3: 'MP3 320',
};

enum LoudnessChoice {
  none('none'),
  peakMinus1('-1 dBFS'),
  lufs14('-14 LUFS'),
  lufs16('-16 LUFS'),
  lufs23('-23 LUFS (R128)'),
  lufsCustom('custom LUFS');

  const LoudnessChoice(this.label);
  final String label;
}

/// One batch-export output target; the mix itself always comes from the
/// current state of the mixer at render time.
class BatchJob {
  BatchJob({
    required this.loudness,
    required this.customLufs,
    required this.format,
  });

  LoudnessChoice loudness;
  double customLufs;
  rust.ApiFormat format;
}

/// Output name matching the Python tool's pattern:
/// `<take>_<target>_<bpm>BPM_<yyyyMMdd_HHmmss>.<ext>`. Shared by the
/// single-file export, the format queue, and the multi-file export.
String suggestedExportName({
  required String baseName,
  required LoudnessChoice loudness,
  required double customLufs,
  required rust.ApiFormat format,
  double? bpm,
  DateTime? now,
}) {
  final ext = switch (format) {
    rust.ApiFormat.flac16 || rust.ApiFormat.flac24 => 'flac',
    rust.ApiFormat.mp3 => 'mp3',
    _ => 'wav',
  };
  final base = baseName.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '');
  final target = switch (loudness) {
    LoudnessChoice.none => 'raw',
    LoudnessChoice.peakMinus1 => '1dBFS',
    LoudnessChoice.lufs14 => '14LUFS',
    LoudnessChoice.lufs16 => '16LUFS',
    LoudnessChoice.lufs23 => '23LUFS',
    LoudnessChoice.lufsCustom =>
      '${customLufs.abs().toStringAsFixed(1).replaceAll('.0', '')}LUFS',
  };
  final bpmPart = bpm != null ? '_${bpm.round()}BPM' : '';
  final stampTime = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${stampTime.year}${two(stampTime.month)}${two(stampTime.day)}'
      '_${two(stampTime.hour)}${two(stampTime.minute)}${two(stampTime.second)}';
  return '${base}_$target${bpmPart}_$stamp.$ext';
}
