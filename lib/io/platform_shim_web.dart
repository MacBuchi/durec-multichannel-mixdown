/// Web implementation of the platform shim (docs/PLAN-PWA.md, S1).
///
/// The app container is a map in memory mirrored into IndexedDB, so settings,
/// the mix and the caches outlive the tab (see [FileStore] for why the map is
/// the source of truth and storage the mirror). What cannot outlive it is the
/// *recording*: without a File System Access API there is no handle to keep, so
/// the file is picked again and the mix re-attaches by name.
///
/// Networking is still absent by design ([hasNetwork]).
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'file_store.dart';
import 'platform_shim_types.dart';

bool get isAndroidPlatform => false;
bool get isIOSPlatform => false;
bool get isMacOSPlatform => false;
bool get isWindowsPlatform => false;
String get operatingSystemName => 'Web';
String get pathSeparator => '/';

const _appSupport = '/web-app-support';

/// The app container: an in-memory map mirrored into IndexedDB, so settings,
/// the mix and the caches survive a reload (#111). Keys are the virtual paths
/// handed out below.
final _files = FileStore(persistPrefix: _appSupport);

/// Read browser storage into the container. Called from `main` before anything
/// reads it, because [fileExistsSync] cannot wait.
///
/// The **file** a mix belongs to cannot be kept: Safari has no File System
/// Access API, so there is no handle to store and the recording has to be
/// picked again after a reload. It re-attaches by itself — [_lazyRecording]
/// keys a source on the file name, and that is what the session path hashes.
Future<void> initPlatformStorage() async {
  await _files.hydrate(await IndexedDbFileStoreBackend.open());
  // Without this, Safari may evict the store after a week of not visiting;
  // granted silently for an installed PWA, refused (harmlessly) elsewhere.
  try {
    await web.window.navigator.storage.persist().toDart;
  } catch (_) {
    // Not implemented in every browser, and never worth failing a boot over.
  }
}

/// Whether what the app writes will still be there on the next visit — false
/// in a private window, where IndexedDB is refused. Never null here: in a
/// browser the answer always needs saying, one way or the other.
bool? get browserStoragePersists => _files.persists;

Future<String> applicationSupportPath() async => _appSupport;

Future<String> systemTempPath() async => '/web-tmp';

Future<void> ensureDirectory(String path) async {}

bool fileExistsSync(String path) => _files.exists(path);

void renameFileSync(String from, String to) => _files.rename(from, to);

void deleteFileSync(String path) => _files.delete(path);

Future<String> readTextFile(String path) async => _files.readText(path);

Future<void> writeTextFile(String path, String contents) async =>
    _files.writeText(path, contents);

Future<Uint8List> readBinaryFile(String path) async {
  final bytes = _files.read(path);
  if (bytes == null) {
    throw StateError('no such file in the app container: $path');
  }
  return bytes;
}

Future<void> writeBinaryFile(String path, Uint8List bytes) async =>
    _files.write(path, bytes);

/// IndexedDB as a flat path → bytes store.
///
/// One object store keyed by the virtual path; values are `Uint8List`, which
/// the structured clone algorithm stores natively. IndexedDB rather than OPFS
/// because it is supported everywhere the app runs — OPFS writable streams
/// arrived late in Safari, and this needs no worker.
///
/// Public only so a browser test can prove the round trip: unit tests run on
/// the VM, where none of this exists, so `test/web_storage_browser_test.dart`
/// drives this class under `flutter test --platform chrome`. Nothing else
/// should reach for it — the app goes through [initPlatformStorage].
class IndexedDbFileStoreBackend implements FileStoreBackend {
  IndexedDbFileStoreBackend(this._db);

  static const _dbName = 'durecmix';
  static const _storeName = 'container';

  final web.IDBDatabase _db;

