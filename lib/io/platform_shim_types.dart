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
