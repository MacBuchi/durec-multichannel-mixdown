import 'dart:async';

import '../src/rust/api/mixer.dart' as rust;
import 'mixer_state.dart';

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

  Timer? _pollTimer;

  Future<void> togglePlay() async {
    if (playing) {
      stop();
      _owner.notify();
      return;
    }
    final rec = _owner.recording;
    if (rec == null) return;
    _owner.error = null;
    try {
      final startFrame = BigInt.from((positionSeconds * rec.sampleRate)
          .round()
          .clamp(0, rec.numFrames.toInt()));
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
    } catch (e) {
      _owner.error = e.toString();
    }
    _owner.notify();
  }

  void seek(double seconds) {
    positionSeconds = seconds.clamp(0, _owner.durationSeconds);
    if (playing) {
      rust.playerSeek(
          frame: BigInt.from((positionSeconds * _owner.sampleRate).round()));
    }
    _owner.notify();
  }

  /// Push the current tracks/master (and preview mastering plan) into the
  /// running player; a no-op while stopped.
  void pushLiveParams() {
    if (!playing) return;
    final stats = _owner.mastering.previewStats;
    unawaited(rust
        .playerUpdateParams(
          tracks: _owner.tracks.map((t) => t.toApi()).toList(),
          master: _owner.master,
          masteringStats: stats,
          reference: stats != null ? _owner.mastering.profile : null,
        )
        // Racing a player stop is harmless — the next start resends the
        // full parameter set anyway.
        .catchError((_) {}));
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
  }

  void dispose() {
    _pollTimer?.cancel();
    if (playing) rust.playerStop();
  }
}
