import '../io/platform_shim.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'range_probe.dart';

/// How much of the `data` payload travels per bridge call while rendering.
/// Same reasoning as [analyzeByRanges]: few enough calls to keep the overhead
/// invisible, small enough that the copy into wasm memory stays bounded.
const _renderBlock = 4 * 1024 * 1024;

/// Thrown by [renderByRanges] when [RenderByRangesCancel] asked it to stop.
///
/// Its own type so callers can tell "the user pressed cancel" apart from a
/// failure — one is a finished job, the other is an error to show.
class RenderCancelled implements Exception {
  const RenderCancelled();

  @override
  String toString() => 'render cancelled';
}

/// Asked once per block; return true to abort the render.
typedef RenderByRangesCancel = bool Function();

/// Render the mix through [read] alone, without a filesystem.
///
/// Two passes over the source — the first measures peak and loudness, the
/// second encodes — and no seek in between, because a `Blob` has none: the
/// same byte range is simply read twice. Reading is cheap enough for that
/// (see `platform_shim_web._lazyRecording`); the audio never lands in memory
/// as a whole.
///
/// [cancelled] is polled once per block. A block is the granularity that
/// exists: the engine call for one block cannot be interrupted from the
/// outside, and at 4 MB it returns fast enough to feel immediate.
Future<rust.ApiRenderReport> renderByRanges(
  RangeReader read,
  int fileSize, {
  required List<rust.ApiTrack> tracks,
  required rust.ApiMaster master,
  required RenderOutput output,
  rust.ApiReferenceProfile? reference,
  void Function(double progress)? onProgress,
  RenderByRangesCancel? cancelled,
}) async {
  final chunks = await scanChunksByRanges(read, fileSize);
  final fmt = chunks.where((c) => c.id == 'fmt ').firstOrNull;
  final data = chunks.where((c) => c.id == 'data').firstOrNull;
  if (fmt == null) throw const FormatException('WAV without a fmt chunk');
  if (data == null) throw const FormatException('WAV without a data chunk');
  final fmtChunk = await read(
    fmt.offset.toInt(),
    fmt.offset.toInt() + fmt.size.toInt(),
  );

  final probe = rust.probeFromChunks(
    fmtChunk: fmtChunk,
    ixmlChunk: null,
    dataBytes: data.size,
  );
  final bytesPerFrame = probe.channels * (probe.bitsPerSample ~/ 8);
  final totalFrames = data.size.toInt() ~/ bytesPerFrame;

  // Trim is applied here, by choosing which bytes to read at all — the engine
  // stages render exactly what they are given.
  final firstFrame = master.trimStartFrame.toInt().clamp(0, totalFrames);
  final lastFrame = (master.trimEndFrame?.toInt() ?? totalFrames).clamp(
    firstFrame,
    totalFrames,
  );
  final start = data.offset.toInt() + firstFrame * bytesPerFrame;
  final end = data.offset.toInt() + lastFrame * bytesPerFrame;

  final id = await rust.renderStreamBegin(
    fmtChunk: fmtChunk,
    rangeFrames: BigInt.from(lastFrame - firstFrame),
    tracks: tracks,
    master: master,
    reference: reference,
  );
  try {
    // Plain max, not `clamp(1, 1 << 62)`: dart2js has no 64-bit shifts, so
    // that upper bound collapses to 0 and clamp throws "Invalid argument: 1".
    final span = end - start > 0 ? end - start : 1;
    for (var at = start; at < end; at += _renderBlock) {
      if (cancelled?.call() ?? false) throw const RenderCancelled();
      final stop = (at + _renderBlock).clamp(at, end);
      await rust.renderStreamPass1Push(id: id, bytes: await read(at, stop));
      onProgress?.call((stop - start) / span * 0.5);
    }
    await rust.renderStreamStartPass2(id: id);
    for (var at = start; at < end; at += _renderBlock) {
      if (cancelled?.call() ?? false) throw const RenderCancelled();
      final stop = (at + _renderBlock).clamp(at, end);
      output.addBody(
        await rust.renderStreamPass2Push(id: id, bytes: await read(at, stop)),
      );
      onProgress?.call(0.5 + (stop - start) / span * 0.5);
    }
    final tail = await rust.renderStreamFinish(id: id);
    await output.complete(tail.head, tail.tail);
    onProgress?.call(1);
    return tail.report;
  } catch (_) {
    await rust.renderStreamCancel(id: id);
    rethrow;
  }
}
