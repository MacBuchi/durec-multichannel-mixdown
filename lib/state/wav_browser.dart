import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'app_settings.dart';

/// One .wav file in the browsed folder.
class WavEntry {
  WavEntry({
    required this.source,
    required this.name,
    this.sizeBytes,
    this.modified,
  });

  /// Filesystem path, or a SAF document URI on Android.
  final String source;
  final String name;
  final int? sizeBytes;
  final DateTime? modified;

  /// Filled in lazily by the probe queue.
  rust.ApiProbe? probe;
  String? probeError;

  /// Ticked for the multi-file export. Defaults to true for multichannel
  /// takes once the probe lands; stereo files start unticked.
  bool selected = false;

  /// Editable output name (without extension) for the multi-file export.
  /// Defaults to the original name minus its .wav ending.
  String? outputStem;

  String get defaultStem =>
      name.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '');
}

/// Folder listing + lazy metadata probing for the in-app WAV browser.
///
/// The list itself comes straight from the directory (instant); a single
/// sequential queue then probes each file (header parse only, no audio
/// scan) — sequential on purpose: USB-OTG sticks handle one reader far
/// better than a swarm. Probe results are cached per source+mtime so
/// reopening the browser is instant.
class WavBrowser extends ChangeNotifier {
  WavBrowser(this.settings) : sortByDate = settings.sortByDate;

  final AppSettings settings;
  final List<WavEntry> entries = [];
  String? folder;
  String? folderName;
  String? error;
  bool loading = false;
  bool sortByDate;

  int _generation = 0;
  static final Map<String, rust.ApiProbe> _probeCache = {};

  /// Platform folder picker: SAF tree on Android, path elsewhere.
  Future<String?> pickFolder() async =>
      Platform.isAndroid ? Saf.pickDirectory() : getDirectoryPath();

  /// List `target`'s .wav files and start probing them.
  Future<void> openFolder(String target) async {
    final generation = ++_generation;
    folder = target;
    folderName = _folderDisplayName(target);
    error = null;
    loading = true;
    entries.clear();
    notifyListeners();
    try {
      final listed = Saf.isContentUri(target)
          ? await _listSaf(target)
          : await _listPath(target);
      if (generation != _generation) return;
      entries.addAll(listed);
      _sort();
      loading = false;
      notifyListeners();
      settings
        ..lastFolder = target
        ..save();
      _probeAll(generation);
    } catch (e) {
      if (generation != _generation) return;
      loading = false;
      error = e.toString();
      notifyListeners();
    }
  }

  /// Stop background probing (browser closed / file opened).
  void cancel() => _generation++;

  /// Restart the probe queue over entries still lacking metadata — after a
  /// batch export paused it, remaining rows must not stay "reading…" forever.
  void resumeProbing() => _probeAll(++_generation);

  List<WavEntry> get selectedEntries => [
    for (final e in entries)
      if (e.selected) e,
  ];

  void toggleSelected(WavEntry e) {
    e.selected = !e.selected;
    notifyListeners();
  }

  /// Multi-export selection mode: checkboxes and name fields only appear
  /// here, so the plain list stays unmistakably "tap to open in the mixer".
  bool selectionMode = false;

  void enterSelectionMode() {
    selectionMode = true;
    notifyListeners();
  }

  void exitSelectionMode() {
    selectionMode = false;
    notifyListeners();
  }

  void toggleSort() {
    sortByDate = !sortByDate;
    _sort();
    notifyListeners();
    settings
      ..sortByDate = sortByDate
      ..save();
  }

  void _sort() {
    if (sortByDate) {
      entries.sort(
        (a, b) =>
            (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0)),
      ); // newest first
    } else {
      entries.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    }
  }

  Future<List<WavEntry>> _listSaf(String treeUri) async {
    final raw = await Saf.listDirectory(treeUri);
    return [
      for (final m in raw)
        WavEntry(
          source: m['uri']! as String,
          name: m['name']! as String,
          sizeBytes: m['size'] as int?,
          modified: switch (m['modified']) {
            final int ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms),
            _ => null,
          },
        ),
    ];
  }

  Future<List<WavEntry>> _listPath(String dirPath) async {
    final listed = <WavEntry>[];
    await for (final f in Directory(dirPath).list()) {
      if (f is! File || !f.path.toLowerCase().endsWith('.wav')) continue;
      final stat = await f.stat();
      listed.add(
        WavEntry(
          source: f.path,
          name: f.path.split(Platform.pathSeparator).last,
          sizeBytes: stat.size,
          modified: stat.modified,
        ),
      );
    }
    return listed;
  }

  Future<void> _probeAll(int generation) async {
    for (final e in List.of(entries)) {
      if (generation != _generation) return;
      if (e.probe != null || e.probeError != null) continue;
      final cacheKey = '${e.source}|${e.modified?.millisecondsSinceEpoch}';
      final cached = _probeCache[cacheKey];
      if (cached != null) {
        e.probe = cached;
        e.selected = cached.channels > 2;
        notifyListeners();
        continue;
      }
      try {
        final fd = Saf.isContentUri(e.source)
            ? await Saf.openFd(e.source)
            : null;
        final probe = await rust.probeRecording(path: e.source, fd: fd);
        if (generation != _generation) return;
        e.probe = probe;
        e.selected = probe.channels > 2;
        _probeCache[cacheKey] = probe;
      } catch (err) {
        if (generation != _generation) return;
        e.probeError = err.toString();
      }
      notifyListeners();
    }
  }

  static String _folderDisplayName(String target) {
    if (!Saf.isContentUri(target)) {
      return target.split(Platform.pathSeparator).last;
    }
    // Tree URIs end in an id like "primary:Music/DUREC" or "1234-5678:".
    final id = Uri.decodeComponent(target.split('/').last);
    final path = id.contains(':') ? id.split(':').last : id;
    if (path.isEmpty) return id.replaceAll(':', '');
    return path.split('/').last;
  }
}
