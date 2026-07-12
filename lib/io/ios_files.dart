import 'dart:io';

import 'package:flutter/services.dart';

/// iOS Files-app bridge, the counterpart of the Android [Saf] class: DUREC
/// recordings are multi-GB, so they are opened in place (`asCopy: false`)
/// under a security scope the native side holds for the whole session — the
/// Rust engine reopens the file by path on every call. Exports render into
/// tmp first and are then moved to the user's chosen location.
class IosFiles {
  static const _channel = MethodChannel('durecmix/files');

  static bool get isAvailable => Platform.isIOS;

  /// Open the Files picker for a WAV; returns its in-place path or null.
  static Future<String?> pickWav() => _channel.invokeMethod<String>('pickWav');

  /// Move a finished render out of tmp via the export picker.
  /// Returns the destination path, or null if the user cancelled.
  static Future<String?> exportMove(String tempPath) =>
      _channel.invokeMethod<String>('exportMove', {'path': tempPath});

  /// Ask iOS for extra background runtime while a render finishes
  /// (~30 s–minutes at the system's discretion). Returns a task id.
  static Future<int?> beginBackgroundTask() =>
      _channel.invokeMethod<int>('beginBackgroundTask');

  static Future<void> endBackgroundTask(int id) =>
      _channel.invokeMethod('endBackgroundTask', {'id': id});
}
