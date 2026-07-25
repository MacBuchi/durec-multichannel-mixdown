/// Web implementation of the platform shim (docs/PLAN-PWA.md, S1).
///
/// The app container is an in-memory map — settings, sessions and caches
/// live for the tab's lifetime. Persistent web storage (OPFS/localStorage)
/// and fetch-based networking are later PWA stages; everything here is
/// deliberately the smallest thing that lets the app boot.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
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
/// its files from [pickRecordings] instead.
Future<List<WavFileInfo>> listWavFiles(String dirPath) async {
  debugPrint('listWavFiles($dirPath) is a no-op on the web');
  return const [];
}

/// True where folder picking is unavailable and the UI must offer a file
/// picker instead. `file_selector_web.getDirectoryPath()` returns null
/// unconditionally — tapping "Choose folder" would be a silent dead end.
const canPickFolders = false;

/// The `playback` Cargo feature (cpal) is off for wasm — `player_start`
/// bails out. Without this flag the transport button surfaces the raw
/// `AnyhowException(...)` in the mixer header (PLAN-PWA S4).
const canPlayAudio = false;

/// Rendering writes with `std::fs`, which has no browser equivalent yet, and
/// `getSaveLocation()` throws on web — an unguarded Export tap dies in an
/// unhandled exception and shows the user nothing at all (PLAN-PWA S3).
const canExportAudio = false;

/// Opens the browser file picker and wraps each pick in lazy range access.
///
/// `XFile.openRead(start, end)` slices the underlying `Blob`, so a 400 MB
/// take is never loaded — only the chunk headers and the iXML payload are
/// actually fetched.
Future<List<PickedRecording>> pickRecordings() async {
  const group = XTypeGroup(label: 'WAV', extensions: ['wav'], mimeTypes: []);
  final files = await openFiles(acceptedTypeGroups: const [group]);
  return [
    for (final f in files)
      PickedRecording(
        // Blobs have no path; the name keeps session keys readable and
        // stable enough for one browser session.
        source: 'blob:${f.name}',
        name: f.name,
        sizeBytes: await f.length(),
        // BytesBuilder, not a List<int>: Dart boxes a growable int list at
        // 8 bytes per element, so accumulating a 4 MB block that way costs
        // ~32 MB and shows up directly as JS heap growth.
        read: (start, end) async {
          final builder = BytesBuilder(copy: false);
          await for (final part in f.openRead(start, end)) {
            builder.add(part);
          }
          return builder.takeBytes();
        },
      ),
  ];
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
