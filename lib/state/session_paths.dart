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
  final path = '${dir.path}/${base}_${sourceHashFor(wavSource)}.durecmix.json';
  // One-time migration: sessions saved before the documentId normalization
  // hashed the full URI string. Rename them onto the stable key so a mix
  // saved via the single-file picker survives opening the same file from
  // the folder browser.
  final legacy = '${dir.path}/${base}_${_fnv1a64(wavSource)}.durecmix.json';
  if (legacy != path && !File(path).existsSync() && File(legacy).existsSync()) {
    try {
      File(legacy).renameSync(path);
    } catch (_) {
      // Migration is best effort: if the rename fails the legacy session is
      // simply not carried over and the user starts from a fresh mix.
    }
  }
  return path;
}

/// Stable identity of a source. Android SAF exposes the SAME file under
/// different URI strings — `…/document/<id>` from the single-file picker vs
/// `…/tree/<t>/document/<id>` from a folder tree — but the documentId is
/// identical, so content URIs are reduced to it before hashing. Everything
/// else (filesystem paths) keeps its full string. Shared by session files
/// and the analysis cache so both survive picker↔browser switches.
String sourceKeyFor(String wavSource) {
  if (!wavSource.startsWith('content://')) return wavSource;
  const marker = '/document/';
  final i = wavSource.lastIndexOf(marker);
  if (i < 0) return wavSource;
  return Uri.decodeComponent(wavSource.substring(i + marker.length));
}

/// FNV-1a hash of the stable source key, hex — filename-safe cache/session
/// discriminator.
String sourceHashFor(String wavSource) => _fnv1a64(sourceKeyFor(wavSource));

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
