import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'mixer_state.dart';
import 'session_paths.dart';
import 'wav_browser.dart';

/// What the multi-file export applies to every rendered take: the current
/// mixer's track values (mapped by track NAME onto each file) and the
/// current loudness/format selection. Captured at the moment the export
/// starts.
class MultiExportConfig {
  MultiExportConfig({
    required this.tracks,
    required this.master,
    required this.loudness,
    required this.customLufs,
    required this.format,
  });

  /// Current mixer tracks; empty when no recording is loaded (each file
  /// then renders with its own saved session / defaults).
  final List<rust.ApiTrack> tracks;
  final rust.ApiMaster master;
  final LoudnessChoice loudness;
  final double customLufs;
  final rust.ApiFormat format;
}

/// Per-file progress the browser rows render.
enum EntryPhase { pending, rendering, done, failed }

class EntryStatus {
  EntryPhase phase = EntryPhase.pending;
  double progress = 0;
  double? integratedLufs;
  String? error;
  String? output; // path or SAF document URI of the finished mixdown
}

/// Renders every selected file of the browsed folder into its `Mixdown/`
/// subfolder, sequentially (one reader per USB stick), with the current mix
/// mapped by track name onto each take. Sessions of the other files are
/// only read, never written; trim/fades are deliberately NOT applied —
/// they are take-specific.
class MultiExportRunner extends ChangeNotifier {
  final Map<String, EntryStatus> status = {};
  bool running = false;
  int current = 0;
  int total = 0;
  bool _cancelRequested = false;

  /// Outputs of the finished run, for the share sheet.
  final List<String> outputs = [];

  EntryStatus statusFor(WavEntry e) => status.putIfAbsent(e.source, EntryStatus.new);

  /// Stop after the file currently rendering (a running render cannot be
  /// interrupted mid-pass).
  void cancel() => _cancelRequested = true;

  Future<void> run(
    List<WavEntry> entries,
    String folder,
    MultiExportConfig config,
  ) async {
    if (running || entries.isEmpty) return;
    running = true;
    _cancelRequested = false;
    current = 0;
    total = entries.length;
    outputs.clear();
    status.clear();
    for (final e in entries) {
      statusFor(e); // pending
    }
    notifyListeners();

    final isSaf = Saf.isContentUri(folder);
    String outDir;
    try {
      if (isSaf) {
        outDir = await Saf.ensureDirectory(folder, 'Mixdown');
      } else {
        outDir = '$folder/Mixdown';
        await Directory(outDir).create();
      }
    } catch (e) {
      for (final entry in entries) {
        statusFor(entry)
          ..phase = EntryPhase.failed
          ..error = 'Mixdown folder: $e';
      }
      running = false;
      notifyListeners();
      return;
    }

    final currentByName = {for (final t in config.tracks) t.name: t};
    final master = _untrimmed(config.master);

    for (final entry in entries) {
      if (_cancelRequested) break;
      current++;
      final st = statusFor(entry)..phase = EntryPhase.rendering;
      notifyListeners();
      if (Saf.isAvailable) {
        await Saf.exportStarted('${entry.name} ($current/$total)');
      }
      try {
        // The file's own session provides the track list (and defaults such
        // as monitor-feed exclusion for never-opened takes)…
        final sessionPath =
            await sessionPathFor(entry.source, displayName: entry.name);
        final info = await rust.loadRecording(
          path: entry.source,
          sessionPath: sessionPath,
          fd: Saf.isContentUri(entry.source)
              ? await Saf.openFd(entry.source)
              : null,
        );
        // …then the current mixer values override wherever a name matches
        // (index fallback), so one mix drives all takes of the session.
        final tracks = [
          for (final t in info.tracks)
            _applied(
                t,
                currentByName[t.name] ??
                    (t.index <= config.tracks.length && config.tracks.isNotEmpty
                        ? config.tracks[t.index - 1]
                        : null)),
        ];

        // User-editable stem from the selection mode; falls back to the
        // original name. Extension follows the chosen format.
        final rawStem = entry.outputStem?.trim() ?? '';
        final stem = _sanitizeStem(
            rawStem.isEmpty ? entry.defaultStem : rawStem, entry.defaultStem);
        final outName = '$stem${extensionFor(config.format)}';
        String outTarget;
        int? outputFd;
        if (isSaf) {
          // SAF providers de-duplicate colliding names themselves.
          outTarget = await Saf.createFileInDirectory(
              outDir, outName, _mime(config.format));
          outputFd = await Saf.openFd(outTarget, mode: 'rwt');
        } else {
          // Match that behaviour on desktop instead of silently overwriting.
          outTarget = '$outDir/$outName';
          var n = 1;
          while (File(outTarget).existsSync()) {
            outTarget = '$outDir/$stem (${n++})${extensionFor(config.format)}';
          }
        }

        var lastPct = -1;
        await for (final ev in rust.renderMix(
          wavPath: entry.source,
          outPath: outTarget,
          tracks: tracks,
          master: master,
          inputFd: Saf.isContentUri(entry.source)
              ? await Saf.openFd(entry.source)
              : null,
          outputFd: outputFd,
        )) {
          st.progress = ev.progress;
          if (Saf.isAvailable) {
            final pct = (ev.progress * 100).round();
            if (pct != lastPct) {
              lastPct = pct;
              unawaited(
                  Saf.exportProgress('${entry.name} ($current/$total)', pct));
            }
          }
          if (ev.report != null) {
            st.integratedLufs = ev.report!.integratedLufs;
          }
          notifyListeners();
        }
        st.phase = EntryPhase.done;
        st.output = outTarget;
        outputs.add(outTarget);
      } catch (e) {
        st
          ..phase = EntryPhase.failed
          ..error = e.toString();
      }
      notifyListeners();
    }

    if (Saf.isAvailable) {
      unawaited(Saf.exportStopped());
    }
    running = false;
    notifyListeners();
  }

