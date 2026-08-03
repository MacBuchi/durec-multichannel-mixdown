@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:durecmix/io/file_store.dart';
import 'package:durecmix/io/platform_shim_web.dart';
import 'package:flutter_test/flutter_test.dart';

/// The half of persistence that no VM test can reach: the IndexedDB adapter.
///
/// `test/file_store_test.dart` covers the store's rules against a fake backend,
/// but a fake cannot show that bytes actually survive in a browser — that is
/// structured clone, an object store and a transaction, none of which exist on
/// the VM. So this runs in Chrome:
///
///     flutter test --platform chrome test/web_storage_browser_test.dart
///
/// A plain `flutter test` skips the file (`@TestOn('browser')`).
void main() {
  const prefix = '/web-app-support';

  Future<FileStore> openStore() async {
    final store = FileStore(persistPrefix: prefix);
    await store.hydrate(await IndexedDbFileStoreBackend.open());
    return store;
  }

  test('a mix written in one visit is there in the next', () async {
    final key = '$prefix/sessions/probe.durecmix.json';
    const mix = '{"tracks":[{"gain_db":-3.5}]}';

    final first = await openStore();
    expect(first.persists, isTrue, reason: 'Chrome should allow IndexedDB');
    first.writeText(key, mix);
    await first.settled();

    // A second store with its own connection is what a reload amounts to:
    // nothing carried over in memory, everything read back from the browser.
    final second = await openStore();
    expect(second.exists(key), isTrue);
    expect(second.readText(key), mix);

    second.delete(key);
    await second.settled();
    final third = await openStore();
    expect(third.exists(key), isFalse);
  });

  test('binary caches round-trip byte for byte', () async {
    // The waveform cache is ~160 KB of packed floats; structured clone must
    // hand back exactly what went in, or a cached take draws wrong.
    final key = '$prefix/caches/probe.bin';
    final payload = List<int>.generate(64 * 1024, (i) => (i * 31) % 256);

    final first = await openStore();
    first.write(key, Uint8List.fromList(payload));
    await first.settled();

    final second = await openStore();
    expect(second.read(key), equals(payload));

    second.delete(key);
    await second.settled();
  });

  test('the app container survives a rename across visits', () async {
    // The legacy-session migration in session_paths.dart renames in place.
    final from = '$prefix/sessions/legacy.json';
    final to = '$prefix/sessions/current.json';

    final first = await openStore();
    first.writeText(from, 'a mix');
    await first.settled();

    final second = await openStore();
    second.rename(from, to);
    await second.settled();

    final third = await openStore();
    expect(third.exists(from), isFalse);
    expect(third.readText(to), 'a mix');

    third.delete(to);
    await third.settled();
  });
}
