import 'dart:io';

import 'package:flutter/services.dart';

/// Android Storage Access Framework bridge. DUREC recordings are multi-GB,
/// so they are never copied: the picker returns a `content://` URI and the
/// Rust engine reads/writes through raw file descriptors — one fresh fd per
/// engine call (each call opens, seeks and closes independently).
class Saf {
  static const _channel = MethodChannel('durecmix/saf');

  static bool get isAvailable => Platform.isAndroid;

  static bool isContentUri(String source) => source.startsWith('content://');

  /// Open the system picker for a WAV; returns a content URI or null.
  static Future<String?> pickWav() => _channel.invokeMethod<String>('pickWav');

  /// Pick any audio file (mastering reference: MP3/FLAC/WAV/OGG); persists
  /// a read grant like [pickWav].
  static Future<String?> pickAudio() =>
      _channel.invokeMethod<String>('pickAudio');

  /// Open the system save dialog; returns a content URI or null.
  static Future<String?> createDocument(String name, String mime) =>
      _channel.invokeMethod<String>(
          'createDocument', {'name': name, 'mime': mime});

  /// A fresh raw fd for the URI. Ownership passes to the engine.
  /// Mode 'r' for reading, 'rwt' for writing (truncate).
  static Future<int?> openFd(String uri, {String mode = 'r'}) =>
      _channel.invokeMethod<int>('openFd', {'uri': uri, 'mode': mode});

  static Future<String?> displayName(String uri) =>
      _channel.invokeMethod<String>('displayName', {'uri': uri});

  // ── folder access (in-app WAV browser) ───────────────────────────────────

  /// Pick a folder via ACTION_OPEN_DOCUMENT_TREE; the grant persists across
  /// app restarts. Returns the tree URI or null.
  static Future<String?> pickDirectory() =>
      _channel.invokeMethod<String>('pickDirectory');

  /// The tree's direct children that end in .wav:
  /// `{uri, name, size, modified}` maps (modified = epoch millis).
  static Future<List<Map<Object?, Object?>>> listDirectory(String treeUri) async {
    final raw = await _channel
        .invokeListMethod<Map<Object?, Object?>>('listDirectory', {'uri': treeUri});
    return raw ?? const [];
  }

  /// Find or create a subfolder (e.g. `Mixdown`) of the granted tree;
  /// returns its document URI.
  static Future<String> ensureDirectory(String treeUri, String name) async =>
      (await _channel.invokeMethod<String>(
          'ensureDirectory', {'uri': treeUri, 'name': name}))!;

  /// Create a file inside a directory document URI; returns the new file's
  /// document URI (the provider may de-duplicate the name — use the URI).
  static Future<String> createFileInDirectory(
          String dirUri, String name, String mime) async =>
      (await _channel.invokeMethod<String>('createFileInDirectory',
          {'dirUri': dirUri, 'name': name, 'mime': mime}))!;

  /// Hand finished files to the system share sheet (Nextcloud, Drive, …).
  static Future<void> shareFiles(List<String> uris,
          {String mime = 'audio/*'}) =>
      _channel.invokeMethod('shareFiles', {'uris': uris, 'mime': mime});

  // ── export foreground service ─────────────────────────────────────────────
  // Renders take minutes on a phone; the service keeps the process alive
  // when the app is backgrounded and mirrors progress as a notification.

  static Future<void> exportStarted(String name) =>
      _channel.invokeMethod('exportStarted', {'name': name, 'progress': 0});

  static Future<void> exportProgress(String name, int progress) => _channel
      .invokeMethod('exportProgress', {'name': name, 'progress': progress});

  static Future<void> exportStopped() =>
      _channel.invokeMethod('exportStopped');
}
