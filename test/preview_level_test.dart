/// State machine of the export-level preview (#113). No engine call is made:
/// the gain itself is computed in Rust and covered by
/// `preview_gain_equals_the_gain_the_render_applies` — what is tested here is
/// when the app considers a measurement valid, stale, or gone.
library;

import 'package:durecmix/src/rust/api/mixer.dart' as rust;
import 'package:durecmix/state/mixer_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// A measured mix, as the engine would report it.
const _measured = rust.ApiMixLevel(peak: 6.3, integratedLufs: -8.2);

MixerState _measuredState() {
  final state = MixerState();
  state.previewLevel
    ..enabled = true
    ..level = _measured
    ..gain = 0.14; // ~-17 dB, a DUREC take normalised to -1 dBFS
  return state;
}

void main() {
  group('staleness', () {
    test('a mix edit makes the measurement stale', () {
      final state = _measuredState();
      expect(state.previewLevel.stale, isFalse);

      state.updateTrack(
        state.tracks.isEmpty ? _addTrack(state) : state.tracks.first,
        (t) => t.gainDb = -3,
      );

      expect(
        state.previewLevel.stale,
        isTrue,
        reason: 'the gain was measured for a mix that no longer exists',
      );
    });

    test('the stale gain keeps playing instead of jumping', () {
      final state = _measuredState();
      final before = state.previewLevel.gain;
      state.previewLevel.markMixEdited();
      expect(
        state.previewLevel.gain,
        before,
        reason:
            'a gain that jumps on every fader move is worse than one '
            'that is slightly off and says so',
      );
      expect(state.master.previewNormGain, before);
    });

    test('nothing goes stale before anything was measured', () {
      final state = MixerState();
      state.previewLevel.markMixEdited();
      expect(state.previewLevel.stale, isFalse);
      expect(state.previewLevel.gain, 1.0);
    });

    test('a measurement that is switched off cannot go stale', () {
      final state = _measuredState()..previewLevel.enabled = false;
      state.previewLevel.markMixEdited();
      expect(state.previewLevel.stale, isFalse);
    });
  });

  group('lifecycle', () {
    test('switching off restores the raw mix immediately', () {
      final state = _measuredState();
      state.previewLevel.disable();
      expect(state.previewLevel.gain, 1.0);
      expect(state.master.previewNormGain, 1.0);
      expect(
        state.previewLevel.level,
        isNotNull,
        reason: 'the measurement stays, so switching back on is free',
      );
    });

    test('a new take drops the measurement entirely', () {
      final state = _measuredState()..previewLevel.stale = true;
      state.previewLevel.resetForNewTake();
      expect(state.previewLevel.enabled, isFalse);
      expect(state.previewLevel.level, isNull);
      expect(state.previewLevel.stale, isFalse);
      expect(state.previewLevel.gain, 1.0);
    });

    test('the gain reaches the engine through the master DTO', () {
      final state = _measuredState();
      expect(state.master.previewNormGain, 0.14);
      // Exports must not see it: they normalise from their own pass 1.
      expect(
        state
            .masterFor(
              loudness: LoudnessChoice.lufs14,
              customLufs: -17,
              format: rust.ApiFormat.wav24,
            )
            .loudness
            .value,
        -14,
      );
    });
  });
}

/// The mix-edit path needs a track to edit.
TrackUi _addTrack(MixerState state) {
  final t = TrackUi(
    index: 1,
    name: 'Kick',
    eq: TrackEqUi(
      hpfEnabled: false,
      hpfFreq: 80,
      hpfSlope: rust.ApiHpfSlope.db12,
      low: EqBandUi(enabled: false, freq: 100, gainDb: 0, q: 1),
      mid: EqBandUi(enabled: false, freq: 1000, gainDb: 0, q: 1),
      high: EqBandUi(enabled: false, freq: 8000, gainDb: 0, q: 1),
    ),
  );
  state.tracks = [t];
  return t;
}