  /// Opens the database, creating the object store on first visit. Throws when
  /// the browser refuses IndexedDB (private windows do); [FileStore.hydrate]
  /// turns that into "runs without persistence".
  static Future<FileStoreBackend> open() async {
    final request = web.window.indexedDB.open(_dbName, 1);
    final done = Completer<web.IDBDatabase>();
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete(request.result as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('IndexedDB unavailable'));
      }
    }).toJS;
    // A `versionchange` transaction that another tab blocks would otherwise
    // hang the boot; without a timeout the app would never show a frame.
    return IndexedDbFileStoreBackend(
      await done.future.timeout(const Duration(seconds: 5)),
    );
  }

  web.IDBObjectStore _store(String mode) =>
      _db.transaction(_storeName.toJS, mode).objectStore(_storeName);

  @override
  Future<Map<String, Uint8List>> loadAll() async {
    final store = _store('readonly');
    final keys = await _await<JSObject>(store.getAllKeys());
    final values = await _await<JSObject>(store.getAll());
    final keyList = (keys as JSArray).toDart;
    final valueList = (values as JSArray).toDart;
    final out = <String, Uint8List>{};
    for (var i = 0; i < keyList.length && i < valueList.length; i++) {
      final key = (keyList[i] as JSString).toDart;
      final value = valueList[i];
      // Anything that is not a byte buffer was not written by this version;
      // drop it rather than crash the boot on it.
      if (value.isA<JSUint8Array>()) {
        out[key] = (value as JSUint8Array).toDart;
      } else if (value.isA<JSArrayBuffer>()) {
        out[key] = (value as JSArrayBuffer).toDart.asUint8List();
      }
    }
    return out;
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    // A fresh copy: the caller may hold a view into a larger buffer, and
    // structured clone would then store the whole thing.
    await _await<JSAny?>(
      _store('readwrite').put(Uint8List.fromList(bytes).toJS, key.toJS),
    );
  }

  @override
  Future<void> remove(String key) async {
    await _await<JSAny?>(_store('readwrite').delete(key.toJS));
  }

  /// One `IDBRequest` as a future.
  static Future<T> _await<T extends JSAny?>(web.IDBRequest request) {
    final done = Completer<T>();
    request.onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete(request.result as T);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('IndexedDB request failed'));
      }
    }).toJS;
    return done.future;
  }
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

/// Reference mastering works here since v0.15.0: the reference is analyzed
/// from bytes ([pickReferenceAudio]) and the mix from byte ranges, and
/// `engine/tests` pins both to the file-based paths — including a mastered
/// render that is byte-identical to the native one.
const canMasterToReference = true;

/// [httpGetText] and [httpPostJson] throw here, so anything that talks to a
/// server must not be offered — and must not pretend it happened. The update
/// check would otherwise report "You're up to date" after silently
/// swallowing an `UnsupportedError`, and feedback would blame the user's
/// connection for a route that does not exist.
const hasNetwork = false;

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
    // blob does not outlive the tab's need for it. Fire-and-forget: for the
    // caller the export ends when the download starts — awaiting this delay
    // kept the export button greyed out for the full five minutes.
    unawaited(
      Future<void>.delayed(
        const Duration(minutes: 5),
      ).then((_) => web.URL.revokeObjectURL(url)),
    );
  }

  static web.Blob _blobOf(Uint8List bytes) =>
      web.Blob([bytes.toJS as JSAny].toJS);
}

/// Opens the browser file picker and wraps each pick in lazy range access.
///
/// **Deliberately not `file_selector`'s `openFiles()`.** That plugin throws
/// the picked `File` away and keeps only `URL.createObjectURL(file)`, which
/// leaves us nothing to slice — see [_lazyRecording] for what that cost. The
/// `<input>` here is the same one the plugin builds, minus the lossy wrapper:
/// the real `File` survives, so reads go straight to disk.
Future<List<PickedRecording>> pickRecordings() {
  final completer = Completer<List<PickedRecording>>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    // Safari on iOS ignores an extension-only accept list for files coming
    // out of iCloud Drive, so the WAV MIME types ride along.
    ..accept = '.wav,audio/wav,audio/x-wav,audio/wave'
    ..multiple = true;
  // Must be in the document for the click to open a picker in Safari.
  web.document.body!.appendChild(input);

  void finish(List<PickedRecording> picked) {
    if (completer.isCompleted) return;
    input.remove();
    completer.complete(picked);
  }

  input.onChange.first.then((_) {
    final files = input.files;
    finish([
      if (files != null)
        for (var i = 0; i < files.length; i++) _lazyRecording(files.item(i)!),
    ]);
  });
  // Dismissing the picker fires `cancel`, never `change` — without this the
  // future would never complete and the caller would wait forever.
  input.addEventListener('cancel', ((web.Event _) => finish(const [])).toJS);
  input.click();
  return completer.future;
}

