import 'dart:async';

import 'package:flutter/foundation.dart';

import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'session_paths.dart';

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

/// Central app state: recording, tracks, playback, meters, export.
class MixerState extends ChangeNotifier {
  rust.RecordingInfo? recording;
  List<TrackUi> tracks = [];
  List<rust.ApiChannelWaveform>? waveforms;
  bool analyzing = false;

  bool playing = false;
  double positionSeconds = 0;
  double peakL = 0; // linear 0..1+
  double peakR = 0;
  double lufsMomentary = -70;
  double lufsIntegrated = -70;
  double truePeak = 0; // linear, running max since start/seek
  double correlation = 0;

  LoudnessChoice loudness = LoudnessChoice.peakMinus1;
  double customLufs = -17.0;
  rust.ApiFormat format = rust.ApiFormat.wav24;

  /// Trim range in seconds (null = untrimmed); fades match the old tool's
  /// 80 ms default whenever a trim point is set.
  double? trimStartSeconds;
  double? trimEndSeconds;
  static const double fadeMs = 80.0;

  /// Detected tempo of the recording (whole BPM), if any.
  double? bpm;

  /// Track indices whose EQ panel is expanded.
  final Set<int> expandedEq = {};

  bool rendering = false;
  double renderProgress = 0;
  rust.ApiRenderReport? lastReport;
  String? lastOutputPath;
  String? error;

  Timer? _pollTimer;
  Timer? _saveDebounce;
  String? _sessionPath;

  double get durationSeconds => recording?.durationSeconds ?? 0;
  int get sampleRate => recording?.sampleRate ?? 48000;
  bool get loaded => recording != null;

  /// Provider-reported file name when the source is a content URI.
  String? displayName;

  bool get _isSaf => recording != null && Saf.isContentUri(recording!.path);

  /// A fresh read fd for SAF sources; null on path-based platforms.
  Future<int?> _inputFd(String source) async =>
      Saf.isContentUri(source) ? Saf.openFd(source) : null;

