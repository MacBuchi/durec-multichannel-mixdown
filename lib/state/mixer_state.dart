import 'dart:async';

import 'package:flutter/foundation.dart';

import '../io/platform_shim.dart' show writeTextFile;
import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'analysis_cache.dart';
import 'export_controller.dart';
import 'mastering_controller.dart';
import 'preview_level.dart';
import 'mix_types.dart';
import 'playback_controller.dart';
import 'range_probe.dart';
import 'session_paths.dart';
import 'stereo_pairs.dart';
import 'debug_log.dart';

export 'export_controller.dart';
export 'mastering_controller.dart';
export 'mix_types.dart';
export 'playback_controller.dart';

/// Central app state and single rebuild root: the loaded recording, its
/// tracks and the mix-level settings (loudness/format/trim, pair linking,
/// A/B snapshots, session persistence).
///
/// Playback, export and reference mastering live in focused controllers
/// ([PlaybackController], [ExportController], [MasteringController]) that
/// this class composes; they publish their changes through [notify], so the
/// UI keeps listening to this one [ChangeNotifier].
class MixerState extends ChangeNotifier {
  MixerState() {
    playback = PlaybackController(this);
    exporter = ExportController(this);
    mastering = MasteringController(this);
    previewLevel = PreviewLevelController(this);
  }

  late final PlaybackController playback;
  late final ExportController exporter;
  late final MasteringController mastering;
  late final PreviewLevelController previewLevel;

  rust.RecordingInfo? recording;
  List<TrackUi> tracks = [];
  List<rust.ApiChannelWaveform>? waveforms;
  bool analyzing = false;

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

  String? error;

  Timer? _saveDebounce;
  String? _sessionPath;

  double get durationSeconds => recording?.durationSeconds ?? 0;
  int get sampleRate => recording?.sampleRate ?? 48000;
  bool get loaded => recording != null;

  /// Provider-reported file name when the source is a content URI.
  String? displayName;

  /// True when the loaded recording is read through Android SAF fds.
  bool get isSafSource =>
      recording != null && Saf.isContentUri(recording!.path);

  /// Just the file name, for log lines: which take failed to open is worth
  /// knowing, the directory it sits in is not (and would be redacted anyway).
  static String _logName(String source) => source.split('/').last;

  /// A fresh read fd for SAF sources; null on path-based platforms.
  Future<int?> inputFdFor(String source) async =>
      Saf.isContentUri(source) ? Saf.openFd(source) : null;

  /// Publish a state change to the UI. Controllers call this instead of
  /// carrying their own listeners so the mixer keeps one rebuild root.
  void notify() => notifyListeners();

  /// Overridden rather than clearing the cache in [notify]: half the mutators
  /// call `notifyListeners()` directly, `updateTrack` — the one that actually
  /// changes solo — among them. Hanging the invalidation on the method every
  /// path ends in is the only version that cannot be forgotten.
  @override
  void notifyListeners() {
    _anySolo = null;
    super.notifyListeners();
  }

  bool? _anySolo;

  /// Whether any track is soloed — which decides whether every *other* track
  /// is audible, and therefore whether its meter is drawn greyed (#115).
  ///
  /// Cached until the next [notify] because every visible strip asks: scanning
  /// the track list per strip is fine at 34 tracks and a needless multiple of
  /// that at the few hundred a multisample recording carries.
  bool get anySolo => _anySolo ??= tracks.any((t) => t.solo);

  /// True while a recording is being opened (drives the loading animation).
  bool opening = false;

  /// Random-access reader for sources without a path (web `Blob`s). Set by
  /// the caller before [open]; null means the engine reads the file itself.
  RangeReader? sourceReader;

  /// Byte size that goes with [sourceReader].
  int sourceSize = 0;

  /// `source` is a filesystem path, or a `content://` URI on Android (the
  /// engine then reads through per-call file descriptors — DUREC files are
  /// never copied). With [sourceReader] set there is no file at all and
  /// everything goes through byte ranges (web; docs/PLAN-PWA.md S2b).
  Future<void> open(String source, {String? name}) async {
    playback.stop();
    error = null;
    waveforms = null;
    displayName = name;
    opening = true;
    notifyListeners();
    try {
      _sessionPath = await sessionPathFor(source, displayName: name);
      final reader = sourceReader;
      recording = reader != null
          ? await _loadByRanges(source, reader)
          : await rust.loadRecording(
              path: source,
              sessionPath: _sessionPath!,
              fd: await inputFdFor(source),
            );
      tracks = recording!.tracks.map(TrackUi.fromApi).toList();
      _restoreMaster(recording!.master);
      playback.positionSeconds = 0;
      exporter.lastReport = null;
      exporter.batchQueue.clear();
      mastering.resetForNewTake();
      previewLevel.resetForNewTake();
      expandedEq.clear();
      unlinkedPairs.clear();
      opening = false;
      notifyListeners();
      // Persist immediately so a session migrated from a legacy sibling file
      // lands in the app container even if the user changes nothing.
      await saveSession();
      _analyze(source);
      if (mastering.enabled) {
        // Warm the reference profile from its cache so a later export (or
        // multi-export) doesn't stall on a fresh analysis.
        unawaited(mastering.ensureProfile().catchError((_) => null));
      }
    } catch (e, st) {
      DebugLog.error('open ${_logName(source)}', e, st);
      opening = false;
      error = e.toString();
      notifyListeners();
    }
  }

