import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where session files live.
///
/// Sandboxed platforms (macOS App Sandbox, Android SAF) forbid writing next
/// to the source WAV, so sessions are stored in the app's own container:
/// `<Application Support>/sessions/<basename>_<hash>.durecmix.json`.
/// The basename keeps the files human-readable; the FNV-1a hash of the full
/// path keeps recordings with identical names apart. Legacy sibling files
/// next to the WAV are still read once by the engine as a migration fallback.
Future<String> sessionPathFor(String wavSource, {String? displayName}) async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory('${support.path}/sessions');
  await dir.create(recursive: true);
  // Content URIs (Android SAF) have no meaningful basename — use the
  // provider-reported display name for readability instead.
  final base = (displayName ?? wavSource.split('/').last)
      .replaceAll(RegExp(r'\.wav$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '${dir.path}/${base}_${_fnv1a64(wavSource)}.durecmix.json';
}

/// FNV-1a 64-bit hash, hex-encoded. Stable across runs and platforms.
/// (Dart ints are signed 64-bit with wrapping arithmetic, hence the
/// unsigned-shift split for hex formatting.)
String _fnv1a64(String s) {
  var hash = 0xcbf29ce484222325;
  for (final unit in s.codeUnits) {
    hash ^= unit;
    hash *= 0x100000001b3;
  }
  return (hash >>> 32).toRadixString(16).padLeft(8, '0') +
      (hash & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
