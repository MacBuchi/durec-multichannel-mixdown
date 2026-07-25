/// Web implementation of the platform shim (docs/PLAN-PWA.md, S1).
///
/// The app container is an in-memory map — settings, sessions and caches
/// live for the tab's lifetime. Persistent web storage (OPFS/localStorage)
/// and fetch-based networking are later PWA stages; everything here is
/// deliberately the smallest thing that lets the app boot.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

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

/// The browser plays through an `AudioWorklet` fed by the engine
/// (`WebPlayback`), not through cpal — the `playback` Cargo feature stays off
/// for wasm (PLAN-PWA S4).
const canPlayAudio = true;

/// Export goes through [BlobRenderOutput] instead of a save dialog — the
/// engine streams the encoded blocks and the browser offers the result as a
/// download (PLAN-PWA S3).
const canExportAudio = true;

/// LAME is C and does not build for wasm32-unknown-unknown, so the `mp3`
/// Cargo feature is off in the web engine — offering MP3 would hand the user
/// an encoder error instead of a file (docs/PLAN-PWA.md).
const canEncodeMp3 = false;

/// The browser's export destination: a download.
RenderOutput createDownloadOutput(String filename) =>
    BlobRenderOutput(filename);

/// Collects the rendered blocks and hands the finished file to the browser.
///
/// The parts stay `Blob`s, which the browser keeps **off** the JS heap (and
/// spills to disk when large) — the alternative, concatenating into one
/// `Uint8List`, would need the whole render in memory, and a 90-minute WAV is
/// ~1.5 GB.
class BlobRenderOutput implements RenderOutput {
  BlobRenderOutput(this.filename);

  final String filename;
  final List<web.Blob> _parts = [];

  @override
  void addBody(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _parts.add(_blobOf(bytes));
  }