/// Bytes of the mastering references picked this session, by pseudo-path.
///
/// Deliberately *not* in the app container: a reference is megabytes and would
/// eat the storage quota for no gain. What persists is its analyzed profile
/// (`ReferenceProfileCache`, a few kilobytes), and that is enough — after a
/// reload the profile comes from the cache and the file is never re-read.
final Map<String, Uint8List> _referenceBytes = {};

/// Pick a mastering reference (WAV/FLAC/MP3/OGG) and read it whole.
Future<PickedReference?> pickReferenceAudio() async {
  final completer = Completer<web.File?>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    // Same reason as the recording picker: iOS Safari ignores an
    // extension-only list for files coming out of iCloud Drive.
    ..accept =
        '.wav,.flac,.mp3,.ogg,audio/wav,audio/x-wav,audio/flac,'
        'audio/mpeg,audio/ogg';
  web.document.body!.appendChild(input);
  void finish(web.File? file) {
    if (completer.isCompleted) return;
    input.remove();
    completer.complete(file);
  }

  input.onChange.first.then((_) => finish(input.files?.item(0)));
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
  input.click();

  final file = await completer.future;
  if (file == null) return null;
  final buffer = await file.arrayBuffer().toDart;
  final picked = PickedReference(
    source: 'blob:${file.name}',
    name: file.name,
    bytes: buffer.toDart.asUint8List(),
  );
  _referenceBytes[picked.source] = picked.bytes;
  return picked;
}

/// Bytes for a reference picked in this tab, or null when only its profile is
/// known (after a reload) — the caller then relies on the profile cache.
Uint8List? referenceBytesFor(String source) => _referenceBytes[source];

/// Wraps one picked file so ranges come straight off it.
///
/// A `File` **is** a `Blob`, and a picked one is backed by the file on disk:
/// `slice()` hands back another lazy view, so a multi-GB take never enters
/// memory and holding it costs nothing.
///
/// **Do not reintroduce a `fetch()` of a blob URL here, and do not go back to
/// `XFile.openRead(start, end)`.** Both start from `file_selector`'s
/// `XFile`, which carries only `URL.createObjectURL(file)`:
/// * `openRead` is quadratic — `cross_file` has no Blob to slice, so every
///   call re-fetches the *whole* file and keeps 4 MB of it. Analysing a
///   782 MB take copied 150 GB and spent 97 s in reads against 2.6 s of
///   actual analysis.
/// * fetching the blob URL once fixed that, but `response.blob()`
///   *materialises a second copy* of the file. Chrome spills it to disk;
///   WebKit keeps it in RAM, so a >1 GB take blew the iPad tab's memory
///   budget and the import failed outright.
///
/// Keeping the `File` avoids both (docs/PLAN-PWA.md).
PickedRecording _lazyRecording(web.File file) => PickedRecording(
  // Blobs have no path; the name keeps session keys readable and stable
  // enough for one browser session.
  source: 'blob:${file.name}',
  name: file.name,
  sizeBytes: file.size,
  read: (start, end) async {
    final buffer = await file.slice(start, end).arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  },
);

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
  int trimTo(int samples) {
    final read = _atomicsLoad(_state, _stateRead);
    final buffered =
        (_atomicsLoad(_state, _stateWrite) - read + _capacity) % _capacity;
    if (buffered <= samples) return 0;
    // Only the write index moves, and only backwards towards the read index:
    // the worklet keeps consuming from `read` throughout, so what it is
    // playing right now is never pulled out from under it.
    var write = read + samples;
    if (write >= _capacity) write -= _capacity;
    _atomicsStore(_state, _stateWrite, write);
    return buffered - samples;
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
