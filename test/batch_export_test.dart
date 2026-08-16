/// Where the multi-file export puts its output — the one part of it that can
/// be checked without an engine.
///
/// No Rust library is loaded in a VM test, so every render fails; that is on
/// purpose here and asserted, so the test cannot quietly pass by not rendering
/// anything. What it does prove is the branch #111 added: a **null folder is
/// the browser's mode**, and then nothing must be created on a filesystem —
/// while a real folder still gets its `Mixdown/` subfolder as before.
library;

import 'dart:io';

import 'package:durecmix/src/rust/api/mixer.dart' as rust;
import 'package:durecmix/state/batch_export.dart';
import 'package:durecmix/state/mixer_state.dart';
import 'package:durecmix/state/wav_browser.dart';
import 'package:flutter_test/flutter_test.dart';

MultiExportConfig _config() {
  final state = MixerState();
  return MultiExportConfig(
    tracks: const [],
    master: state.master,
    loudness: LoudnessChoice.peakMinus1,
    customLufs: -17,
    format: rust.ApiFormat.wav24,
  );
}

/// A take with a byte reader, the shape `pickRecordings()` produces on web.
WavEntry _webEntry(String name) =>
    WavEntry(source: 'blob:$name', name: name, sizeBytes: 4096)
      ..read = ((start, end) async =>
          throw StateError('no engine in a VM test'))
      ..outputStem = name.replaceAll('.wav', '');

void main() {
  test('a null folder downloads and touches no filesystem', () async {
    final runner = MultiExportRunner();
    final entries = [_webEntry('take_a.wav'), _webEntry('take_b.wav')];

    await runner.run(entries, null, _config());

    expect(
      runner.downloaded,
      isTrue,
      reason:
          'the result bar must say "downloaded", not "exported to Mixdown/"',
    );
    expect(runner.running, isFalse);
    // Both entries were attempted and failed on the missing engine — proof the
    // run reached the per-take work rather than bailing out early.
    for (final e in entries) {
      expect(runner.statusFor(e).phase, EntryPhase.failed);
      expect(runner.statusFor(e).error, isNotNull);
    }
    expect(runner.outputs, isEmpty);
  });

  test('a real folder still gets its Mixdown subfolder', () async {
    final dir = await Directory.systemTemp.createTemp('mixstack-batch');
    addTearDown(() => dir.delete(recursive: true));

    final runner = MultiExportRunner();
    // No reader: the native path, which asks the engine for the file.
    final entry = WavEntry(source: '${dir.path}/take.wav', name: 'take.wav');
    await runner.run([entry], dir.path, _config());

    expect(runner.downloaded, isFalse);
    expect(
      Directory('${dir.path}/Mixdown').existsSync(),
      isTrue,
      reason: 'the folder is created before rendering, as it always was',
    );
    expect(runner.statusFor(entry).phase, EntryPhase.failed);
  });

  test('an empty selection does nothing at all', () async {
    final runner = MultiExportRunner();
    await runner.run(const [], null, _config());
    expect(runner.running, isFalse);
    expect(runner.total, 0);
    expect(runner.downloaded, isFalse, reason: 'no run, no verdict');
  });
}
