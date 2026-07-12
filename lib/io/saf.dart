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
}
