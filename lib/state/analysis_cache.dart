import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../src/rust/api/mixer.dart' as rust;
import 'session_paths.dart';

/// Waveform/BPM cache: the analysis pass reads the ENTIRE recording (slow
/// over USB-OTG), but its result is tiny (~163 KB for 34 ch × 600 buckets).
/// Caching it makes the second visit to a take instant — the core
/// take-switching workflow stops paying the full-scan tax every time.
///
/// Keyed by the stable source identity plus the frame count, so re-recorded
/// files with the same name invalidate naturally. Binary layout (LE):
/// magic 'DXAN' · u32 version · f64 bpm (NaN = none) · u32 channels ·
/// u32 buckets · per channel: f64 peakDbfs, buckets×f32 min, buckets×f32 max.
class AnalysisCache {
  static const _magic = 0x4458414E; // 'DXAN'
  static const _version = 1;

  static Future<File> _fileFor(
      String source, BigInt numFrames, int buckets) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/analysis');
    await dir.create(recursive: true);
    return File(
        '${dir.path}/${sourceHashFor(source)}_${numFrames}_$buckets.bin');
  }

  static Future<rust.ApiAnalysis?> load(
      String source, BigInt numFrames, int buckets) async {
    try {
      final file = await _fileFor(source, numFrames, buckets);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final data = ByteData.sublistView(bytes);
      var o = 0;
      if (data.getUint32(o, Endian.little) != _magic) return null;
      o += 4;
      if (data.getUint32(o, Endian.little) != _version) return null;
      o += 4;
      final bpm = data.getFloat64(o, Endian.little);
      o += 8;
      final channels = data.getUint32(o, Endian.little);
      o += 4;
      final storedBuckets = data.getUint32(o, Endian.little);
      o += 4;
      if (storedBuckets != buckets) return null;
      final waveforms = <rust.ApiChannelWaveform>[];
      for (var c = 0; c < channels; c++) {
        final peakDbfs = data.getFloat64(o, Endian.little);
        o += 8;
        Float32List read() {
          final list = Float32List(buckets);
          for (var i = 0; i < buckets; i++) {
            list[i] = data.getFloat32(o, Endian.little);
            o += 4;
          }
          return list;
        }

        final min = read();
        final max = read();
        waveforms.add(rust.ApiChannelWaveform(
            min: min, max: max, peakDbfs: peakDbfs));
      }
      return rust.ApiAnalysis(
          waveforms: waveforms, bpm: bpm.isNaN ? null : bpm);
    } catch (_) {
      return null; // any corruption → treat as miss
    }
  }

  static Future<void> save(String source, BigInt numFrames, int buckets,
      rust.ApiAnalysis analysis) async {
    try {
      final channels = analysis.waveforms.length;
      final builder = BytesBuilder();
      final header = ByteData(24)
        ..setUint32(0, _magic, Endian.little)
        ..setUint32(4, _version, Endian.little)
        ..setFloat64(8, analysis.bpm ?? double.nan, Endian.little)
        ..setUint32(16, channels, Endian.little)
        ..setUint32(20, buckets, Endian.little);
      builder.add(header.buffer.asUint8List());
      for (final w in analysis.waveforms) {
        final peak = ByteData(8)..setFloat64(0, w.peakDbfs, Endian.little);
        builder.add(peak.buffer.asUint8List());
        for (final list in [w.min, w.max]) {
          final data = ByteData(buckets * 4);
          for (var i = 0; i < buckets; i++) {
            data.setFloat32(i * 4, i < list.length ? list[i] : 0, Endian.little);
          }
          builder.add(data.buffer.asUint8List());
        }
      }
      final file = await _fileFor(source, numFrames, buckets);
      await file.writeAsBytes(builder.toBytes());
    } catch (_) {
      // Cache writes are best effort — never surface failures.
    }
  }
}
