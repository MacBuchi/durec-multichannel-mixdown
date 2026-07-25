import 'dart:io';

import 'package:durecmix/state/changelog.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = '''
# Changelog

Preamble that the parser must skip.

## [0.2.0] – 2026-07-25

### Added

- **Bold lead-in:** rest of the bullet,
  joined from a continuation line.
- Plain bullet with `code`.

### Fixed

- Single fix.

## [0.1.0] — 2026-07-01

### Added

- First.

[0.2.0]: https://example.com/v0.2.0
[0.1.0]: https://example.com/v0.1.0
''';

void main() {
  group('parseChangelog', () {
    test('splits versions, sections and bullets in file order', () {
      final entries = parseChangelog(_fixture);
      expect(entries.map((e) => e.version), ['0.2.0', '0.1.0']);
      expect(entries.first.date, '2026-07-25');
      expect(entries.first.sections.map((s) => s.title), ['Added', 'Fixed']);
      expect(entries.first.sections.last.items, ['Single fix.']);
      expect(entries.last.sections.single.items, ['First.']);
    });

    test('joins wrapped bullets and keeps bold markers for the renderer', () {
      final added = parseChangelog(_fixture).first.sections.first;
      expect(added.items, [
        '**Bold lead-in:** rest of the bullet, joined from a continuation '
            'line.',
        'Plain bullet with `code`.',
      ]);
    });

    test('ignores the link-reference list at the file end', () {
      final entries = parseChangelog(_fixture);
      for (final entry in entries) {
        for (final section in entry.sections) {
          expect(
            section.items,
            everyElement(isNot(contains('example.com'))),
            reason: 'link references are metadata, not bullets',
          );
        }
      }
    });
  });

  // Release-trap guards (see AGENTS.md, Testing): everything here compiles
  // fine when broken and only fails in a user's hands — the merge IS the
  // release, so CI must catch the drift.
  group('CHANGELOG.md stays consistent with the release flow', () {
    final changelog = File('CHANGELOG.md').readAsStringSync();
    final entries = parseChangelog(changelog);

    test('top entry matches the pubspec version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(
        r'^version:\s*([0-9.]+)\+',
        multiLine: true,
      ).firstMatch(pubspec)!.group(1);
      expect(
        entries.first.version,
        version,
        reason:
            'a version bump must add its CHANGELOG section, otherwise the '
            'released app shows a stale "What\'s new"',
      );
    });

    test('is bundled as an asset', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec,
        contains('\n    - CHANGELOG.md'),
        reason:
            'without the asset entry the What\'s-new dialog fails only at '
            'runtime',
      );
    });

    test('every version heading has a matching release link', () {
      for (final entry in entries) {
        expect(
          changelog,
          contains(
            '[${entry.version}]: https://github.com/MacBuchi/'
            'durec-multichannel-mixdown/releases/tag/v${entry.version}',
          ),
          reason: 'house convention: link list at the file end',
        );
      }
    });

    test('parses into the shape the dialog renders', () {
      expect(entries.length, greaterThanOrEqualTo(35));
      for (final entry in entries) {
        expect(
          entry.sections,
          isNotEmpty,
          reason: '${entry.version} renders as an empty block',
        );
        for (final section in entry.sections) {
          expect(
            section.items,
            isNotEmpty,
            reason: '${entry.version}/${section.title} has no bullets',
          );
        }
      }
    });
  });
}
