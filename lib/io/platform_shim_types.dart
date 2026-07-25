/// Types shared by both platform shim implementations
/// (`platform_shim_io.dart` / `platform_shim_web.dart`).
library;

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
