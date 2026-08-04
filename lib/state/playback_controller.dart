import 'dart:async';

import '../src/rust/api/mixer.dart' as rust;
import 'mixer_state.dart';
import 'web_playback.dart';
import 'debug_log.dart';

/// Live playback: start/stop/seek plus the 30 Hz meter poll. Owned and
/// composed by [MixerState], which stays the single rebuild root — all
/// changes are published through `owner.notify()`.
class PlaybackController {
  PlaybackController(this._owner);

  final MixerState _owner;

  bool playing = false;
  double positionSeconds = 0;
  double peakL = 0; // linear 0..1+
  double peakR = 0;
  double lufsMomentary = -70;
  double lufsIntegrated = -70;
  double truePeak = 0; // linear, running max since start/seek
  double correlation = 0;

  /// Held peak of every source channel, linear, **post-EQ and pre-fader**
  /// (#115). Index `track.index - 1`; empty while nothing is playing.
  ///
  /// The post-fader reading is this times the track's gain, so both meter
  /// modes come from one array and switching needs no engine call.
  List<double> trackPeaks = const [];

  Timer? _pollTimer;

  /// Browser-preview diagnostics (#114), kept after playback stops so they
  /// can still be read out of the Settings dialog. `null` while nothing has
  /// played in the browser — on native there is no pump to report on.
  ///
  /// [webUnderruns] counts how often the worklet found the ring empty, which
  /// is what a click sounds like; [webMixRate] is the measured mixing speed
  /// the pacing derives its buffers from, and [webTailSeconds] the buffer it
  /// arrived at — the number to ask for when a device still clicks.
  int? webUnderruns;
  double? webMixRate;
  double? webTailSeconds;

  /// Set while a take opened in the browser is playing; native takes keep
  /// using the engine's own player.
  WebPlayback? _web;

  Future<void> togglePlay() async {
    if (playing) {
      await stopAsync();
      _owner.notify();
      return;
    }
    final rec = _owner.recording;
    if (rec == null) return;
    _owner.error = null;
    if (_owner.sourceReader != null) {
      await _startWeb();
      return;
    }
    try {
      final startFrame = BigInt.from(
        (positionSeconds * rec.sampleRate).round().clamp(
          0,
          rec.numFrames.toInt(),
        ),
      );
      final stats = _owner.mastering.previewStats;
      await rust.playerStart(
        path: rec.path,
        tracks: _owner.tracks.map((t) => t.toApi()).toList(),
        master: _owner.master,
        startFrame: startFrame,
        fd: await _owner.inputFdFor(rec.path),
        masteringStats: stats,
        reference: stats != null ? _owner.mastering.profile : null,
      );
      playing = true;
      _startPolling();
    } catch (e, st) {
      DebugLog.error('playback start', e, st);
      _owner.error = e.toString();
    }
    _owner.notify();
  }

  /// Browser playback: the engine mixes, an AudioWorklet plays, and the pump
  /// in [WebPlayback] keeps the ring between them full.
  Future<void> _startWeb() async {
    final web = WebPlayback(
      read: _owner.sourceReader!,
      fileSize: _owner.sourceSize,
      tracks: () => _owner.tracks.map((t) => t.toApi()).toList(),
      master: () => _owner.master,
      mastering: () => _owner.mastering.previewStats,
      reference: () => _owner.mastering.previewStats != null
          ? _owner.mastering.profile
          : null,
      onTick: _pollWeb,
      onError: (e) {
        DebugLog.error('browser playback', e);
        _owner.error = e.toString();
        _web = null;
        playing = false;
        _stopPolling();
        _owner.notify();
      },
    );
    try {
      await web.start((positionSeconds * _owner.sampleRate).round());
      _web = web;
      playing = true;
    } catch (e, st) {
      DebugLog.error('browser playback start', e, st);
      _owner.error = e.toString();
      await web.stop();
    }
    _owner.notify();
  }

  void _pollWeb() {
    final web = _web;
    if (web == null) return;
    positionSeconds = web.positionSeconds;
    webUnderruns = web.underruns;
    webMixRate = web.mixRate;
    webTailSeconds = web.tailSeconds;
    final id = web.playerId;
    final s = id == null ? null : rust.webPlayerState(id: id);
    if (s != null) {
      peakL = s.peakL;
      peakR = s.peakR;
      lufsMomentary = s.lufsMomentary;
      lufsIntegrated = s.lufsIntegrated;
      truePeak = s.truePeak;
      correlation = s.correlation;
      trackPeaks = s.trackPeaks;
    }
    if (web.finished) {
      unawaited(stopAsync());
    }
    _owner.notify();
  }

  /// [stop] for callers that can await — the browser's audio context has to
  /// be closed asynchronously.
  Future<void> stopAsync() async {
    final web = _web;
    _web = null;
    if (web != null) {
      playing = false;
      _stopPolling();
      await web.stop();
      return;
    }
    stop();
  }

  void seek(double seconds) {
    positionSeconds = seconds.clamp(0, _owner.durationSeconds);
    final frame = (positionSeconds * _owner.sampleRate).round();
    if (_web != null) {
      unawaited(_web!.seek(frame));
    } else if (playing) {
      rust.playerSeek(frame: BigInt.from(frame));
    }
    _owner.notify();
  }

  /// Push the current tracks/master (and preview mastering plan) into the
  /// running player; a no-op while stopped.
  void pushLiveParams() {
    if (!playing) return;
    if (_web != null) {
      unawaited(_web!.pushParams().catchError((_) {}));
      return;
    }
    final stats = _owner.mastering.previewStats;
    unawaited(
      rust
          .playerUpdateParams(
            tracks: _owner.tracks.map((t) => t.toApi()).toList(),
            master: _owner.master,
            masteringStats: stats,
            reference: stats != null ? _owner.mastering.profile : null,
          )
          // Racing a player stop is harmless — the next start resends the
          // full parameter set anyway.
          .catchError((_) {}),
    );
  }

  /// Stop playback and the meter poll (take switch, dispose, stop button).
  void stop() {
    if (playing) {
      rust.playerStop();
      playing = false;
    }
    _stopPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final s = rust.playerState();
      positionSeconds = s.positionFrames.toInt() / _owner.sampleRate;
      peakL = s.peakL;
      peakR = s.peakR;
      lufsMomentary = s.lufsMomentary;
      lufsIntegrated = s.lufsIntegrated;
      truePeak = s.truePeak;
      correlation = s.correlation;
      trackPeaks = s.trackPeaks;
      if (!s.playing && playing) {
        playing = false;
        _stopPolling();
      }
      _owner.notify();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    peakL = 0;
    peakR = 0;
    // Bars left standing after stop would read as signal on a silent mix.
    trackPeaks = const [];
  }

  void dispose() {
    _pollTimer?.cancel();
    if (_web != null) {
      unawaited(_web!.stop());
      _web = null;
      return;
    }
    if (playing) rust.playerStop();
  }
}
