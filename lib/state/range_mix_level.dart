import '../src/rust/api/mixer.dart' as rust;
import 'range_probe.dart';

/// Same block size as the render's byte-range pass — few enough bridge calls
/// to keep the overhead invisible, small enough that the copy into wasm
/// memory stays bounded.
const _scanBlock = 4 * 1024 * 1024;

/// Measure the mix's level through [read] alone, without a filesystem.
///
/// The browser twin of `analyzeMixLevel`: one pass over the trimmed range,
/// pushed block by block because a `Blob` has no synchronous seek. Behind it
/// sits the same engine stage the file-based scan uses, so the measurement —
/// and with it the preview's gain — cannot differ between the two.
Future<rust.ApiMixLevel> measureMixLevelByRanges(
  RangeReader read,
  int fileSize, {
  required List<rust.ApiTrack> tracks,
  required rust.ApiMaster master,
  void Function(double progress)? onProgress,
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

  // Trim by choosing which bytes to read at all, exactly as the render does.
  final firstFrame = master.trimStartFrame.toInt().clamp(0, totalFrames);
  final lastFrame = (master.trimEndFrame?.toInt() ?? totalFrames).clamp(
    firstFrame,
    totalFrames,
  );
  final start = data.offset.toInt() + firstFrame * bytesPerFrame;
  final end = data.offset.toInt() + lastFrame * bytesPerFrame;

  final id = await rust.mixLevelBegin(
    fmtChunk: fmtChunk,
    rangeFrames: BigInt.from(lastFrame - firstFrame),
    tracks: tracks,
    master: master,
  );
  try {
    final span = end - start > 0 ? end - start : 1;
    for (var at = start; at < end; at += _scanBlock) {
      final stop = (at + _scanBlock).clamp(at, end);
      await rust.mixLevelPush(id: id, bytes: await read(at, stop));
      onProgress?.call((stop - start) / span);
    }
    return await rust.mixLevelFinish(id: id);
  } catch (_) {
    // The scan holds engine state until it is finished or dropped; a throw
    // between begin and finish would leak it for the tab's lifetime.
    await rust.mixLevelCancel(id: id);
    rethrow;
  }
}