  /// Batch renders never trim or fade — those belong to the take they were
  /// set on.
  static rust.ApiMaster _untrimmed(rust.ApiMaster m) => rust.ApiMaster(
        loudness: m.loudness,
        format: m.format,
        limiterEnabled: m.limiterEnabled,
        ceilingDbtp: m.ceilingDbtp,
        dither: m.dither,
        trimStartFrame: BigInt.zero,
        trimEndFrame: null,
        fadeInMs: 0,
        fadeOutMs: 0,
        masteringEnabled: m.masteringEnabled,
        masteringReferencePath: m.masteringReferencePath,
        masteringReferenceName: m.masteringReferenceName,
      );

  static rust.ApiTrack _applied(rust.ApiTrack target, rust.ApiTrack? source) =>
      source == null
          ? target
          : rust.ApiTrack(
              index: target.index,
              name: target.name,
              gainDb: source.gainDb,
              pan: source.pan,
              polarityInvert: source.polarityInvert,
              muted: source.muted,
              solo: source.solo,
              inMix: source.inMix,
              eq: source.eq,
            );

  static String _mime(rust.ApiFormat f) => switch (f) {
        rust.ApiFormat.flac16 || rust.ApiFormat.flac24 => 'audio/flac',
        rust.ApiFormat.mp3 => 'audio/mpeg',
        _ => 'audio/x-wav',
      };

  /// File extension of the chosen output format (also shown as the fixed
  /// suffix of the name editor in the browser's selection mode).
  static String extensionFor(rust.ApiFormat f) => switch (f) {
        rust.ApiFormat.flac16 || rust.ApiFormat.flac24 => '.flac',
        rust.ApiFormat.mp3 => '.mp3',
        _ => '.wav',
      };

  /// Strip filesystem-hostile characters; an emptied-out stem falls back to
  /// the original file name.
  static String _sanitizeStem(String stem, String fallback) {
    final cleaned = stem.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? fallback : cleaned;
  }
}