  @override
  Future<void> complete(Uint8List head, Uint8List tail) async {
    // The header is produced last but belongs first: the encoders patch it
    // once the render is done.
    final parts = <web.Blob>[_blobOf(head), ..._parts, _blobOf(tail)];
    final blob = web.Blob(
      parts.map((p) => p as JSAny).toList().toJS,
      web.BlobPropertyBag(type: 'application/octet-stream'),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = filename;
    web.document.body!.appendChild(anchor);
    anchor.click();
    anchor.remove();
    // Revoking while the browser is still writing the file cuts the download
    // off — Safari in particular starts it well after the click returns. The
    // URL is held for a while and then released so the (possibly gigabyte)
    // blob does not outlive the tab's need for it.
    await Future<void>.delayed(const Duration(minutes: 5));
    web.URL.revokeObjectURL(url);
  }

  static web.Blob _blobOf(Uint8List bytes) =>
      web.Blob([bytes.toJS as JSAny].toJS);
}

/// Opens the browser file picker and wraps each pick in lazy range access.
Future<List<PickedRecording>> pickRecordings() async {
  const group = XTypeGroup(label: 'WAV', extensions: ['wav'], mimeTypes: []);
  final files = await openFiles(acceptedTypeGroups: const [group]);
  return [for (final f in files) await _lazyRecording(f)];
}

/// Wraps one picked file so ranges come straight off its `Blob`.
///
/// **Do not go back to `XFile.openRead(start, end)` here.** It looks like the
/// obvious API and it is quadratic: `file_selector_web` builds its `XFile`
/// from `URL.createObjectURL(file)` alone and never hands over the `File`, so
/// `cross_file` holds no Blob to slice. Every single call therefore
/// re-hydrates the *whole* file over XHR and then keeps 4 MB of it.
/// Analysing a 782 MB take that way copied 150 GB and spent 97 s in reads
/// against 2.6 s of actual analysis; hydrating once and slicing here brings
/// the reads down to ~0.5 s (docs/PLAN-PWA.md).
///
/// The Blob stays file-backed — it is a handle, not bytes on the JS heap —
/// so holding it costs nothing even for a multi-GB take.
Future<PickedRecording> _lazyRecording(XFile file) async {
  final size = await file.length();
  Future<web.Blob>? blob;

  Future<web.Blob> hydrate() async {
    final response = await web.window.fetch(file.path.toJS).toDart;
    return response.blob().toDart;
  }

  return PickedRecording(
    // Blobs have no path; the name keeps session keys readable and stable
    // enough for one browser session.
    source: 'blob:${file.name}',
    name: file.name,
    sizeBytes: size,
    read: (start, end) async {
      final source = await (blob ??= hydrate());
      final buffer = await source.slice(start, end).arrayBuffer().toDart;
      return buffer.toDart.asUint8List();
    },
  );
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

// ── preview audio ───────────────────────────────────────────────────────────

@JS('SharedArrayBuffer')
extension type _SharedArrayBuffer._(JSObject _) implements JSObject {
  external _SharedArrayBuffer(int byteLength);
}

@JS('Float32Array')
extension type _JsFloat32Array._(JSObject _) implements JSObject {
  external _JsFloat32Array(JSObject buffer);
  external void set(JSObject source, int offset);
  external int get length;
}

@JS('Int32Array')
extension type _JsInt32Array._(JSObject _) implements JSObject {
  external _JsInt32Array(JSObject buffer);
}

@JS('Atomics.load')
external int _atomicsLoad(JSObject array, int index);

@JS('Atomics.store')
external int _atomicsStore(JSObject array, int index, int value);

/// Ring indices, shared with `web/audio-pump.js`.
const _stateRead = 0;
const _stateWrite = 1;
const _stateUnderruns = 2;
const _statePlayed = 3;

/// Roughly a second of stereo audio. Long enough to survive a stalled main
/// thread (layout, GC), short enough that a fader move is heard promptly —
/// live parameter changes only reach the ear once the ring has drained.
const _ringSeconds = 1.0;

/// Browser preview output: an `AudioWorklet` reading a ring buffer.
///
/// The worklet runs on the audio thread and must never wait, so it only
/// copies out of a `SharedArrayBuffer` this class keeps filled. That needs
/// cross-origin isolation, which `coi-sw.js` already provides for the
/// threaded wasm engine.
class _WorkletPreviewSink implements PreviewSink {
  _WorkletPreviewSink(this._context, this._node, this._ring, this._state)
    : _capacity = _ring.length;

  final web.AudioContext _context;
  final web.AudioWorkletNode _node;
  final _JsFloat32Array _ring;
  final _JsInt32Array _state;
  final int _capacity;

  @override
  int get sampleRate => _context.sampleRate.round();

  @override
  int get freeSamples {
    final read = _atomicsLoad(_state, _stateRead);
    final write = _atomicsLoad(_state, _stateWrite);
    // One slot stays empty so full and empty stay distinguishable.
    return (read - write + _capacity - 2) % _capacity;
  }

  @override
  int get bufferedSamples {
    final read = _atomicsLoad(_state, _stateRead);
    final write = _atomicsLoad(_state, _stateWrite);
    return (write - read + _capacity) % _capacity;
  }

  @override
  int get playedFrames => _atomicsLoad(_state, _statePlayed);

  @override
  int get underruns => _atomicsLoad(_state, _stateUnderruns);

  @override
  void write(Float32List samples) {
    var write = _atomicsLoad(_state, _stateWrite);
    var offset = 0;
    while (offset < samples.length) {
      final n = (samples.length - offset).clamp(0, _capacity - write);
      _ring.set(
        Float32List.sublistView(samples, offset, offset + n).toJS,
        write,
      );
      write += n;
      if (write >= _capacity) write -= _capacity;
      offset += n;
    }
    _atomicsStore(_state, _stateWrite, write);
  }

  @override
  void flush() {
    _atomicsStore(_state, _stateWrite, _atomicsLoad(_state, _stateRead));
  }

  @override
  Future<void> dispose() async {
    _node.disconnect();
    await _context.close().toDart;
  }
}

/// Open the browser's audio output at [sampleRate].
///
/// The context is created at the file's rate rather than the browser default:
/// a 44.1 kHz take through a 48 kHz context would play sharp. Must be called
/// from a user gesture — iOS Safari starts every context suspended.
Future<PreviewSink?> openPreviewSink(int sampleRate) async {
  final context = web.AudioContext(
    web.AudioContextOptions(sampleRate: sampleRate.toDouble()),
  );
  await context.audioWorklet.addModule('audio-pump.js').toDart;

  final samples = (sampleRate * _ringSeconds).round() * 2;
  final ringBuffer = _SharedArrayBuffer(samples * 4);
  final stateBuffer = _SharedArrayBuffer(4 * 4);
  final ring = _JsFloat32Array(ringBuffer);
  final state = _JsInt32Array(stateBuffer);

  final options = web.AudioWorkletNodeOptions(
    numberOfInputs: 0,
    numberOfOutputs: 1,
    outputChannelCount: [2].jsify()! as JSArray<JSNumber>,
    processorOptions:
        {'ring': ringBuffer, 'state': stateBuffer}.jsify()! as JSObject,
  );
  final node = web.AudioWorkletNode(context, 'durecmix-pump', options);
  node.connect(context.destination);
  await context.resume().toDart;
  return _WorkletPreviewSink(context, node, ring, state);
}
