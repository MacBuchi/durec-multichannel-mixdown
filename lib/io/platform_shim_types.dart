/// Types shared by both platform shim implementations
/// (`platform_shim_io.dart` / `platform_shim_web.dart`).
library;

import 'dart:typed_data';

/// One `.wav` file found by the desktop directory listing.
class WavFileInfo {
  const WavFileInfo({
    required this.path,
    required this.sizeBytes,
    required this.modified,
  });

  final String path;
  final int sizeBytes;
  final DateTime? modified;
}

/// A recording the user picked, with lazy random access to its bytes.
///
/// The web build gets these from `<input type="file">` and reads ranges
/// with `blob.slice()`; native builds keep working from paths, so [source]
/// is the plain path there and [read] is unused (docs/PLAN-PWA.md S2).
class PickedRecording {
  const PickedRecording({
    required this.source,
    required this.name,
    required this.sizeBytes,
    required this.read,
  });

  final String source;
  final String name;
  final int sizeBytes;

  /// Reads `[start, end)` without pulling the whole file into memory.
  final Future<Uint8List> Function(int start, int end) read;
}

/// A mastering reference the user picked in the browser.
///
/// Unlike a recording this travels whole: a reference song is a few megabytes,
/// and the analysis decodes it front to back anyway, so slicing would buy
/// nothing. [source] is a `blob:<name>` pseudo-path — the same shape a picked
/// recording gets, which is what lets the session and the profile cache key on
/// it unchanged (docs/PLAN-PWA.md).
class PickedReference {
  const PickedReference({
    required this.source,
    required this.name,
    required this.bytes,
  });

  final String source;
  final String name;
  final Uint8List bytes;
}

/// Progress of an in-app APK install (Android OTA update).
enum ApkInstallPhase { downloading, installing, error }

class ApkInstallEvent {
  const ApkInstallEvent(this.phase, {this.progress = 0});

  final ApkInstallPhase phase;

  /// Download progress 0..1 (only meaningful while downloading).
  final double progress;
}

/// Minimal HTTP response for the GitHub API calls (update check, feedback).
class HttpTextResponse {
  const HttpTextResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Where the rendered bytes go. The browser cannot write a file, so the
/// caller decides what to do with each block as it arrives.
///
/// Order matters and is **not** the order of production: the encoders patch
/// their header (RIFF sizes, FLAC STREAMINFO) only once the render is
/// complete, so [head] is delivered last but belongs first. The finished file
/// is `head ++ body blocks in order ++ tail`.
abstract class RenderOutput {
  /// One encoded block, in order.
  void addBody(Uint8List bytes);

  /// Called once at the end with the patched header and the encoder's tail.
  Future<void> complete(Uint8List head, Uint8List tail);
}

/// Where preview audio goes on platforms without cpal — the browser.
///
/// The engine mixes ahead of time and hands blocks over; the device pulls
/// from a ring buffer on its own thread. Everything here is counted in
/// **interleaved samples**, not frames, because that is what the ring holds.
abstract class PreviewSink {
  /// Sample rate the device actually runs at.
  int get sampleRate;

  /// Room for this many more samples before the ring is full.
  int get freeSamples;

  /// Samples waiting to be played.
  int get bufferedSamples;

  /// Frames the device has really played — the playhead follows this, not
  /// what was produced, or it would run ahead of what you hear.
  int get playedFrames;

  /// How often the device found the ring empty. Non-zero means the filler
  /// fell behind; silence was played.
  int get underruns;

  /// Append interleaved stereo samples. Never more than [freeSamples].
  void write(Float32List samples);

  /// Drop everything buffered — the signal is about to jump elsewhere.
  void flush();

  /// Keep at most [samples] of what is buffered and drop the rest; returns
  /// how many samples were dropped.
  ///
  /// For re-mixing after a parameter change: everything past the kept tail
  /// was produced with the old settings. The tail stays so the device has
  /// something to play while the replacement is produced.
  int trimTo(int samples);

  Future<void> dispose();
}
