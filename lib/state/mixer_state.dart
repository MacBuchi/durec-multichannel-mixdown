import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/rust/api/mixer.dart' as rust;

/// Mutable UI-side copy of one track's mix parameters.
class TrackUi {
  TrackUi({
    required this.index,
    required this.name,
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
    gainDb: t.gainDb,
    pan: t.pan,
    polarityInvert: t.polarityInvert,
    muted: t.muted,
    solo: t.solo,
    inMix: t.inMix,
  );

  final int index;
  final String name;
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
  );
}

enum LoudnessChoice {
  none('none', null),
  peakMinus1('-1 dBFS', -1.0);

  const LoudnessChoice(this.label, this.peakDbfs);
  final String label;
  final double? peakDbfs;
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
  double correlation = 0;

  LoudnessChoice loudness = LoudnessChoice.peakMinus1;
  rust.ApiFormat format = rust.ApiFormat.wav24;

  bool rendering = false;
  double renderProgress = 0;
  rust.ApiRenderReport? lastReport;
  String? lastOutputPath;
  String? error;

  Timer? _pollTimer;
  Timer? _saveDebounce;

  double get durationSeconds => recording?.durationSeconds ?? 0;
  int get sampleRate => recording?.sampleRate ?? 48000;
  bool get loaded => recording != null;

  Future<void> open(String path) async {
    _stopPolling();
    if (playing) {
      rust.playerStop();
      playing = false;
    }
    error = null;
    waveforms = null;
    try {
      recording = await rust.loadRecording(path: path);
      tracks = recording!.tracks.map(TrackUi.fromApi).toList();
      positionSeconds = 0;
      lastReport = null;
      notifyListeners();
      _analyze(path);
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> _analyze(String path) async {
    analyzing = true;
    notifyListeners();
    try {
      waveforms = await rust.analyzeWaveforms(path: path, buckets: BigInt.from(600));
    } catch (_) {
      waveforms = null;
    }
    analyzing = false;
    notifyListeners();
  }

  // ── track parameter changes ───────────────────────────────────────────────

  void updateTrack(TrackUi track, void Function(TrackUi) change) {
    change(track);
    _pushLiveParams();
    _scheduleSave();
    notifyListeners();
  }

  void toggleSolo(TrackUi t) => updateTrack(t, (t) => t.solo = !t.solo);
  void toggleMute(TrackUi t) => updateTrack(t, (t) => t.muted = !t.muted);
  void togglePolarity(TrackUi t) =>
      updateTrack(t, (t) => t.polarityInvert = !t.polarityInvert);
  void toggleInMix(TrackUi t) => updateTrack(t, (t) => t.inMix = !t.inMix);

  void _pushLiveParams() {
    if (playing) {
      rust.playerUpdateTracks(tracks: tracks.map((t) => t.toApi()).toList());
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), saveSession);
  }

  Future<void> saveSession() async {
    final rec = recording;
    if (rec == null) return;
    try {
      await rust.saveSession(
        wavPath: rec.path,
        tracks: tracks.map((t) => t.toApi()).toList(),
        peakDbfs: loudness.peakDbfs,
        format: format,
      );
    } catch (_) {}
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
        startFrame: startFrame,
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

  Future<void> export(String outPath) async {
    final rec = recording;
    if (rec == null || rendering) return;
    rendering = true;
    renderProgress = 0;
    lastReport = null;
    error = null;
    notifyListeners();
    try {
      await for (final ev in rust.renderMix(
        wavPath: rec.path,
        outPath: outPath,
        tracks: tracks.map((t) => t.toApi()).toList(),
        peakDbfs: loudness.peakDbfs,
        format: format,
      )) {
        renderProgress = ev.progress;
        if (ev.report != null) {
          lastReport = ev.report;
          lastOutputPath = outPath;
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
