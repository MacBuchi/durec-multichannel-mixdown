/// Unit tests for the pure-ish MixerState logic: stereo-pair mirroring,
/// link/unlink/relink, A/B snapshots, batch-queue handling, export naming
/// and the master DTO mapping. No engine call is made — the E2E flow stays
/// in integration_test/app_test.dart.
library;

import 'package:durecmix/src/rust/api/mixer.dart' as rust;
import 'package:durecmix/state/mixer_state.dart';
import 'package:durecmix/state/stereo_pairs.dart';
import 'package:flutter_test/flutter_test.dart';

EqBandUi _band() => EqBandUi(enabled: false, freq: 100, gainDb: 0, q: 1);

TrackUi _track(int index, String name) => TrackUi(
      index: index,
      name: name,
      eq: TrackEqUi(
        hpfEnabled: false,
        hpfFreq: 80,
        hpfSlope: rust.ApiHpfSlope.db12,
        low: _band(),
        mid: _band(),
        high: _band(),
      ),
    );

MixerState _stateWithPair() {
  final state = MixerState();
  state.tracks = [
    _track(1, 'Vocals'),
    _track(2, 'Keys L'),
    _track(3, 'Keys R'),
  ];
  return state;
}

void main() {
  group('stereo pair helpers', () {
    test('pairBaseOf detects " L"/" R" suffixes only', () {
      expect(pairBaseOf('Keys L'), 'Keys');
      expect(pairBaseOf('Keys R'), 'Keys');
      expect(pairBaseOf('Vocals'), isNull);
      expect(pairBaseOf('KeysL'), isNull); // no space → no pair
      expect(pairBaseOf('L'), isNull); // needs a base name? "L" ends with nothing valid
    });

    test('pairPartnerOf finds the opposite side or nothing', () {
      final tracks = [_track(1, 'Keys L'), _track(2, 'Keys R'), _track(3, 'Gtr L')];
      expect(pairPartnerOf(tracks, tracks[0])!.name, 'Keys R');
      expect(pairPartnerOf(tracks, tracks[1])!.name, 'Keys L');
      expect(pairPartnerOf(tracks, tracks[2]), isNull); // Gtr R missing
    });

    test('syncPairOnto mirrors everything, pan inverted', () {
      final from = _track(1, 'Keys L')
        ..gainDb = -6
        ..pan = -0.8
        ..muted = true
        ..solo = true
        ..inMix = false
        ..polarityInvert = true;
      from.eq
        ..hpfEnabled = true
        ..hpfFreq = 120
        ..hpfSlope = rust.ApiHpfSlope.db24;
      from.eq.mid
        ..enabled = true
        ..freq = 1500
        ..gainDb = 3.5
        ..q = 2;
      final partner = _track(2, 'Keys R');
      syncPairOnto(partner, from);
      expect(partner.gainDb, -6);
      expect(partner.pan, 0.8); // mirrored
      expect(partner.muted, isTrue);
      expect(partner.solo, isTrue);
      expect(partner.inMix, isFalse);
      expect(partner.polarityInvert, isTrue);
      expect(partner.eq.hpfEnabled, isTrue);
      expect(partner.eq.hpfFreq, 120);
      expect(partner.eq.hpfSlope, rust.ApiHpfSlope.db24);
      expect(partner.eq.mid.enabled, isTrue);
      expect(partner.eq.mid.freq, 1500);
      expect(partner.eq.mid.gainDb, 3.5);
      expect(partner.eq.mid.q, 2);
    });
  });

  group('MixerState pair linking', () {
    test('updateTrack mirrors onto the linked partner', () {
      final state = _stateWithPair();
      state.updateTrack(state.tracks[1], (t) => t.gainDb = -6);
      expect(state.tracks[2].gainDb, -6);
      state.updateTrack(state.tracks[1], (t) => t.pan = -1.0);
      expect(state.tracks[2].pan, 1.0);
      // The unpaired track never mirrors anywhere.
      state.updateTrack(state.tracks[0], (t) => t.gainDb = -3);
      expect(state.tracks[1].gainDb, -6);
    });

    test('global link toggle stops the mirroring', () {
      final state = _stateWithPair();
      state.toggleLinkPairs();
      expect(state.linkPairs, isFalse);
      state.updateTrack(state.tracks[1], (t) => t.gainDb = -6);
      expect(state.tracks[2].gainDb, 0);
    });

    test('per-pair unlink and relink; relink copies the tapped side', () {
      final state = _stateWithPair();
      expect(state.isPairLinked(state.tracks[1]), isTrue);

      state.togglePairLink(state.tracks[1]); // unlink
      expect(state.isPairLinked(state.tracks[1]), isFalse);
      expect(state.isPairLinked(state.tracks[2]), isFalse); // both sides
      state.updateTrack(state.tracks[1], (t) => t.gainDb = -9);
      expect(state.tracks[2].gainDb, 0); // no longer follows

      state.togglePairLink(state.tracks[2]); // relink from the R side
      expect(state.isPairLinked(state.tracks[1]), isTrue);
      // Relink copied the tapped side (R, still 0 dB) onto the partner.
      expect(state.tracks[1].gainDb, 0);
    });

    test('isPaired only when the partner exists', () {
      final state = _stateWithPair();
      expect(state.isPaired(state.tracks[0]), isFalse);
      expect(state.isPaired(state.tracks[1]), isTrue);
    });
  });

  group('A/B snapshots', () {
    test('store, edit, recall restores tracks and targets', () {
      final state = _stateWithPair();
      state.customLufs = -17.5;
      state.setLoudness(LoudnessChoice.lufsCustom);
      state.recallOrStoreSnapshot('A'); // empty slot → stores
      expect(state.hasSnapshot('A'), isTrue);

      state.updateTrack(state.tracks[0], (t) => t.gainDb = -12);
      state.setLoudness(LoudnessChoice.lufs14);
      state.recallOrStoreSnapshot('A'); // recalls
      expect(state.tracks[0].gainDb, 0);
      expect(state.loudness, LoudnessChoice.lufsCustom);
      expect(state.customLufs, -17.5);
    });

    test('storeSnapshot overwrites unconditionally', () {
      final state = _stateWithPair();
      state.recallOrStoreSnapshot('A');
      state.updateTrack(state.tracks[0], (t) => t.gainDb = -9);
      state.storeSnapshot('A');
      state.updateTrack(state.tracks[0], (t) => t.gainDb = 0);
      state.recallOrStoreSnapshot('A');
      expect(state.tracks[0].gainDb, -9);
    });
  });

  group('batch queue', () {
    test('addBatchJob copies the current app-bar selection', () {
      final state = _stateWithPair();
      state.customLufs = -18.0;
      state.setLoudness(LoudnessChoice.lufsCustom);
      state.setFormat(rust.ApiFormat.mp3);
      state.exporter.addBatchJob();
      final job = state.exporter.batchQueue.single;
      expect(job.loudness, LoudnessChoice.lufsCustom);
      expect(job.customLufs, -18.0);
      expect(job.format, rust.ApiFormat.mp3);

      state.exporter.removeBatchJob(job);
      expect(state.exporter.batchQueue, isEmpty);
      expect(state.exporter.batchRunning, isFalse);
    });
  });

  group('suggestedExportName', () {
    final stamp = DateTime(2026, 7, 19, 14, 30, 5);

    test('pattern: take, target, bpm, timestamp, extension', () {
      expect(
        suggestedExportName(
          baseName: 'UFX33_00_DuesPaid.WAV',
          loudness: LoudnessChoice.peakMinus1,
          customLufs: -17,
          format: rust.ApiFormat.wav24,
          bpm: 161,
          now: stamp,
        ),
        'UFX33_00_DuesPaid_1dBFS_161BPM_20260719_143005.wav',
      );
    });

    test('custom LUFS keeps a decimal, integral values drop it', () {
      String name(double lufs) => suggestedExportName(
            baseName: 'Take.wav',
            loudness: LoudnessChoice.lufsCustom,
            customLufs: lufs,
            format: rust.ApiFormat.flac24,
            now: stamp,
          );
      expect(name(-17.5), 'Take_17.5LUFS_20260719_143005.flac');
      expect(name(-17.0), 'Take_17LUFS_20260719_143005.flac');
    });

    test('targets and extensions per choice/format, no BPM part', () {
      expect(
        suggestedExportName(
          baseName: 'Take.wav',
          loudness: LoudnessChoice.none,
          customLufs: -17,
          format: rust.ApiFormat.mp3,
          now: stamp,
        ),
        'Take_raw_20260719_143005.mp3',
      );
      expect(
        suggestedExportName(
          baseName: 'Take.wav',
          loudness: LoudnessChoice.lufs23,
          customLufs: -17,
          format: rust.ApiFormat.wav16,
          now: stamp,
        ),
        'Take_23LUFS_20260719_143005.wav',
      );
    });
  });

  group('masterFor', () {
    test('maps loudness choices and trim/fades into the DTO', () {
      final state = _stateWithPair();
      final m14 = state.masterFor(
          loudness: LoudnessChoice.lufs14,
          customLufs: -17,
          format: rust.ApiFormat.wav24);
      expect(m14.loudness.mode, rust.ApiLoudnessMode.lufsIntegrated);
      expect(m14.loudness.value, -14);
      expect(m14.fadeInMs, 0); // untrimmed → no fades
      expect(m14.fadeOutMs, 0);
      expect(m14.trimStartFrame, BigInt.zero);
      expect(m14.trimEndFrame, isNull);

      // Without a recording durationSeconds is 0 — the trim clamps to it,
      // but a set trim point still switches the fades on.
      state.trimStartSeconds = 1.0;
      state.trimEndSeconds = 2.0;
      final trimmed = state.masterFor(
          loudness: LoudnessChoice.none,
          customLufs: -17,
          format: rust.ApiFormat.wav24);
      expect(trimmed.loudness.mode, rust.ApiLoudnessMode.none);
      expect(trimmed.fadeInMs, MixerState.fadeMs);
      expect(trimmed.fadeOutMs, MixerState.fadeMs);
      expect(trimmed.trimStartFrame, BigInt.from(48000));
      expect(trimmed.trimEndFrame, BigInt.from(96000));
    });
  });
}
