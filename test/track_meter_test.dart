/// The per-track level meter (#115) as the user sees it.
///
/// The measurement itself is the engine's and is covered there
/// (`track_meters_read_pre_fader_so_post_fader_is_exactly_gain_times_it` and
/// friends). What is tested here is what the strip does with it: the mode
/// switch is plain arithmetic on this side, a muted track stays visible rather
/// than blank, and the bar has to fit a row that was already full.
library;

import 'dart:typed_data';

import 'package:durecmix/src/rust/api/mixer.dart' as rust;
import 'package:durecmix/state/app_settings.dart';
import 'package:durecmix/state/mixer_state.dart';
import 'package:durecmix/ui/app_colors.dart';
import 'package:durecmix/ui/meters.dart';
import 'package:durecmix/ui/track_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

EqBandUi _band() => EqBandUi(enabled: false, freq: 100, gainDb: 0, q: 1);

TrackUi _track(int index, {double gainDb = 0}) => TrackUi(
  index: index,
  name: 'T$index',
  eq: TrackEqUi(
    hpfEnabled: false,
    hpfFreq: 80,
    hpfSlope: rust.ApiHpfSlope.db12,
    low: _band(),
    mid: _band(),
    high: _band(),
  ),
)..gainDb = gainDb;

/// A state whose playback reports [peaks] for the source channels.
MixerState _state(List<TrackUi> tracks, List<double> peaks) {
  final state = MixerState();
  state.tracks = tracks;
  state.playback.trackPeaks = Float32List.fromList(peaks);
  return state;
}

Future<TrackLevelMeter> _pumpStrip(
  WidgetTester tester,
  MixerState state,
  TrackUi track, {
  Size size = const Size(1200, 400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: [AppColors.dark]),
      home: Scaffold(
        body: TrackStrip(state: state, track: track),
      ),
    ),
  );
  await tester.pump();
  return tester.widget<TrackLevelMeter>(find.byType(TrackLevelMeter));
}

void main() {
  setUp(() => AppSettings.trackMeterMode.value = TrackMeterMode.postFader);

  testWidgets('post-fader shows the measurement times the fader', (
    tester,
  ) async {
    // −12 dB fader, so a quarter of the level (0.2512…).
    final track = _track(1, gainDb: -12);
    final meter = await _pumpStrip(tester, _state([track], [0.8]), track);
    expect(meter.peak, closeTo(0.8 * 0.251188, 1e-4));
    expect(meter.audible, isTrue);
  });

  testWidgets('pre-fader shows the measurement untouched', (tester) async {
    AppSettings.trackMeterMode.value = TrackMeterMode.preFader;
    final track = _track(1, gainDb: -12);
    final meter = await _pumpStrip(tester, _state([track], [0.8]), track);
    // closeTo, not equals: the engine reports f32, so 0.8 arrives as
    // 0.800000011920929 once it is widened to a double.
    expect(
      meter.peak,
      closeTo(0.8, 1e-6),
      reason: 'a fader pulled down must not hide what arrives on the track',
    );
  });

  testWidgets('flipping the mode repaints without rebuilding the mixer', (
    tester,
  ) async {
    final track = _track(1, gainDb: -20);
    await _pumpStrip(tester, _state([track], [0.5]), track);
    expect(
      tester.widget<TrackLevelMeter>(find.byType(TrackLevelMeter)).peak,
      closeTo(0.05, 1e-3),
    );

    AppSettings.trackMeterMode.value = TrackMeterMode.preFader;
    await tester.pump();

    expect(
      tester.widget<TrackLevelMeter>(find.byType(TrackLevelMeter)).peak,
      closeTo(0.5, 1e-6),
    );
  });

  group('audible', () {
    testWidgets('a muted track keeps its level and is greyed', (tester) async {
      final track = _track(1)..muted = true;
      final meter = await _pumpStrip(tester, _state([track], [0.6]), track);
      expect(
        meter.peak,
        closeTo(0.6, 1e-6),
        reason: 'seeing that a muted track has signal is the point',
      );
      expect(meter.audible, isFalse);
    });

    testWidgets('a track out of the mix is greyed too', (tester) async {
      final track = _track(1)..inMix = false;
      final meter = await _pumpStrip(tester, _state([track], [0.6]), track);
      expect(meter.audible, isFalse);
    });

    testWidgets('solo elsewhere greys this one', (tester) async {
      final soloed = _track(1)..solo = true;
      final other = _track(2);
      final meter = await _pumpStrip(
        tester,
        _state([soloed, other], [0.3, 0.6]),
        other,
      );
      expect(
        meter.peak,
        closeTo(0.6, 1e-6),
        reason: 'solo mutes the audio, not the meter',
      );
      expect(meter.audible, isFalse);
    });

    testWidgets('the soloed track itself stays lit', (tester) async {
      final soloed = _track(1)..solo = true;
      final meter = await _pumpStrip(
        tester,
        _state([soloed, _track(2)], [0.3, 0.6]),
        soloed,
      );
      expect(meter.audible, isTrue);
    });
  });

  testWidgets('nothing playing means an empty bar, not a crash', (
    tester,
  ) async {
    final track = _track(7);
    // No peaks at all (stopped), and a channel index past the array.
    final meter = await _pumpStrip(tester, _state([track], const []), track);
    expect(meter.peak, 0.0);
  });

  for (final size in const [Size(320, 640), Size(411, 891), Size(1200, 400)]) {
    testWidgets('the strip still fits at ${size.width.toInt()} dp', (
      tester,
    ) async {
      final track = _track(1, gainDb: -6);
      await _pumpStrip(tester, _state([track], [0.9]), track, size: size);
      expect(find.byType(TrackLevelMeter), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the row was already full before the meter was added to it',
      );
    });
  }
}
