/// The web build's app container: a map in memory that writes itself through
/// to browser storage, so a mix survives a reload (#111).
///
/// Why a map at all, rather than reading storage on demand? Because parts of
/// the shim this backs are **synchronous** — `fileExistsSync`,
/// `renameFileSync`, `deleteFileSync` — and every persistent web store
/// (IndexedDB, OPFS, the Cache API) is asynchronous. Keeping the map as the
/// source of truth preserves those signatures; storage is a mirror that is
/// filled once at startup and updated behind the app's back.
///
/// Deliberately pure Dart: no `dart:js_interop`, no `package:web`. The
/// interesting behaviour — hydrate before use, coalesce repeated writes, never
/// let a refusing browser break the app — is then unit-testable on the VM
/// against a fake backend, and the IndexedDB adapter stays thin enough to read
/// in one sitting (`lib/io/platform_shim_web.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Where a [FileStore] keeps its contents between visits.
///
/// One key per virtual path, bytes as the value. Implementations may throw:
/// the store treats every failure as "this browser does not want to store
/// anything" and carries on in memory.
abstract class FileStoreBackend {
  /// Everything stored so far. Called once, before the app reads anything.
  Future<Map<String, Uint8List>> loadAll();

  Future<void> put(String key, Uint8List bytes);

  Future<void> remove(String key);
}

/// A backend that stores nothing — the container behaves exactly as it did
/// before persistence existed. Used where a browser refuses storage (private
/// windows block IndexedDB) and in tests that do not care about it.
class EphemeralFileStoreBackend implements FileStoreBackend {
  const EphemeralFileStoreBackend();

  @override
  Future<Map<String, Uint8List>> loadAll() async => const {};

  @override
  Future<void> put(String key, Uint8List bytes) async {}

  @override
  Future<void> remove(String key) async {}
}

class FileStore {
  /// [persistPrefix] limits what reaches storage. Everything the app keeps —
  /// settings, sessions, waveform caches, reference profiles — lives under the
  /// app-support path and is small. A rendered export is hundreds of
  /// megabytes; it goes straight to a download today and must never end up in
  /// a quota-limited store, so the prefix is a guard against a future writer
  /// putting it somewhere it would be mirrored.
  FileStore({required this.persistPrefix});

  final String persistPrefix;

  final Map<String, Uint8List> _files = {};

  /// Pending writes, latest value per key; `null` means delete.
  ///
  /// A map rather than a queue because the session autosave debounces to once
  /// a second and a long mixing session would otherwise pile up hundreds of
  /// superseded puts for the same key.
  final Map<String, Uint8List?> _pending = {};

  Future<void>? _flushing;
  FileStoreBackend _backend = const EphemeralFileStoreBackend();
  bool _hydrated = false;

  /// Whether anything written here will still be here next visit — false in a
  /// browser that refused storage, so the UI can say so rather than promise it.
  bool get persists => _hydrated && _backend is! EphemeralFileStoreBackend;

  /// Adopt [backend] and read what it already holds into memory.
  ///
  /// Must complete before the app reads the container, because
  /// [fileExistsSync] cannot wait for it. A backend that throws is downgraded
  /// to [EphemeralFileStoreBackend]: no persistence, but a working tab.
  Future<void> hydrate(FileStoreBackend backend) async {
    if (_hydrated) return;
    try {
      final stored = await backend.loadAll();
      // Anything written while hydration was in flight is newer than what
      // storage holds, so the in-memory entry wins.
      for (final e in stored.entries) {
        _files.putIfAbsent(e.key, () => e.value);
      }
      _backend = backend;
    } catch (_) {
      _backend = const EphemeralFileStoreBackend();
    }
    _hydrated = true;
    // Whatever was written before a backend existed is precisely what storage
    // has never seen, so it flushes now rather than waiting for the next edit.
    if (_pending.isNotEmpty) _flushing ??= _flush();
  }

  bool exists(String path) => _files.containsKey(path);

  Uint8List? read(String path) => _files[path];

  String readText(String path) {
    final bytes = _files[path];
    if (bytes == null) {
      throw StateError('no such file in the app container: $path');
    }
    return utf8.decode(bytes);
  }

  void write(String path, Uint8List bytes) {
    _files[path] = bytes;
    _schedule(path, bytes);
  }

  void writeText(String path, String contents) =>
      write(path, Uint8List.fromList(utf8.encode(contents)));

  void delete(String path) {
    if (_files.remove(path) == null) return;
    _schedule(path, null);
  }

  void rename(String from, String to) {
    final bytes = _files.remove(from);
    if (bytes == null) {
      throw ArgumentError.value(from, 'from', 'no such file in the container');
    }
    _files[to] = bytes;
    _schedule(from, null);
    _schedule(to, bytes);
  }

  /// Completes when every pending write has reached the backend. For tests and
  /// for a caller that wants to know the mix is safely stored; the app itself
  /// never waits on this.
  Future<void> settled() async {
    while (_flushing != null) {
      await _flushing;
    }
  }

  void _schedule(String path, Uint8List? bytes) {
    if (!path.startsWith(persistPrefix)) return;
    _pending[path] = bytes;
    // No backend has been adopted yet, so there is nowhere to flush to —
    // [hydrate] picks these up once there is.
    if (_hydrated) _flushing ??= _flush();
  }

  Future<void> _flush() async {
    while (_pending.isNotEmpty) {
      final path = _pending.keys.first;
      final bytes = _pending.remove(path);
      try {
        if (bytes == null) {
          await _backend.remove(path);
        } else {
          await _backend.put(path, bytes);
        }
      } catch (_) {
        // Storage refused this one — a full quota, or eviction mid-session.
        // The value stays in memory, so the tab is unaffected; retrying here
        // would risk a hot loop against a permanently full store.
      }
    }
    _flushing = null;
  }
}