  /// `source` is a filesystem path, or a `content://` URI on Android (the
  /// engine then reads through per-call file descriptors — DUREC files are
  /// never copied).
  Future<void> open(String source, {String? name}) async {
    _stopPolling();
    if (playing) {
      rust.playerStop();
      playing = false;
    }
    error = null;
    waveforms = null;
    displayName = name;
    try {
      _sessionPath = await sessionPathFor(source, displayName: name);
      recording = await rust.loadRecording(
        path: source,
        sessionPath: _sessionPath!,
        fd: await _inputFd(source),
      );
      tracks = recording!.tracks.map(TrackUi.fromApi).toList();
      _restoreMaster(recording!.master);
      positionSeconds = 0;
      lastReport = null;
      expandedEq.clear();
      notifyListeners();
      // Persist immediately so a session migrated from a legacy sibling file
      // lands in the app container even if the user changes nothing.
      await saveSession();
      _analyze(source);
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> _analyze(String source) async {
    analyzing = true;
    notifyListeners();
    try {
      final analysis = await rust.analyzeRecording(
        path: source,
        buckets: BigInt.from(600),
        fd: await _inputFd(source),
      );
      waveforms = analysis.waveforms;
      bpm = analysis.bpm;
    } catch (_) {
      waveforms = null;
      bpm = null;
    }
    analyzing = false;
    notifyListeners();
  }

  // ── track parameter changes ───────────────────────────────────────────────

  /// Mirror changes across " L"/" R" stereo pairs (iXML naming convention);
  /// pans mirror inverted. Toggleable from the app bar.
  bool linkPairs = true;

  static String? _pairBase(String name) =>
      name.endsWith(' L') || name.endsWith(' R')
          ? name.substring(0, name.length - 2)
          : null;

  TrackUi? _pairPartner(TrackUi t) {
    final base = _pairBase(t.name);
    if (base == null) return null;
    final other = t.name.endsWith(' L') ? '$base R' : '$base L';
    for (final candidate in tracks) {
      if (candidate.name == other) return candidate;
    }
    return null;
  }

  void _syncPair(TrackUi from) {
    final partner = _pairPartner(from);
    if (partner == null) return;
    partner.gainDb = from.gainDb;
    partner.pan = -from.pan; // mirrored
    partner.muted = from.muted;
    partner.solo = from.solo;
    partner.inMix = from.inMix;
    partner.polarityInvert = from.polarityInvert;
    partner.eq
      ..hpfEnabled = from.eq.hpfEnabled
      ..hpfFreq = from.eq.hpfFreq
      ..hpfSlope = from.eq.hpfSlope;
    for (final (a, b) in [
      (partner.eq.low, from.eq.low),
      (partner.eq.mid, from.eq.mid),
      (partner.eq.high, from.eq.high),
    ]) {
      a
        ..enabled = b.enabled
        ..freq = b.freq
        ..gainDb = b.gainDb
        ..q = b.q;
    }
  }

  void updateTrack(TrackUi track, void Function(TrackUi) change) {
    change(track);
    if (linkPairs) _syncPair(track);
    _pushLiveParams();
    _scheduleSave();
    notifyListeners();
  }

  void toggleLinkPairs() {
    linkPairs = !linkPairs;
    notifyListeners();
  }

  void toggleSolo(TrackUi t) => updateTrack(t, (t) => t.solo = !t.solo);
  void toggleMute(TrackUi t) => updateTrack(t, (t) => t.muted = !t.muted);
  void togglePolarity(TrackUi t) =>
      updateTrack(t, (t) => t.polarityInvert = !t.polarityInvert);
  void toggleInMix(TrackUi t) => updateTrack(t, (t) => t.inMix = !t.inMix);

  void toggleEqPanel(TrackUi t) {
    if (!expandedEq.remove(t.index)) {
      expandedEq.add(t.index);
    }
    notifyListeners();
  }

  /// Master settings sent to the engine. Preview and export share the same
  /// limiter/ceiling; loudness gain is export-only (see the engine docs).
  rust.ApiMaster get master => rust.ApiMaster(
    loudness: switch (loudness) {
      LoudnessChoice.none =>
          const rust.ApiLoudness(mode: rust.ApiLoudnessMode.none, value: 0),
      LoudnessChoice.peakMinus1 =>
          const rust.ApiLoudness(mode: rust.ApiLoudnessMode.peakDbfs, value: -1),
      LoudnessChoice.lufs14 => const rust.ApiLoudness(
          mode: rust.ApiLoudnessMode.lufsIntegrated, value: -14),
      LoudnessChoice.lufs16 => const rust.ApiLoudness(
          mode: rust.ApiLoudnessMode.lufsIntegrated, value: -16),
      LoudnessChoice.lufs23 => const rust.ApiLoudness(
          mode: rust.ApiLoudnessMode.lufsIntegrated, value: -23),
      LoudnessChoice.lufsCustom => rust.ApiLoudness(
          mode: rust.ApiLoudnessMode.lufsIntegrated, value: customLufs),
    },
    format: format,
    limiterEnabled: true,
    ceilingDbtp: -1.0,
    dither: true,
    trimStartFrame: BigInt.from(((trimStartSeconds ?? 0) * sampleRate).round()),
    trimEndFrame:
        trimEndSeconds != null ? BigInt.from((trimEndSeconds! * sampleRate).round()) : null,
    fadeInMs: trimStartSeconds != null ? fadeMs : 0,
    fadeOutMs: trimEndSeconds != null ? fadeMs : 0,
  );

  void setTrimStart(double? seconds) {
    trimStartSeconds = seconds?.clamp(0, durationSeconds);
    _scheduleSave();
    notifyListeners();
  }

  void setTrimEnd(double? seconds) {
    trimEndSeconds = seconds?.clamp(0, durationSeconds);
    _scheduleSave();
    notifyListeners();
  }

  void _restoreMaster(rust.ApiMaster m) {
    format = m.format;
    final sr = recording?.sampleRate ?? 48000;
    final start = m.trimStartFrame.toInt();
    trimStartSeconds = start > 0 ? start / sr : null;
    trimEndSeconds = m.trimEndFrame != null ? m.trimEndFrame!.toInt() / sr : null;
    switch (m.loudness.mode) {
      case rust.ApiLoudnessMode.none:
        loudness = LoudnessChoice.none;
      case rust.ApiLoudnessMode.peakDbfs:
        loudness = LoudnessChoice.peakMinus1;
      case rust.ApiLoudnessMode.lufsIntegrated:
        loudness = switch (m.loudness.value) {
          -14.0 => LoudnessChoice.lufs14,
          -16.0 => LoudnessChoice.lufs16,
          -23.0 => LoudnessChoice.lufs23,
          _ => LoudnessChoice.lufsCustom,
        };
        if (loudness == LoudnessChoice.lufsCustom) {
          customLufs = m.loudness.value;
        }
    }
  }

  void _pushLiveParams() {
    if (playing) {
      rust.playerUpdateParams(
        tracks: tracks.map((t) => t.toApi()).toList(),
        master: master,
      );
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), saveSession);
  }

  Future<void> saveSession() async {
    final sessionPath = _sessionPath;
    if (recording == null || sessionPath == null) return;
    try {
      await rust.saveSession(
        sessionPath: sessionPath,
        tracks: tracks.map((t) => t.toApi()).toList(),
        master: master,
      );
    } catch (e) {
      error = 'Session save failed: $e';
      notifyListeners();
    }
  }

  // ── playback ──────────────────────────────────────────────────────────────

  Future<void> togglePlay() async {
    if (playing) {
      rust.playerStop();
      playing = false;
      _stopPolling();
      notifyListeners();
      return;
    }
    final rec = recording;
    if (rec == null) return;
    error = null;
    try {
      final startFrame =
          BigInt.from((positionSeconds * rec.sampleRate).round().clamp(0, rec.numFrames.toInt()));
      await rust.playerStart(
        path: rec.path,
        tracks: tracks.map((t) => t.toApi()).toList(),
        master: master,
        startFrame: startFrame,
        fd: await _inputFd(rec.path),
      );
      playing = true;
      _startPolling();
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  void seek(double seconds) {
    positionSeconds = seconds.clamp(0, durationSeconds);
    if (playing) {
      rust.playerSeek(frame: BigInt.from((positionSeconds * sampleRate).round()));
    }
    notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final s = rust.playerState();
      positionSeconds = s.positionFrames.toInt() / sampleRate;
      peakL = s.peakL;
      peakR = s.peakR;
      lufsMomentary = s.lufsMomentary;
      lufsIntegrated = s.lufsIntegrated;
      truePeak = s.truePeak;
      correlation = s.correlation;
      if (!s.playing && playing) {
        playing = false;
        _stopPolling();
      }
      notifyListeners();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    peakL = 0;
    peakR = 0;
  }

  // ── export ────────────────────────────────────────────────────────────────

  /// `outTarget` is a filesystem path, or a `content://` URI on Android
  /// (SAF CREATE_DOCUMENT result) written through a raw fd.
  Future<void> export(String outTarget) async {
    final rec = recording;
    if (rec == null || rendering) return;
    rendering = true;
    renderProgress = 0;
    lastReport = null;
    error = null;
    notifyListeners();
    try {
      final outputFd = Saf.isContentUri(outTarget)
          ? await Saf.openFd(outTarget, mode: 'rwt')
          : null;
      await for (final ev in rust.renderMix(
        wavPath: rec.path,
        outPath: outTarget,
        tracks: tracks.map((t) => t.toApi()).toList(),
        master: master,
        inputFd: _isSaf ? await _inputFd(rec.path) : null,
        outputFd: outputFd,
      )) {
        renderProgress = ev.progress;
        if (ev.report != null) {
          lastReport = ev.report;
          lastOutputPath = outTarget;
        }
        notifyListeners();
      }
      await saveSession();
    } catch (e) {
      error = e.toString();
    }
    rendering = false;
    notifyListeners();
  }

  void setLoudness(LoudnessChoice c) {
    loudness = c;
    _scheduleSave();
    notifyListeners();
  }

  void setFormat(rust.ApiFormat f) {
    format = f;
    _scheduleSave();
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _saveDebounce?.cancel();
    if (playing) rust.playerStop();
    super.dispose();
  }
}
