import '../src/rust/api/mixer.dart' as rust;
import 'mixer_state.dart';
import 'range_scan.dart';
import 'debug_log.dart';

/// Playing the preview at the level the export will have (#113).
///
/// The export normalises with a gain it computes from a measurement over the
/// whole file, and until now the preview left that gain out: with a DUREC
/// take, whose unity mix sits around +16 dBFS, the export cuts ~17 dB while
/// the preview handed the limiter the raw signal and let it pump. Same chain,
/// different sound — the one kind of deviation a mixer must not have.
///
/// The measurement cannot be free (one read of the file), so this follows the
/// mastering preview's shape: switched on explicitly, with progress, and mix
/// edits mark it stale instead of re-scanning behind the user's back. A stale
/// gain keeps playing — a value that jumps on every fader move would be worse
/// than one that is slightly off.
///
/// Owned and composed by [MixerState], which stays the single rebuild root.
class PreviewLevelController {
  PreviewLevelController(this._owner);

  final MixerState _owner;

  /// The user's switch. Off means the preview plays the raw mix, as before.
  bool enabled = false;

  /// Measurement of the current mix; null until it has run.
  rust.ApiMixLevel? level;

  /// True once the mix changed after the measurement — the gain in [gain] is
  /// then out of date but deliberately kept.
  bool stale = false;

  bool measuring = false;
  double progress = 0;

  /// The gain handed to the preview, linear. **Stored, not computed on
  /// demand:** it travels inside `ApiMaster`, and building that DTO must not
  /// call back into the engine on every rebuild.
  double gain = 1.0;

  /// Whether the meters and the preview currently show export level.
  bool get active => enabled && level != null && gain != 1.0;

  /// Every mix edit invalidates a whole-file measurement.
  void markMixEdited() {
    if (enabled && level != null) stale = true;
  }

  /// A measurement belongs to one take and one mix; nothing survives a switch.
  void resetForNewTake() {
    enabled = false;
    level = null;
    stale = false;
    gain = 1.0;
  }

  /// Recompute the gain from the last measurement — after the loudness target
  /// or mastering changed, where the level itself still holds.
  ///
  /// The formula lives in the engine (`normGainForMix`), never here: a second
  /// implementation is how "what you hear" and "what you get" drift apart.
  void recomputeGain() {
    final l = level;
    if (!enabled || l == null) {
      gain = 1.0;
      return;
    }
    gain = rust.normGainForMix(master: _owner.master, level: l);
  }

  /// Turn the preview's export level on, measuring the mix first.
  Future<void> enable() async {
    if (_owner.recording == null || measuring) return;
    await _measure();
    if (level == null) return;
    enabled = true;
    stale = false;
    recomputeGain();
    _owner.notify();
    _owner.playback.pushLiveParams();
  }

  void disable() {
    enabled = false;
    gain = 1.0;
    _owner.notify();
    _owner.playback.pushLiveParams();
  }

  /// Measure again after mix edits — explicit, like the mastering refresh.
  Future<void> refresh() async {
    if (measuring) return;
    await _measure();
    stale = false;
    recomputeGain();
    _owner.notify();
    _owner.playback.pushLiveParams();
  }

  Future<void> _measure() async {
    final rec = _owner.recording;
    if (rec == null) return;
    measuring = true;
    progress = 0;
    _owner.notify();
    try {
      final reader = _owner.sourceReader;
      if (reader != null) {
        // Browser: no path, so the same scan is fed byte ranges.
        level = await measureMixLevelByRanges(
          reader,
          _owner.sourceSize,
          tracks: _owner.tracks.map((t) => t.toApi()).toList(),
          master: _owner.master,
          onProgress: (p) {
            progress = p;
            _owner.notify();
          },
        );
      } else {
        await for (final ev in rust.analyzeMixLevel(
          path: rec.path,
          tracks: _owner.tracks.map((t) => t.toApi()).toList(),
          master: _owner.master,
          fd: _owner.isSafSource ? await _owner.inputFdFor(rec.path) : null,
        )) {
          progress = ev.progress;
          if (ev.level != null) level = ev.level;
          _owner.notify();
        }
      }
    } catch (e, st) {
      DebugLog.error('mix level scan', e, st);
      _owner.error = e.toString();
    } finally {
      measuring = false;
      _owner.notify();
    }
  }
}
