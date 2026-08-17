import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode, ValueNotifier;

import '../io/platform_shim.dart';

/// Tiny persisted app settings at `<Application Support>/settings.json` —
/// the same path_provider pattern as session files, no extra dependency.
class AppSettings {
  AppSettings._(this._path, Map<String, dynamic> data)
    : lastFolder = data['lastFolder'] as String?,
      sortByDate = data['sortByDate'] as bool? ?? false {
    themeMode.value = _parseThemeMode(data['themeMode'] as String?);
    trackMeterMode.value = _parseMeterMode(data['trackMeterMode'] as String?);
  }

  static AppSettings? _instance;

  final String _path;

  /// Last browsed folder: a filesystem path, or a SAF tree URI on Android.
  String? lastFolder;

  /// Browser sort order: false = name A→Z, true = newest first.
  bool sortByDate;

  /// Live theme selection: the app listens, the settings dialog writes.
  ///
  /// Static and eagerly initialised because the widget tree is built
  /// synchronously (`MixstackApp` takes no settings argument) while [load]
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

  /// What the per-track meters show (#115). Live like [themeMode], because
  /// every one of the 34 strips listens to it and the mixer must not rebuild
  /// wholesale when it flips.
  static final ValueNotifier<TrackMeterMode> trackMeterMode = ValueNotifier(
    TrackMeterMode.postFader,
  );

  static TrackMeterMode _parseMeterMode(String? name) {
    for (final mode in TrackMeterMode.values) {
      if (mode.name == name) return mode;
    }
    return TrackMeterMode.postFader;
  }

  /// Apply and persist a theme choice. Applies immediately even if the
  /// write fails — this is a preference, not a transaction.
  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await save();
  }

  Future<void> setTrackMeterMode(TrackMeterMode mode) async {
    trackMeterMode.value = mode;
    await save();
  }

  static Future<AppSettings> load() async {
    if (_instance != null) return _instance!;
    final support = await applicationSupportPath();
    final path = '$support/settings.json';
    Map<String, dynamic> data = const {};
    try {
      data = jsonDecode(await readTextFile(path)) as Map<String, dynamic>;
    } catch (_) {
      // Missing or corrupt settings file: start fresh.
    }
    return _instance = AppSettings._(path, data);
  }

  Future<void> save() async {
    try {
      await writeTextFile(
        _path,
        jsonEncode({
          'lastFolder': lastFolder,
          'sortByDate': sortByDate,
          'themeMode': themeMode.value.name,
          'trackMeterMode': trackMeterMode.value.name,
        }),
      );
    } catch (_) {
      // Settings are a convenience; never surface write failures.
    }
  }
}

/// Where the per-track meters tap the signal (#115).
///
/// Both come from one engine measurement: the engine reports the level after
/// the EQ and before the fader, and the post-fader reading is that times the
/// track's gain. Switching therefore costs nothing and takes effect on the
/// next frame.
enum TrackMeterMode {
  /// What arrives on the track — good for finding silent, hot or wrongly
  /// patched channels, and unaffected by how far the fader is down.
  preFader('pre'),

  /// What the track contributes to the mix. The default: it is the question
  /// you are asking while you mix.
  postFader('post');

  const TrackMeterMode(this.label);

  /// Shown on the toggle in the mixer's header.
  final String label;
}
