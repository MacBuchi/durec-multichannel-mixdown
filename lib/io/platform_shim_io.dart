/// Native implementation of the platform shim — the only place in `lib/`
/// allowed to import `dart:io`, `path_provider` and `ota_update`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ota_update/ota_update.dart';
import 'package:path_provider/path_provider.dart';

import 'platform_shim_types.dart';

bool get isAndroidPlatform => Platform.isAndroid;
bool get isIOSPlatform => Platform.isIOS;
bool get isMacOSPlatform => Platform.isMacOS;
bool get isWindowsPlatform => Platform.isWindows;
String get operatingSystemName => Platform.operatingSystem;
String get pathSeparator => Platform.pathSeparator;

Future<String> applicationSupportPath() async =>
    (await getApplicationSupportDirectory()).path;

Future<String> systemTempPath() async => Directory.systemTemp.path;

Future<void> ensureDirectory(String path) async {
  await Directory(path).create(recursive: true);
}

bool fileExistsSync(String path) => File(path).existsSync();

void renameFileSync(String from, String to) => File(from).renameSync(to);

void deleteFileSync(String path) => File(path).deleteSync();

Future<String> readTextFile(String path) => File(path).readAsString();

Future<void> writeTextFile(String path, String contents) async {
  await File(path).writeAsString(contents);
}

Future<Uint8List> readBinaryFile(String path) => File(path).readAsBytes();

Future<void> writeBinaryFile(String path, Uint8List bytes) async {
  await File(path).writeAsBytes(bytes);
}

/// `.wav` files (by extension, case-insensitive) directly in [dirPath].
Future<List<WavFileInfo>> listWavFiles(String dirPath) async {
  final out = <WavFileInfo>[];
  await for (final f in Directory(dirPath).list()) {
    if (f is! File || !f.path.toLowerCase().endsWith('.wav')) continue;
    final stat = await f.stat();
    out.add(
      WavFileInfo(path: f.path, sizeBytes: stat.size, modified: stat.modified),
    );
  }
  return out;
}

Future<HttpTextResponse> httpGetText(
  Uri url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(url);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    final body = await response.transform(const Utf8Decoder()).join();
    return HttpTextResponse(statusCode: response.statusCode, body: body);
  } finally {
    client.close();
  }
}

Future<HttpTextResponse> httpPostJson(
  Uri url, {
  Map<String, String> headers = const {},
  required String body,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.postUrl(url);
    headers.forEach(request.headers.set);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close().timeout(timeout);
    final responseBody = await response.transform(const Utf8Decoder()).join();
    return HttpTextResponse(
      statusCode: response.statusCode,
      body: responseBody,
    );
  } finally {
    client.close();
  }
}

/// Native platforms have real folder pickers (SAF tree on Android, a path
/// dialog elsewhere), so the browser page keeps its folder flow.
const canPickFolders = true;

/// Only used where [canPickFolders] is false (web); native builds browse
/// folders instead of picking individual files.
Future<List<PickedRecording>> pickRecordings() async => const [];

/// Live playback runs through cpal, which every native target has.
const canPlayAudio = true;

/// Rendering writes the mixdown with `std::fs`, available on all native
/// targets.
const canExportAudio = true;

/// LAME is compiled in on every native target (Cargo feature `mp3`).
const canEncodeMp3 = true;

/// Native builds render straight to the chosen file, so the streamed
/// download path is never taken here.
RenderOutput createDownloadOutput(String filename) =>
    throw UnsupportedError('native builds export to a file, not a download');

/// Download and install an APK in-app (Android only; ota_update plugin).
Stream<ApkInstallEvent> installApk(String apkUrl, String filename) {
  return OtaUpdate().execute(apkUrl, destinationFilename: filename).map((
    event,
  ) {
    switch (event.status) {
      case OtaStatus.DOWNLOADING:
        return ApkInstallEvent(
          ApkInstallPhase.downloading,
          progress: (double.tryParse(event.value ?? '') ?? 0) / 100,
        );
      case OtaStatus.INSTALLING:
        return const ApkInstallEvent(ApkInstallPhase.installing);
      default:
        return const ApkInstallEvent(ApkInstallPhase.error);
    }
  });
}

/// Native builds play through cpal inside the engine, so there is no sink to
/// hand out here.
Future<PreviewSink?> openPreviewSink(int sampleRate) async => null;
