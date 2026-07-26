import 'dart:async';

import '../io/ios_files.dart';
import '../io/platform_shim.dart';
import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'mixer_state.dart';
import 'range_render.dart';

/// Single-file export and the batch queue (several loudness/format targets
/// of the current mix into one folder). Owned and composed by [MixerState],
/// which stays the single rebuild root.
class ExportController {
  ExportController(this._owner);

  final MixerState _owner;

  bool rendering = false;
  double renderProgress = 0;
  rust.ApiRenderReport? lastReport;
  String? lastOutputPath;

  /// Set while a cancellable render is running — only the range renderer can
  /// be stopped, so the UI must not offer it for the others (a cancel button
  /// that does nothing is the dead end this app keeps running into).
  bool _cancellable = false;
  bool _cancelRequested = false;

  /// True when the running export can be stopped.
  bool get canCancel => rendering && _cancellable && !_cancelRequested;

  /// True once cancelling was asked for and the render has not noticed yet —
  /// it stops at the next block boundary, so the button must show that the
  /// press arrived.
  bool get cancelling => rendering && _cancelRequested;

  /// Set when the last export ended because the user cancelled it. Lets the
  /// caller skip the "Export finished" message without treating it as an
  /// error.
  bool lastCancelled = false;

  /// Ask the running render to stop at the next block boundary.
  void cancelExport() {
    if (!canCancel) return;
    _cancelRequested = true;
    _owner.notify();
  }

  /// One queued output: the current mix rendered at this loudness/format.
  /// Starts as a copy of the app-bar selection; editable in the batch dialog.
  final List<BatchJob> batchQueue = [];

  int batchCurrent = 0; // 1-based job being rendered; 0 = no batch running
  int batchTotal = 0;

  bool get batchRunning => batchTotal > 0;

  /// `outTarget` is a filesystem path, or a `content://` URI on Android
  /// (SAF CREATE_DOCUMENT result) written through a raw fd. `masterOverride`
  /// lets batch jobs swap the loudness target / format per render.
  Future<void> export(
    String outTarget, {
    rust.ApiMaster? masterOverride,
  }) async {
    final rec = _owner.recording;
    if (rec == null || rendering) return;
    rendering = true;
    renderProgress = 0;
    lastReport = null;
    _owner.error = null;
    _owner.notify();
    // Keep the render alive if the app is backgrounded mid-export: Android
    // gets a foreground service with a progress notification, iOS a
    // background-task grant. Desktop needs neither.
    final exportName = _owner.displayName ?? outTarget.split('/').last;
    int? iosBgTask;
    try {
      if (Saf.isAvailable) {
        await Saf.exportStarted(exportName);
      }
      if (IosFiles.isAvailable) {
        iosBgTask = await IosFiles.beginBackgroundTask();
      }
      // Resolve the mastering reference first (cache hit is instant; a
      // fresh analysis streams its own progress).
      rust.ApiReferenceProfile? reference;
      if ((masterOverride ?? _owner.master).masteringEnabled) {
        reference = await _owner.mastering.ensureProfile();
        if (reference == null) {
          throw StateError('Mastering is on but no reference track is set');
        }
      }
      final outputFd = Saf.isContentUri(outTarget)
          ? await Saf.openFd(outTarget, mode: 'rwt')
          : null;
      var lastPct = -1;
      await for (final ev in rust.renderMix(
        wavPath: rec.path,
        outPath: outTarget,
        tracks: _owner.tracks.map((t) => t.toApi()).toList(),
        master: masterOverride ?? _owner.master,
        reference: reference,
        inputFd: _owner.isSafSource ? await _owner.inputFdFor(rec.path) : null,
        outputFd: outputFd,
      )) {
        renderProgress = ev.progress;
        if (Saf.isAvailable) {
          final pct = (ev.progress * 100).round();
          if (pct != lastPct) {
            lastPct = pct;
            unawaited(Saf.exportProgress(exportName, pct));
          }
        }
        if (ev.report != null) {
          lastReport = ev.report;
          lastOutputPath = outTarget;
        }
        _owner.notify();
      }
      await _owner.saveSession();
    } catch (e) {
      _owner.error = e.toString();
    } finally {
      if (Saf.isAvailable) unawaited(Saf.exportStopped());
      if (iosBgTask != null) unawaited(IosFiles.endBackgroundTask(iosBgTask));
    }
    rendering = false;
    _owner.notify();
  }