  /// Open a take that has no file behind it (web): the header chunks are
  /// fetched through [sourceReader], and the saved mix comes out of the app
  /// container the same way it does natively — see [_storedSessionJson].
  Future<rust.RecordingInfo> _loadByRanges(
    String source,
    RangeReader reader,
  ) async => loadRecordingByRanges(
    reader,
    sourceSize,
    source: source,
    sessionJson: await storedSessionJson(_sessionPath),
  );

  static const int _waveformBuckets = 600;

  Future<void> _analyze(String source) async {
    // The analysis pass reads the whole multi-GB file — cached results make
    // returning to a take instant (key includes the frame count, so
    // re-recorded files invalidate naturally).
    final numFrames = recording!.numFrames;
    final cached = await AnalysisCache.load(
      source,
      numFrames,
      _waveformBuckets,
    );
    if (cached != null && recording?.path == source) {
      waveforms = cached.waveforms;
      bpm = cached.bpm;
      notifyListeners();
      return;
    }
    analyzing = true;
    notifyListeners();
    try {
      final reader = sourceReader;
      final analysis = reader != null
          // No file to hand the engine: push the data payload block by
          // block, so peak memory stays at one block (PLAN-PWA S2b).
          ? await analyzeByRanges(reader, sourceSize, buckets: _waveformBuckets)
          : await rust.analyzeRecording(
              path: source,
              buckets: BigInt.from(_waveformBuckets),
              fd: await inputFdFor(source),
            );
      waveforms = analysis.waveforms;
      bpm = analysis.bpm;
      unawaited(
        AnalysisCache.save(source, numFrames, _waveformBuckets, analysis),
      );
    } catch (_) {
      // Analysis is decoration (waveforms + BPM badge) — a failure must
      // never block mixing, so the strips simply render without waveforms.
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

  /// Pair base names the user has unlinked individually (chip on the strip).
  /// Cleared when a new recording is opened.
  final Set<String> unlinkedPairs = {};

  void _syncPair(TrackUi from) {
    final partner = pairPartnerOf(tracks, from);
    if (partner == null) return;
    syncPairOnto(partner, from);
  }

  /// A mix edit reaches the running player and invalidates both whole-file
  /// measurements: the mastering preview's analysis and the export level the
  /// preview plays at. Both keep their frozen value and say they are stale.
  void _afterMixEdit() {
    mastering.markMixEdited();
    previewLevel.markMixEdited();
    playback.pushLiveParams();
  }

  void updateTrack(TrackUi track, void Function(TrackUi) change) {
    change(track);
    if (isPairLinked(track)) _syncPair(track);
    _afterMixEdit();
    scheduleSave();
    notifyListeners();
  }

  void toggleLinkPairs() {
    linkPairs = !linkPairs;
    notifyListeners();
  }

  /// True when the track has a " L"/" R" partner in the current recording.
  bool isPaired(TrackUi t) => pairPartnerOf(tracks, t) != null;

  /// True when edits to this track currently mirror to its partner.
  bool isPairLinked(TrackUi t) {
    final base = pairBaseOf(t.name);
    return linkPairs &&
        base != null &&
        !unlinkedPairs.contains(base) &&
        pairPartnerOf(tracks, t) != null;
  }

  /// Unlink or relink one pair. Relinking copies the tapped side onto the
  /// partner (pan mirrored), so both strips agree again immediately.
  void togglePairLink(TrackUi t) {
    final base = pairBaseOf(t.name);
    if (base == null) return;
    if (unlinkedPairs.remove(base)) {
      if (linkPairs) {
        _syncPair(t);
        _afterMixEdit();
        scheduleSave();
      }
    } else {
      unlinkedPairs.add(base);
    }
    notifyListeners();
  }

  // ── A/B mix snapshots ─────────────────────────────────────────────────────

  final Map<String, _MixSnapshot> _snapshots = {};

  bool hasSnapshot(String slot) => _snapshots.containsKey(slot);

  void storeSnapshot(String slot) {
    _snapshots[slot] = _MixSnapshot(
      tracks: tracks.map((t) => t.toApi()).toList(),
      loudness: loudness,
      customLufs: customLufs,
      format: format,
    );
    notifyListeners();
  }

  /// Recall `slot` if stored; otherwise store the current mix into it.
  void recallOrStoreSnapshot(String slot) {
    final snap = _snapshots[slot];
    if (snap == null) {
      storeSnapshot(slot);
      return;
    }
    tracks = snap.tracks.map(TrackUi.fromApi).toList();
    loudness = snap.loudness;
    customLufs = snap.customLufs;
    format = snap.format;
    // A snapshot can carry a different loudness target, so the gain follows
    // it — the measurement itself is stale either way (_afterMixEdit).
    previewLevel.recomputeGain();
    _afterMixEdit();
    scheduleSave();
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
  rust.ApiMaster get master =>
      masterFor(loudness: loudness, customLufs: customLufs, format: format);

  /// Master settings for an arbitrary loudness/format combination — the
  /// current mix (trim, fades, limiter) with only the output target swapped.
  /// Used by [master] and by batch-export jobs.
  rust.ApiMaster masterFor({
    required LoudnessChoice loudness,
    required double customLufs,
    required rust.ApiFormat format,
  }) => rust.ApiMaster(
    loudness: switch (loudness) {
      LoudnessChoice.none => const rust.ApiLoudness(
        mode: rust.ApiLoudnessMode.none,
        value: 0,
      ),
      LoudnessChoice.peakMinus1 => const rust.ApiLoudness(
        mode: rust.ApiLoudnessMode.peakDbfs,
        value: -1,
      ),
      LoudnessChoice.lufs14 => const rust.ApiLoudness(
        mode: rust.ApiLoudnessMode.lufsIntegrated,
        value: -14,
      ),
      LoudnessChoice.lufs16 => const rust.ApiLoudness(
        mode: rust.ApiLoudnessMode.lufsIntegrated,
        value: -16,
      ),
      LoudnessChoice.lufs23 => const rust.ApiLoudness(
        mode: rust.ApiLoudnessMode.lufsIntegrated,
        value: -23,
      ),
      LoudnessChoice.lufsCustom => rust.ApiLoudness(
        mode: rust.ApiLoudnessMode.lufsIntegrated,
        value: customLufs,
      ),
    },
    format: format,
    limiterEnabled: true,
    ceilingDbtp: -1.0,
    dither: true,
    trimStartFrame: BigInt.from(((trimStartSeconds ?? 0) * sampleRate).round()),
    trimEndFrame: trimEndSeconds != null
        ? BigInt.from((trimEndSeconds! * sampleRate).round())
        : null,
    fadeInMs: trimStartSeconds != null ? fadeMs : 0,
    fadeOutMs: trimEndSeconds != null ? fadeMs : 0,
    masteringEnabled: mastering.enabled,
    masteringReferences: mastering.references,
    // Only the preview reads this; renders normalise from their own pass 1.
    // 1.0 until the mix has been measured and the switch is on.
    previewNormGain: previewLevel.gain,
  );

  void setTrimStart(double? seconds) {
    trimStartSeconds = seconds?.clamp(0, durationSeconds);
    mastering.markMixEdited(); // analysis covers the trim range
    scheduleSave();
    notifyListeners();
  }

  void setTrimEnd(double? seconds) {
    trimEndSeconds = seconds?.clamp(0, durationSeconds);
    mastering.markMixEdited();
    scheduleSave();
    notifyListeners();
  }

  void _restoreMaster(rust.ApiMaster m) {
    format = m.format;
    mastering.restoreFromMaster(m);
    final sr = recording?.sampleRate ?? 48000;
    final start = m.trimStartFrame.toInt();
    trimStartSeconds = start > 0 ? start / sr : null;
    trimEndSeconds = m.trimEndFrame != null
        ? m.trimEndFrame!.toInt() / sr
        : null;
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

  /// Debounced session autosave; used by every mix-level edit.
  void scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), saveSession);
  }

  Future<void> saveSession() async {
    final sessionPath = _sessionPath;
    if (recording == null || sessionPath == null) return;
    try {
      if (sourceReader != null) {
        // The engine writes sessions with `std::fs`, which wasm has none of,
        // so Dart serialises it and puts it in the container at the very path
        // the native build uses — same file name, same hash, same contents.
        await writeTextFile(
          sessionPath,
          rust.sessionToJson(
            tracks: tracks.map((t) => t.toApi()).toList(),
            master: master,
          ),
        );
        return;
      }
      await rust.saveSession(
        sessionPath: sessionPath,
        tracks: tracks.map((t) => t.toApi()).toList(),
        master: master,
      );
    } catch (e, st) {
      DebugLog.error('session save', e, st);
      error = 'Session save failed: $e';
      notifyListeners();
    }
  }

  void setLoudness(LoudnessChoice c) {
    loudness = c;
    // The measurement still holds — only the target moved, so the gain is
    // recomputed rather than the file re-read.
    previewLevel.recomputeGain();
    playback.pushLiveParams();
    scheduleSave();
    notifyListeners();
  }

  void setFormat(rust.ApiFormat f) {
    format = f;
    scheduleSave();
    notifyListeners();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    playback.dispose();
    super.dispose();
  }
}

/// Immutable copy of the full mix for A/B comparison.
class _MixSnapshot {
  _MixSnapshot({
    required this.tracks,
    required this.loudness,
    required this.customLufs,
    required this.format,
  });

  final List<rust.ApiTrack> tracks;
  final LoudnessChoice loudness;
  final double customLufs;
  final rust.ApiFormat format;
}
