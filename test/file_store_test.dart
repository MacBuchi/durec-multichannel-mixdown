import 'dart:convert';
import 'dart:typed_data';

import 'package:durecmix/io/file_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for IndexedDB: records every call so the tests can assert on what
/// actually reached storage, not just on what the map holds.
class FakeBackend implements FileStoreBackend {
  FakeBackend([Map<String, Uint8List>? initial])
    : stored = {...?initial},
      _initial = {...?initial};

  final Map<String, Uint8List> stored;
  final Map<String, Uint8List> _initial;
  final List<String> puts = [];
  final List<String> removes = [];

  /// Set to fail every write, the way a full quota or a private window does.
  bool failWrites = false;

  /// Set to fail opening, the way a browser that refuses IndexedDB does.
  bool failLoad = false;

  @override
  Future<Map<String, Uint8List>> loadAll() async {
    if (failLoad) throw StateError('IndexedDB unavailable');
    return _initial;
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    puts.add(key);
    if (failWrites) throw StateError('quota exceeded');
    stored[key] = bytes;
  }

  @override
  Future<void> remove(String key) async {
    removes.add(key);
    if (failWrites) throw StateError('quota exceeded');
    stored.remove(key);
  }
}

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

FileStore store() => FileStore(persistPrefix: '/app');

void main() {
  group('hydration', () {
    test('what a previous visit stored is readable straight away', () async {
      final s = store();
      await s.hydrate(FakeBackend({'/app/settings.json': bytes('{"dark":1}')}));

      // Synchronously — this is what `fileExistsSync` needs and why hydration
      // has to finish before the app reads anything.
      expect(s.exists('/app/settings.json'), isTrue);
      expect(s.readText('/app/settings.json'), '{"dark":1}');
    });

    test(
      'a browser that refuses storage still gives a working store',
      () async {
        final s = store();
        await s.hydrate(FakeBackend()..failLoad = true);

        expect(s.persists, isFalse);
        s.writeText('/app/mix.json', 'a mix');
        await s.settled();
        // The tab works; only the next visit will have lost it.
        expect(s.readText('/app/mix.json'), 'a mix');
      },
    );

    test('hydration does not overwrite what was written before it', () async {
      final s = store();
      s.writeText('/app/settings.json', 'newer');
      final backend = FakeBackend({'/app/settings.json': bytes('older')});
      await s.hydrate(backend);
      await s.settled();

      expect(s.readText('/app/settings.json'), 'newer');
      // And the newer value is pushed out, since storage only had the older.
      expect(utf8.decode(backend.stored['/app/settings.json']!), 'newer');
    });

    test('a second hydrate is ignored', () async {
      final s = store();
      await s.hydrate(FakeBackend({'/app/a': bytes('first')}));
      await s.hydrate(FakeBackend({'/app/a': bytes('second')}));
      expect(s.readText('/app/a'), 'first');
    });
  });

  group('write-through', () {
    test('a write reaches storage', () async {
      final s = store();
      final backend = FakeBackend();
      await s.hydrate(backend);

      s.writeText('/app/mix.json', 'the mix');
      await s.settled();
      expect(utf8.decode(backend.stored['/app/mix.json']!), 'the mix');
      expect(s.persists, isTrue);
    });

    test('repeated writes to one key collapse into the last', () async {
      // The session autosave debounces to once a second; a long mixing session
      // must not queue a put per edit.
      final s = store();
      final backend = FakeBackend();
      await s.hydrate(backend);

      for (var i = 0; i < 50; i++) {
        s.writeText('/app/mix.json', 'edit $i');
      }
      await s.settled();

      expect(utf8.decode(backend.stored['/app/mix.json']!), 'edit 49');
      expect(backend.puts.length, lessThan(50));
    });

    test('a delete reaches storage and the value is gone', () async {
      final s = store();
      final backend = FakeBackend({'/app/mix.json': bytes('the mix')});
      await s.hydrate(backend);

      s.delete('/app/mix.json');
      await s.settled();
      expect(s.exists('/app/mix.json'), isFalse);
      expect(backend.stored, isNot(contains('/app/mix.json')));
    });

    test('deleting what is not there touches storage not at all', () async {
      final s = store();
      final backend = FakeBackend();
      await s.hydrate(backend);

      s.delete('/app/never-existed');
      await s.settled();
      expect(backend.removes, isEmpty);
    });

    test('a rename moves the value and both ends land in storage', () async {
      // This is the legacy-session migration in session_paths.dart.
      final s = store();
      final backend = FakeBackend({'/app/legacy.json': bytes('a mix')});
      await s.hydrate(backend);

      s.rename('/app/legacy.json', '/app/current.json');
      await s.settled();

      expect(s.readText('/app/current.json'), 'a mix');
      expect(s.exists('/app/legacy.json'), isFalse);
      expect(utf8.decode(backend.stored['/app/current.json']!), 'a mix');
      expect(backend.stored, isNot(contains('/app/legacy.json')));
    });

    test('renaming a missing file throws rather than inventing one', () async {
      final s = store();
      await s.hydrate(FakeBackend());
      expect(
        () => s.rename('/app/nope.json', '/app/other.json'),
        throwsArgumentError,
      );
    });

    test('storage refusing a write leaves the app usable', () async {
      final s = store();
      final backend = FakeBackend()..failWrites = true;
      await s.hydrate(backend);

      s.writeText('/app/mix.json', 'the mix');
      await s.settled();

      // In memory it is there, so nothing the user is doing breaks; it just
      // will not come back next visit.
      expect(s.readText('/app/mix.json'), 'the mix');
      expect(backend.stored, isEmpty);
    });

    test('one refused write does not stop the next from being tried', () async {
      final s = store();
      final backend = FakeBackend()..failWrites = true;
      await s.hydrate(backend);

      s.writeText('/app/a', 'one');
      await s.settled();
      backend.failWrites = false;
      s.writeText('/app/b', 'two');
      await s.settled();

      expect(utf8.decode(backend.stored['/app/b']!), 'two');
    });
  });

  group('what is kept out of storage', () {
    test('a path outside the prefix stays in memory only', () async {
      // A rendered export is hundreds of megabytes and belongs nowhere near a
      // quota-limited store.
      final s = store();
      final backend = FakeBackend();
      await s.hydrate(backend);

      s.write('/web-tmp/mixdown.wav', bytes('pretend this is 400 MB'));
      await s.settled();

      expect(s.exists('/web-tmp/mixdown.wav'), isTrue);
      expect(backend.puts, isEmpty);
      expect(backend.stored, isEmpty);
    });

    test('deleting an out-of-prefix file does not touch storage', () async {
      final s = store();
      final backend = FakeBackend();
      await s.hydrate(backend);

      s.write('/web-tmp/mixdown.wav', bytes('x'));
      s.delete('/web-tmp/mixdown.wav');
      await s.settled();
      expect(backend.removes, isEmpty);
    });
  });

  test('reading a missing file throws, as the shim promises', () async {
    final s = store();
    await s.hydrate(FakeBackend());
    expect(() => s.readText('/app/nope.json'), throwsStateError);
    expect(s.read('/app/nope.json'), isNull);
  });
}
