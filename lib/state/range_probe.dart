import 'dart:typed_data';

import '../src/rust/api/mixer.dart' as rust;

/// Reads `[start, end)` of a recording. The web build slices a `Blob`
/// (lazy, so a multi-GB take never enters memory); native callers can wrap
/// any random-access source.
typedef RangeReader = Future<Uint8List> Function(int start, int end);

/// Probe result plus the track names, which only exist when the take
/// carries iXML.
class RangeProbe {
  const RangeProbe({required this.probe, required this.trackNames});

  final rust.ApiProbe probe;
  final List<String> trackNames;
}

/// Window size per scan step. Chunk headers are 8 bytes and real takes have
/// a handful of chunks, so one window per cluster is plenty — the point is
/// to never read the audio payload.
const _scanWindow = 64 * 1024;

/// How much of the `data` payload travels per bridge call during analysis.
/// Big enough that 400 MB needs ~100 calls rather than thousands, small
/// enough that the copy into wasm memory stays bounded.
const _analysisBlock = 4 * 1024 * 1024;

/// Locate the RIFF chunks using [read] alone.
///
/// Rust parses (`scanWavChunks`); this only fetches the windows it asks
/// for. **Seeking is mandatory, not an optimisation:** real DUREC takes
/// store iXML — the track names — *behind* the multi-GB audio payload, so a
/// prefix-only reader would always report zero tracks (docs/PLAN-PWA.md).
Future<List<rust.ApiChunk>> scanChunksByRanges(
  RangeReader read,
  int fileSize,
) async {
  final chunks = <rust.ApiChunk>[];
  var offset = 0;
  while (true) {
    final end = (offset + _scanWindow).clamp(0, fileSize);
    if (end <= offset) break;
    final scan = rust.scanWavChunks(
      buf: await read(offset, end),
      bufOffset: BigInt.from(offset),
      fileSize: BigInt.from(fileSize),
    );
    chunks.addAll(scan.chunks);
    final next = scan.nextOffset;
    if (next == null) break;
    offset = next.toInt();
  }
  return chunks;
}

rust.ApiChunk? _find(List<rust.ApiChunk> chunks, String id) {
  for (final c in chunks) {
    if (c.id == id) return c;
  }
  return null;
}

Future<Uint8List> _payload(RangeReader read, rust.ApiChunk c) {
  final start = c.offset.toInt();
  return read(start, start + c.size.toInt());
}

/// Probes a recording through [read] alone, without a filesystem.
Future<RangeProbe> probeByRanges(RangeReader read, int fileSize) async {
  final chunks = await scanChunksByRanges(read, fileSize);
  final fmt = _find(chunks, 'fmt ');
  final data = _find(chunks, 'data');
  if (fmt == null) throw const FormatException('WAV without a fmt chunk');
  if (data == null) throw const FormatException('WAV without a data chunk');
  final ixmlChunk = _find(chunks, 'iXML');
  final ixml = ixmlChunk == null ? null : await _payload(read, ixmlChunk);

  return RangeProbe(
    probe: rust.probeFromChunks(
      fmtChunk: await _payload(read, fmt),
      ixmlChunk: ixml,
      dataBytes: data.size,
    ),
    trackNames: ixml == null
        ? const []
        : rust.trackNamesFromIxml(ixmlChunk: ixml),
  );
}

/// Waveform + BPM analysis through [read] alone.
///
/// Unlike [probeByRanges] this genuinely streams the audio: the `data`
/// payload is pushed to Rust in [_analysisBlock] slices, so peak memory
/// stays at one block no matter how long the take is. [onProgress] reports
/// 0..1 for the UI.
Future<rust.ApiAnalysis> analyzeByRanges(
  RangeReader read,
  int fileSize, {
  required int buckets,
  void Function(double progress)? onProgress,
}) async {
  final chunks = await scanChunksByRanges(read, fileSize);
  final fmt = _find(chunks, 'fmt ');
  final data = _find(chunks, 'data');
  if (fmt == null) throw const FormatException('WAV without a fmt chunk');
  if (data == null) throw const FormatException('WAV without a data chunk');

  final id = await rust.streamAnalysisBegin(
    fmtChunk: await _payload(read, fmt),
    dataBytes: data.size,
    buckets: BigInt.from(buckets),
  );
  try {
    final start = data.offset.toInt();
    final end = start + data.size.toInt();
    for (var at = start; at < end; at += _analysisBlock) {
      final stop = (at + _analysisBlock).clamp(at, end);
      await rust.streamAnalysisPush(id: id, bytes: await read(at, stop));
      onProgress?.call((stop - start) / (end - start));
    }
    return await rust.streamAnalysisFinish(id: id);
  } catch (_) {
    await rust.streamAnalysisCancel(id: id);
    rethrow;
  }
}
