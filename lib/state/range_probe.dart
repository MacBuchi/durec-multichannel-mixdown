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

/// Probes a recording through [read] alone, without a filesystem.
///
/// Rust locates the chunks (`scanWavChunks`) and parses them
/// (`probeFromChunks`); this function only fetches the byte ranges Rust
/// asks for. **Seeking is mandatory, not an optimisation:** real DUREC
/// takes store iXML — the track names — *behind* the multi-GB audio
/// payload, so a prefix-only reader would always report zero tracks
/// (docs/PLAN-PWA.md S2).
Future<RangeProbe> probeByRanges(RangeReader read, int fileSize) async {
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

  Future<Uint8List>? payload(String id) {
    for (final c in chunks) {
      if (c.id == id) {
        final start = c.offset.toInt();
        return read(start, start + c.size.toInt());
      }
    }
    return null;
  }

  final fmt = await payload('fmt ');
  if (fmt == null) throw const FormatException('WAV without a fmt chunk');
  final data = chunks.where((c) => c.id == 'data');
  if (data.isEmpty) throw const FormatException('WAV without a data chunk');
  final ixml = await payload('iXML');

  return RangeProbe(
    probe: rust.probeFromChunks(
      fmtChunk: fmt,
      ixmlChunk: ixml,
      dataBytes: data.first.size,
    ),
    trackNames: ixml == null
        ? const []
        : rust.trackNamesFromIxml(ixmlChunk: ixml),
  );
}
