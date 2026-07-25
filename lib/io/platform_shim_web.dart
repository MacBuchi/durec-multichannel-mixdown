/// Web implementation of the platform shim (docs/PLAN-PWA.md, S1).
///
/// The app container is an in-memory map — settings, sessions and caches
/// live for the tab's lifetime. Persistent web storage (OPFS/localStorage)
/// and fetch-based networking are later PWA stages; everything here is
/// deliberately the smallest thing that lets the app boot.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'platform_shim_types.dart';

bool get isAndroidPlatform => false;
bool get isIOSPlatform => false;
bool get isMacOSPlatform => false;
bool get isWindowsPlatform => false;
String get operatingSystemName => 'Web';
String get pathSeparator => '/';

/// Tab-lifetime file store; keys are the virtual paths handed out below.
final Map<String, Uint8List> _files = {};

Future<String> applicationSupportPath() async => '/web-app-support';

Future<String> systemTempPath() async => '/web-tmp';

Future<void> ensureDirectory(String path) async {}

bool fileExistsSync(String path) => _files.containsKey(path);

void renameFileSync(String from, String to) {
  final bytes = _files.remove(from);
  if (bytes == null) {
    throw ArgumentError.value(from, 'from', 'no such in-memory file');
  }
  _files[to] = bytes;
}

void deleteFileSync(String path) {
  _files.remove(path);
}

Future<String> readTextFile(String path) async {
  final bytes = _files[path];
  if (bytes == null) {
    throw StateError('no such in-memory file: $path');
  }
  return utf8.decode(bytes);
}

Future<void> writeTextFile(String path, String contents) async {
  _files[path] = Uint8List.fromList(utf8.encode(contents));
}

Future<Uint8List> readBinaryFile(String path) async {
  final bytes = _files[path];
  if (bytes == null) {
    throw StateError('no such in-memory file: $path');
  }
  return bytes;
}

Future<void> writeBinaryFile(String path, Uint8List bytes) async {
  _files[path] = bytes;
}

/// No desktop-style directory listing in the browser; the web build gets
/// its files from pickers (S2). Empty keeps the browser page functional.
Future<List<WavFileInfo>> listWavFiles(String dirPath) async {
  debugPrint('listWavFiles($dirPath) is a no-op on the web');
  return const [];
}

Future<HttpTextResponse> httpGetText(
  Uri url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 10),
}) async {
  throw UnsupportedError('network is not wired up in the web build (S5)');
}

Future<HttpTextResponse> httpPostJson(
  Uri url, {
  Map<String, String> headers = const {},
  required String body,
  Duration timeout = const Duration(seconds: 15),
}) async {
  throw UnsupportedError('network is not wired up in the web build (S5)');
}

Stream<ApkInstallEvent> installApk(String apkUrl, String filename) {
  throw UnsupportedError('APK install does not exist in the web build');
}