  /// Render a take that has no path — the browser's `Blob` source — and hand
  /// the result to the platform (a download).
  ///
  /// Same two-pass render as [export]; only the source and the destination
  /// differ, and both live behind [renderByRanges] / [RenderOutput].
  Future<void> exportByRanges(String filename) async {
    final read = _owner.sourceReader;
    if (read == null || rendering) return;
    final size = _owner.sourceSize;
    rendering = true;
    _cancellable = true;
    _cancelRequested = false;
    lastCancelled = false;
    renderProgress = 0;
    lastReport = null;
    _owner.error = null;
    _owner.notify();
    try {
      rust.ApiReferenceProfile? reference;
      if (_owner.master.masteringEnabled) {
        reference = await _owner.mastering.ensureProfile();
        if (reference == null) {
          throw StateError('Mastering is on but no reference track is set');
        }
      }
      lastReport = await renderByRanges(
        read,
        size,
        tracks: _owner.tracks.map((t) => t.toApi()).toList(),
        master: _owner.master,
        reference: reference,
        output: createDownloadOutput(filename),
        onProgress: (p) {
          renderProgress = p;
          _owner.notify();
        },
        cancelled: () => _cancelRequested,
      );
      lastOutputPath = filename;
      await _owner.saveSession();
    } on RenderCancelled {
      // A cancelled export is a finished job, not a failure: no error banner,
      // and no half-written file either — the blob parts are simply dropped
      // and `complete()` never runs, so no download is offered.
      lastCancelled = true;
    } catch (e) {
      _owner.error = e.toString();
    }
    rendering = false;
    _cancellable = false;
    _cancelRequested = false;
    renderProgress = 0;
    _owner.notify();
  }

  void addBatchJob() {
    batchQueue.add(
      BatchJob(
        loudness: _owner.loudness,
        customLufs: _owner.customLufs,
        format: _owner.format,
      ),
    );
    _owner.notify();
  }

  void removeBatchJob(BatchJob job) {
    batchQueue.remove(job);
    _owner.notify();
  }

  /// Render every queued job into `directory`, sequentially (the engine is
  /// two-pass and I/O-bound — parallel renders of a multi-GB source would
  /// just fight over the disk). Stops on the first failing job.
  Future<void> exportBatch(String directory) async {
    if (_owner.recording == null || rendering || batchQueue.isEmpty) return;
    batchTotal = batchQueue.length;
    for (var i = 0; i < batchQueue.length; i++) {
      batchCurrent = i + 1;
      _owner.notify();
      final job = batchQueue[i];
      final name = suggestedName(
        loudness: job.loudness,
        customLufs: job.customLufs,
        format: job.format,
      );
      await export(
        '$directory/$name',
        masterOverride: _owner.masterFor(
          loudness: job.loudness,
          customLufs: job.customLufs,
          format: job.format,
        ),
      );
      if (_owner.error != null) break;
    }
    lastOutputPath = directory;
    batchCurrent = 0;
    batchTotal = 0;
    _owner.notify();
  }

  /// Suggested output name matching the Python tool's pattern:
  /// `<take>_<target>_<bpm>BPM_<yyyyMMdd_HHmmss>.<ext>`. Defaults to the
  /// current app-bar selection; batch jobs pass their own target/format.
  String suggestedName({
    LoudnessChoice? loudness,
    double? customLufs,
    rust.ApiFormat? format,
  }) => suggestedExportName(
    baseName: _owner.displayName ?? _owner.recording!.path.split('/').last,
    loudness: loudness ?? _owner.loudness,
    customLufs: customLufs ?? _owner.customLufs,
    format: format ?? _owner.format,
    bpm: _owner.bpm,
  );
}
