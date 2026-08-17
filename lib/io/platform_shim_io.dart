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

/// Nothing to prepare: the app container is a real directory, and the OS has
/// already mounted it by the time the app starts. The web build hydrates its
/// container from browser storage here instead.
Future<void> initPlatformStorage() async {}

/// Null because the question does not arise: a real filesystem always keeps
/// what was written to it, and the UI has nothing to explain.
bool? get browserStoragePersists => null;

/// Native platforms have real folder pickers (SAF tree on Android, a path
/// dialog elsewhere), so the browser page keeps its folder flow.
const canPickFolders = true;

/// Only used where [canPickFolders] is false (web); native builds browse
/// folders instead of picking individual files.
Future<List<PickedRecording>> pickRecordings() async => const [];

/// Web-only: native builds pick a reference by path (SAF, iOS Files or a file
/// dialog) and let the engine read it.
Future<PickedReference?> pickReferenceAudio() async => null;

/// Null on every native target — a reference is read from its path there, so
/// nothing is ever held in memory for it.
Uint8List? referenceBytesFor(String source) => null;

/// Live playback runs through cpal, which every native target has.
const canPlayAudio = true;

/// Rendering writes the mixdown with `std::fs`, available on all native
/// targets.
const canExportAudio = true;

/// LAME is compiled in on every native target (Cargo feature `mp3`).
const canEncodeMp3 = true;

/// Nothing to explain: native builds use the encoder the format name implies.
const String? mp3EncoderNote = null;

/// The reference track is read from a path (or a SAF fd), which every native
/// target provides.
const canMasterToReference = true;

/// Native builds reach the GitHub releases API over HTTP.
const hasNetwork = true;

/// Set by the `play` product flavour (`--dart-define=PLAY_STORE=true`).
///
/// Google Play distributes and updates the app itself, and its Device and
/// Network Abuse policy forbids an app from installing its own updates —
/// `REQUEST_INSTALL_PACKAGES` is reserved for apps whose *core* purpose is
/// installing packages (browsers, file managers, MDM). A downmixer that ships
/// the installer path gets rejected, so the `play` flavour strips the
/// permission from the merged manifest and this flag closes the code paths
/// that would otherwise reach for it.
const isPlayStoreBuild = bool.fromEnvironment('PLAY_STORE');

/// In-app APK download + handover to the system installer. Android only, and
/// never in a Play build — see [isPlayStoreBuild].
bool get canSelfUpdate => isAndroidPlatform && !isPlayStoreBuild;

/// Whether to poll GitHub for a newer release at all. A Play build must not:
/// Play is the update channel there, and a banner pointing at an off-store
/// download is both wrong and policy-adjacent.
const canCheckForUpdates = !isPlayStoreBuild;

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
