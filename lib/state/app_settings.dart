import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode, ValueNotifier;
import 'package:path_provider/path_provider.dart';

/// Tiny persisted app settings at `<Application Support>/settings.json` —
/// the same path_provider pattern as session files, no extra dependency.
class AppSettings {
  AppSettings._(this._file, Map<String, dynamic> data)
    : lastFolder = data['lastFolder'] as String?,
      sortByDate = data['sortByDate'] as bool? ?? false {
    themeMode.value = _parseThemeMode(data['themeMode'] as String?);
  }

  static AppSettings? _instance;

  final File _file;

  /// Last browsed folder: a filesystem path, or a SAF tree URI on Android.
  String? lastFolder;

  /// Browser sort order: false = name A→Z, true = newest first.
  bool sortByDate;

  /// Live theme selection: the app listens, the settings dialog writes.
  ///
  /// Static and eagerly initialised because the widget tree is built
  /// synchronously (`DurecMixApp` takes no settings argument) while [load]
  /// is async — the app starts on the system default and [load] applies the
  /// stored choice before the first frame in `main`.
  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier(
    ThemeMode.system,
  );

  static ThemeMode _parseThemeMode(String? name) {
    for (final mode in ThemeMode.values) {
      if (mode.name == name) return mode;
    }
    return ThemeMode.system;
  }

  /// Apply and persist a theme choice. Applies immediately even if the
  /// write fails — this is a preference, not a transaction.
  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await save();
  }

  static Future<AppSettings> load() async {
    if (_instance != null) return _instance!;
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}/settings.json');
    Map<String, dynamic> data = const {};
    try {
      data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // Missing or corrupt settings file: start fresh.
    }
    return _instance = AppSettings._(file, data);
  }

  Future<void> save() async {
    try {
      await _file.writeAsString(
        jsonEncode({
          'lastFolder': lastFolder,
          'sortByDate': sortByDate,
          'themeMode': themeMode.value.name,
        }),
      );
    } catch (_) {
      // Settings are a convenience; never surface write failures.
    }
  }
}
