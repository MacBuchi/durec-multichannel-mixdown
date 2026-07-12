/// End-to-end smoke test of the real app against the real Rust engine —
/// the command-line replacement for clicking through the GUI by hand:
///
///   flutter test integration_test -d macos
///
/// It runs inside the app process (WidgetTester injects events internally,
/// so it never touches the real mouse/keyboard) and uses a tiny synthetic
/// DUREC-like WAV generated into the app's sandbox-writable temp directory.
/// The native file picker itself stays a manual-test surface; the test
/// enters through `MixerState.open`, which is the picker's target.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:durecmix/main.dart';
import 'package:durecmix/state/mixer_state.dart';
import 'package:durecmix/src/rust/frb_generated.dart';
import 'package:durecmix/ui/mixer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String fixturePath;

  setUpAll(() async {
    await RustLib.init();
    tempDir = await Directory.systemTemp.createTemp('durecmix_test');
    fixturePath = '${tempDir.path}/fixture_4ch.wav';
    File(fixturePath).writeAsBytesSync(_buildFixtureWav());
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  testWidgets('open → mix → EQ → export against the real engine',
      (tester) async {
    await tester.pumpWidget(const DurecMixApp());
    await tester.pumpAndSettle();
    expect(find.text('Open recording'), findsOneWidget);

    // Open the fixture (the picker's target API; the native panel itself
    // cannot be driven headlessly).
    final dynamic screenState = tester.state(find.byType(MixerScreen));
    final MixerState state = screenState.state as MixerState;
    await state.open(fixturePath);
    await tester.pumpAndSettle();

    // iXML track names and the stereo-pair pan heuristic arrived intact.
    expect(state.error, isNull);
    expect(state.tracks, hasLength(4));
    expect(find.text('Vocals'), findsOneWidget);
    expect(find.text('Kick'), findsOneWidget);
    expect(state.tracks[2].pan, -1.0); // "Keys L"
    expect(state.tracks[3].pan, 1.0); // "Keys R"

    // Mute toggle through a real tap on the first track's M chip.
    await tester.tap(find.text('M').first);
    await tester.pump();
    expect(state.tracks[0].muted, isTrue);
    await tester.tap(find.text('M').first);
    await tester.pump();
    expect(state.tracks[0].muted, isFalse);

    // EQ panel: expand via the EQ chip, enable the HPF via its switch.
    await tester.tap(find.text('EQ').first);
    await tester.pumpAndSettle();
    expect(find.text('HPF'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(state.tracks[0].eq.hpfEnabled, isTrue);

    // Session autosave (debounced 1 s) must land in the app container.
    await tester.pump(const Duration(seconds: 2));
    await state.saveSession();
    expect(state.error, isNull);

    // Export at a custom −17.5 LUFS through the real two-pass engine
    // (non-preset value, so the session round-trip below must restore it
    // as `lufsCustom` rather than canonicalising to a preset).
    state.customLufs = -17.5;
    state.setLoudness(LoudnessChoice.lufsCustom);
    final outPath = '${tempDir.path}/mix.wav';
    await state.export(outPath);
    await tester.pumpAndSettle();

    expect(state.error, isNull);
    final report = state.lastReport;
    expect(report, isNotNull);
    expect(File(outPath).existsSync(), isTrue);
    // The engine's own tests verify measurement accuracy; here we check the
    // report is coherent: target hit and ceiling respected.
    expect((report!.integratedLufs - -17.5).abs(), lessThan(0.5));
    expect(report.truePeakDbtp, lessThanOrEqualTo(-1.0 + 0.05));
    expect(find.textContaining('Exported:'), findsOneWidget);

    // Reopen: the EQ setting and loudness choice round-trip via the session.
    await state.open(fixturePath);
    await tester.pumpAndSettle();
    expect(state.tracks[0].eq.hpfEnabled, isTrue);
    expect(state.loudness, LoudnessChoice.lufsCustom);
    expect(state.customLufs, -17.5);
  });
}

/// 4-channel, 16-bit, 44.1 kHz, 2 s WAV with a DUREC-style iXML track list —
/// the same shape as `engine/examples/gen_fixture.rs`, small enough to build
/// inline (the app sandbox cannot read files the test didn't create itself).
Uint8List _buildFixtureWav() {
  const sampleRate = 44100;
  const seconds = 2;
  const channels = 4;
  const tracks = [
    ('Vocals', 440.0, 0.25),
    ('Kick', 55.0, 0.5),
    ('Keys L', 330.0, 0.125),
    ('Keys R', 331.0, 0.125),
  ];

  final frames = sampleRate * seconds;
  final data = BytesBuilder();
  for (var n = 0; n < frames; n++) {
    final t = n / sampleRate;
    for (final (_, freq, amp) in tracks) {
      final v = (amp * math.sin(2 * math.pi * freq * t) * 32767).round();
      data.add([v & 0xFF, (v >> 8) & 0xFF]);
    }
  }

  final ixmlTracks = StringBuffer();
  for (var i = 0; i < tracks.length; i++) {
    ixmlTracks.write('<TRACK><CHANNEL_INDEX>${i + 1}</CHANNEL_INDEX>'
        '<INTERLEAVE_INDEX>${i + 1}</INTERLEAVE_INDEX>'
        '<NAME>${tracks[i].$1}</NAME></TRACK>');
  }
  final ixml = '<?xml version="1.0" encoding="UTF-8"?><BWFXML>'
      '<IXML_VERSION>1.5</IXML_VERSION><TRACK_LIST>'
      '<TRACK_COUNT>$channels</TRACK_COUNT>$ixmlTracks</TRACK_LIST></BWFXML>';

  Uint8List chunk(String id, List<int> payload) {
    final b = BytesBuilder();
    b.add(ascii.encode(id));
    b.add(_u32(payload.length));
    b.add(payload);
    if (payload.length.isOdd) b.addByte(0);
    return b.toBytes();
  }

  const blockAlign = channels * 2;
  final fmt = BytesBuilder()
    ..add(_u16(1)) // PCM
    ..add(_u16(channels))
    ..add(_u32(sampleRate))
    ..add(_u32(sampleRate * blockAlign))
    ..add(_u16(blockAlign))
    ..add(_u16(16));

  final body = BytesBuilder()
    ..add(ascii.encode('WAVE'))
    ..add(chunk('fmt ', fmt.toBytes()))
    ..add(chunk('data', data.toBytes()))
    ..add(chunk('iXML', utf8.encode(ixml)));

  final bodyBytes = body.toBytes();
  final file = BytesBuilder()
    ..add(ascii.encode('RIFF'))
    ..add(_u32(bodyBytes.length))
    ..add(bodyBytes);
  return file.toBytes();
}

Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
