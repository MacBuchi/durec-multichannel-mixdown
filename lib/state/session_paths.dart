import '../io/platform_shim.dart';

/// Where session files live.
///
/// Sandboxed platforms (macOS App Sandbox, Android SAF) forbid writing next
/// to the source WAV, so sessions are stored in the app's own container:
/// `<Application Support>/sessions/<basename>_<hash>.durecmix.json`.
/// The basename keeps the files human-readable; the FNV-1a hash of the full
/// path keeps recordings with identical names apart. Legacy sibling files
/// next to the WAV are still read once by the engine as a migration fallback.
Future<String> sessionPathFor(String wavSource, {String? displayName}) async {
  final support = await applicationSupportPath();
  final dir = '$support/sessions';
  await ensureDirectory(dir);
  // Content URIs (Android SAF) have no meaningful basename — use the
  // provider-reported display name for readability instead.
  final base = (displayName ?? wavSource.split('/').last)
      .replaceAll(RegExp(r'\.wav$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final path = '$dir/${base}_${sourceHashFor(wavSource)}.durecmix.json';
  // One-time migration: sessions saved before the documentId normalization
  // hashed the full URI string. Rename them onto the stable key so a mix
  // saved via the single-file picker survives opening the same file from
  // the folder browser.
  final legacy = '$dir/${base}_${_fnv1a64(wavSource)}.durecmix.json';
  if (legacy != path && !fileExistsSync(path) && fileExistsSync(legacy)) {
    try {
      renameFileSync(legacy, path);
    } catch (_) {
      // Migration is best effort: if the rename fails the legacy session is
      // simply not carried over and the user starts from a fresh mix.
    }
  }
  return path;
}

/// The saved mix at [sessionPath], or null when there is none.
///
/// Only the byte-range paths need this: the engine reads sessions itself when
/// it opens a file, but it does that with `std::fs`, which wasm has none of —
/// so in the browser Dart fetches the JSON from the app container and hands it
/// to `loadRecordingFromChunks`. Same file, same name, same contents as
/// natively; since v0.14.0 the container persists, so this survives a reload.
Future<String?> storedSessionJson(String? sessionPath) async {
  if (sessionPath == null || !fileExistsSync(sessionPath)) return null;
  try {
    return await readTextFile(sessionPath);
  } catch (_) {
    // A half-written or unreadable session must not stop a take from opening
    // (or a batch render from starting) — it falls back to the unity mix.
    return null;
  }
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
///
/// Computed on two 32-bit halves because dart2js has no 64-bit integers
/// (the previous `0xcbf29ce484222325` literal did not even compile for the
/// web). Every intermediate stays below 2^42, exact in doubles, so VM and
/// dart2js produce bit-identical hashes — existing session and cache
/// filenames depend on that (vectors: test/session_paths_test.dart).
String _fnv1a64(String s) {
  // Offset basis 0xcbf29ce4_84222325; prime 0x100_000001b3.
  var hi = 0xcbf29ce4;
  var lo = 0x84222325;
  const primeHi = 0x100;
  const primeLo = 0x1b3;
  const limb = 0x100000000;
  for (final unit in s.codeUnits) {
    lo ^= unit;
    final low = lo * primeLo;
    hi = (lo * primeHi + hi * primeLo + low ~/ limb) % limb;
    lo = low % limb;
  }
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
