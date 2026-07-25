import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Parsed view of CHANGELOG.md for the in-app "What's new" dialog.
///
/// The file is the single source of truth (bundled as an asset), so this
/// parser understands exactly the subset the changelog uses — version
/// headings, category headings and bullets — and nothing more:
///
///     ## [0.12.15] – 2026-07-25
///     ### Added
///     - **Bold lead-in:** rest of the bullet,
///       wrapped onto a continuation line.
///
/// `test/changelog_test.dart` fails when the real file drifts outside this
/// subset or out of sync with pubspec.yaml.
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.sections,
  });

  /// Bare version, e.g. "0.12.15".
  final String version;

  /// Release date as written, e.g. "2026-07-25".
  final String date;

  final List<ChangelogSection> sections;
}

/// One category ("Added", "Fixed", …) with its bullets in file order.
class ChangelogSection {
  const ChangelogSection({required this.title, required this.items});

  final String title;

  /// Bullet texts with continuation lines joined; `**` markers are kept and
  /// interpreted by the dialog's renderer.
  final List<String> items;
}

final _versionHeading = RegExp(r'^## \[([^\]]+)\] [–—-] (.+)$');
final _sectionHeading = RegExp(r'^### (.+)$');
final _linkReference = RegExp(r'^\[[^\]]+\]: ');

/// Parses changelog markdown into entries, newest first (file order).
List<ChangelogEntry> parseChangelog(String markdown) {
  final entries = <ChangelogEntry>[];
  List<ChangelogSection>? sections;
  List<String>? items;

  for (final line in markdown.split('\n')) {
    final version = _versionHeading.firstMatch(line);
    if (version != null) {
      sections = [];
      items = null;
      entries.add(
        ChangelogEntry(
          version: version.group(1)!,
          date: version.group(2)!.trim(),
          sections: sections,
        ),
      );
      continue;
    }
    if (sections == null) continue; // preamble before the first version
    final section = _sectionHeading.firstMatch(line);
    if (section != null) {
      items = [];
      sections.add(
        ChangelogSection(title: section.group(1)!.trim(), items: items),
      );
      continue;
    }
    if (_linkReference.hasMatch(line)) continue;
    final trimmed = line.trim();
    if (trimmed.isEmpty || items == null) continue;
    if (trimmed.startsWith('- ')) {
      items.add(trimmed.substring(2).trim());
    } else if (items.isNotEmpty) {
      // Continuation of a wrapped bullet.
      items[items.length - 1] = '${items.last} $trimmed';
    }
  }
  return entries;
}

/// Loads and parses the bundled CHANGELOG.md.
Future<List<ChangelogEntry>> loadChangelog({AssetBundle? bundle}) async {
  return parseChangelog(
    await (bundle ?? rootBundle).loadString('CHANGELOG.md'),
  );
}
