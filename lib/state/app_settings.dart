import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Tiny persisted app settings at `<Application Support>/settings.json` —
/// the same path_provider pattern as session files, no extra dependency.
class AppSettings {
  AppSettings._(this._file, Map<String, dynamic> data)
      : lastFolder = data['lastFolder'] as String?,
        sortByDate = data['sortByDate'] as bool? ?? false;

  static AppSettings? _instance;

  final File _file;

  /// Last browsed folder: a filesystem path, or a SAF tree URI on Android.
  String? lastFolder;

  /// Browser sort order: false = name A→Z, true = newest first.
  bool sortByDate;

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
      await _file.writeAsString(jsonEncode({
        'lastFolder': lastFolder,
        'sortByDate': sortByDate,
      }));
    } catch (_) {
      // Settings are a convenience; never surface write failures.
    }
  }
}
