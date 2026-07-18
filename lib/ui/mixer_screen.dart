import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../io/ios_files.dart';
import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import '../state/app_settings.dart';
import '../state/batch_export.dart';
import '../state/mixer_state.dart';
import '../state/wav_browser.dart';
import 'animated_logo.dart';
import 'meters.dart';
import 'track_strip.dart';
import 'wav_browser_page.dart';

class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key});

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  final MixerState state = MixerState();

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  WavBrowser? _browser;

  /// Default open flow: the in-app WAV browser (Android + desktop). iOS
  /// keeps the system picker until folder access lands there.
  Future<void> _openFile() =>
      IosFiles.isAvailable ? _openSystemPicker() : _openBrowser();

  Future<void> _openBrowser() async {
    final settings = await AppSettings.load();
    final browser = _browser ??= WavBrowser(settings);
    if (browser.folder == null) {
      final last = settings.lastFolder;
      if (last != null) {
        // Fire and forget: the page renders the listing as it arrives. A
        // stale grant (e.g. macOS sandbox after relaunch) surfaces as an
        // in-page error with a "choose folder" button.
        unawaited(browser.openFolder(last));
      } else {
        final picked = await browser.pickFolder();
        if (picked == null) return;
        unawaited(browser.openFolder(picked));
      }
    }
    await _showBrowser(browser);
  }

  /// App-bar folder icon: switch the target folder directly, then browse it.
  /// (The title tap keeps the current folder — that's "switch file".)
  Future<void> _changeFolder() async {
    if (IosFiles.isAvailable) {
      await _openSystemPicker();
      return;
    }
    final settings = await AppSettings.load();
    final browser = _browser ??= WavBrowser(settings);
    final picked = await browser.pickFolder();
    if (picked == null) return;
    unawaited(browser.openFolder(picked));
    await _showBrowser(browser);
  }

  Future<void> _showBrowser(WavBrowser browser) async {
    if (!mounted) return;
    final result = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
        builder: (_) => WavBrowserPage(
          browser: browser,
          currentSource: state.recording?.path,
          // Captured on export tap: the current mix drives every take
          // (mapped by track name); loudness/format from the app bar.
          exportConfig: () => MultiExportConfig(
            tracks: state.tracks.map((t) => t.toApi()).toList(),
            master: state.master,
            loudness: state.loudness,
            customLufs: state.customLufs,
            format: state.format,
            // Analyzed when the reference was chosen; cache-restored on
            // app restart the first time an export runs.
            reference: state.referenceProfile,
          ),
          onPickLoudness: _pickLoudnessDialog,
          onPickFormat: _pickFormatDialog,
        ),
      ),
    );
    if (result is WavEntry) {
      await state.open(result.source, name: result.name);
    } else if (result == useSystemPicker) {
      await _openSystemPicker();
    }
  }

  Future<void> _openSystemPicker() async {
    if (Saf.isAvailable) {
      // Android: SAF returns a content URI; the engine reads it through raw
      // fds without ever copying the multi-GB file.
      final uri = await Saf.pickWav();
      if (uri != null) {
        await state.open(uri, name: await Saf.displayName(uri));
      }
      return;
    }
    if (IosFiles.isAvailable) {
      // iOS: picked in place under a session-long security scope — the
      // engine then reads the file by path, again without copying.
      final path = await IosFiles.pickWav();
      if (path != null) {
        await state.open(path);
      }
      return;
    }
    const group = XTypeGroup(label: 'WAV recordings', extensions: ['wav', 'WAV']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file != null) {
      await state.open(file.path);
    }
  }

  Future<void> _export() async {
    if (state.recording == null) return;
    if (Saf.isAvailable) {
      final mime = switch (state.format) {
        rust.ApiFormat.flac16 || rust.ApiFormat.flac24 => 'audio/flac',
        rust.ApiFormat.mp3 => 'audio/mpeg',
        _ => 'audio/x-wav',
      };
      final uri = await Saf.createDocument(state.suggestedName(), mime);
      if (uri != null) {
        await state.export(uri);
        if (state.error == null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Export finished'),
            action: SnackBarAction(
              label: 'Share',
              onPressed: () => Saf.shareFiles([uri]),
            ),
          ));
        }
      }
      return;
    }
    if (IosFiles.isAvailable) {
      // iOS: render into tmp, then let the export picker move the finished
      // file wherever the user chooses (Files, iCloud, USB drive).
      final tempPath = '${Directory.systemTemp.path}/${state.suggestedName()}';
      await state.export(tempPath);
      if (state.error == null) {
        final dest = await IosFiles.exportMove(tempPath);
        if (dest == null) {
          // Cancelled: don't leave a multi-GB orphan in tmp.
          try {
            File(tempPath).deleteSync();
          } catch (_) {}
        }
      }
      return;
    }
    final location = await getSaveLocation(suggestedName: state.suggestedName());
    if (location != null) {
      await state.export(location.path);
    }
  }

  /// Queue several loudness/format targets of the current mix, then render
  /// them one after another into a single folder. Desktop only for now —
  /// Android would need a SAF directory tree (planned with the phone work).
  Future<void> _batchExport() async {
    if (state.recording == null) return;
    if (state.batchQueue.isEmpty) state.addBatchJob();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Batch export'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Each job renders the current mix at its own loudness '
                    'target and format, auto-named into one folder.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 8),
                for (final job in List.of(state.batchQueue))
                  Row(
                    children: [
                      Expanded(child: _jobLoudnessDropdown(job, setDialogState)),
                      const SizedBox(width: 8),
                      _jobFormatDropdown(job, setDialogState),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 18),
                        onPressed: () =>
                            setDialogState(() => state.removeBatchJob(job)),
                      ),
                    ],
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setDialogState(state.addBatchJob),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add job'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: state.batchQueue.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Export all…'),
            ),
          ],
        ),
      ),
    );
    if (proceed != true || state.batchQueue.isEmpty) return;
    final directory = await getDirectoryPath();
    if (directory != null) {
      await state.exportBatch(directory);
    }
  }

  Widget _jobLoudnessDropdown(BatchJob job, StateSetter setDialogState) {
    return DropdownButton<LoudnessChoice>(
      value: job.loudness,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: LoudnessChoice.values
          .map((c) => DropdownMenuItem(
              value: c,
              child: Text(
                  c == LoudnessChoice.lufsCustom && job.loudness == c
                      ? '${job.customLufs.toStringAsFixed(1)} LUFS'
                      : c.label,
                  style: const TextStyle(fontSize: 13))))
          .toList(),
      onChanged: (c) async {
        if (c == null) return;
        if (c == LoudnessChoice.lufsCustom) {
          final v = await _askCustomLufs();
          if (v == null) return;
          job.customLufs = v;
        }
        setDialogState(() => job.loudness = c);
      },
    );
  }

  Widget _jobFormatDropdown(BatchJob job, StateSetter setDialogState) {
    return DropdownButton<rust.ApiFormat>(
      value: job.format,
      underline: const SizedBox.shrink(),
      items: rust.ApiFormat.values
          .map((f) => DropdownMenuItem(
              value: f,
              child:
                  Text(formatLabels[f]!, style: const TextStyle(fontSize: 13))))
          .toList(),
      onChanged: (f) =>
          f != null ? setDialogState(() => job.format = f) : null,
    );
  }

  /// Batch export needs a directory picker, which file_selector only
  /// implements on desktop; phones export one file at a time.
  bool get _batchAvailable => !Platform.isAndroid && !Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 640;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final rec = state.recording;
        return Scaffold(
          appBar: AppBar(
            // Tapping the loaded file's name reopens the browser — the fast
            // path for switching between takes of the same folder.
            title: rec == null
                ? const Text('DurecMix', style: TextStyle(fontSize: 16))
                : Tooltip(
                    message: 'Switch recording',
                    child: InkWell(
                      onTap: _openFile,
                      borderRadius: BorderRadius.circular(4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              state.displayName ?? rec.path.split('/').last,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.expand_more,
                              size: 18, color: Colors.white54),
                        ],
                      ),
                    ),
                  ),
            actions: narrow ? _narrowActions(rec) : [
              if (rec != null) ...[
                IconButton(
                  tooltip: state.masteringPreview && state.mixStatsStale
                      ? 'Mastering preview is stale — mix changed since the '
                          'analysis'
                      : state.masteringEnabled
                          ? 'Reference mastering: '
                              '${state.masteringReferenceName}'
                          : 'Reference mastering — match the export to a '
                              'reference track',
                  onPressed: _masteringDialog,
                  icon: Icon(Icons.auto_fix_high,
                      size: 20,
                      color: state.masteringPreview && state.mixStatsStale
                          ? Colors.amberAccent
                          : state.masteringEnabled
                              ? Colors.lightBlueAccent
                              : Colors.white38),
                ),
                _loudnessSelector(),
                const SizedBox(width: 8),
                _formatSelector(),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: state.rendering ? null : _export,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: Text(state.rendering
                      ? '${state.batchRunning ? '${state.batchCurrent}/${state.batchTotal} · ' : ''}'
                          '${(state.renderProgress * 100).round()} %'
                      : 'Export'),
                ),
                if (_batchAvailable)
                  IconButton(
                    tooltip: 'Export multiple formats of this mix into one '
                        'folder (all files of the folder: use the browser)',
                    onPressed: state.rendering ? null : _batchExport,
                    icon: const Icon(Icons.playlist_add_check, size: 20),
                  ),
                const SizedBox(width: 8),
              ],
              if (rec != null)
                for (final slot in ['A', 'B'])
                  Tooltip(
                    message: state.hasSnapshot(slot)
                        ? 'Recall mix snapshot $slot — long-press or '
                            'right-click to overwrite'
                        : 'Store current mix as snapshot $slot',
                    // Manual trigger: the default long-press trigger steals
                    // the gesture from onLongPress below, making overwrite
                    // impossible. Hover still shows the tooltip.
                    triggerMode: TooltipTriggerMode.manual,
                    child: GestureDetector(
                      onSecondaryTap: () => _storeSnapshot(slot),
                      child: InkWell(
                        onTap: () => _tapSnapshot(slot),
                        onLongPress: () => _storeSnapshot(slot),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(slot,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: state.hasSnapshot(slot)
                                    ? Colors.lightBlueAccent
                                    : Colors.white38,
                              )),
                        ),
                      ),
                    ),
                  ),
              if (rec != null)
                IconButton(
                  tooltip: 'Link stereo pairs (·L/·R): mirrored pans, shared '
                      'gain/mute/solo/EQ',
                  onPressed: state.toggleLinkPairs,
                  icon: Icon(Icons.link,
                      size: 20,
                      color: state.linkPairs
                          ? Colors.lightBlueAccent
                          : Colors.white38),
                ),
              IconButton(
                tooltip: 'Choose recordings folder',
                onPressed: _changeFolder,
                icon: const Icon(Icons.folder_open),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: rec == null ? _emptyView() : _mixerView(rec),
          bottomNavigationBar: rec == null ? null : _transportBar(rec),
        );
      },
    );
  }

  /// Phone app bar: Export + open stay visible, everything else moves into
  /// an overflow menu (the wide bar's selectors don't fit a phone width).
  List<Widget> _narrowActions(rust.RecordingInfo? rec) {
    return [
      if (rec != null)
        FilledButton(
          onPressed: state.rendering ? null : _export,
          child: Text(state.rendering
              ? '${state.batchRunning ? '${state.batchCurrent}/${state.batchTotal} · ' : ''}'
                  '${(state.renderProgress * 100).round()} %'
              : 'Export'),
        ),
      IconButton(
        tooltip: 'Choose recordings folder',
        onPressed: _changeFolder,
        icon: const Icon(Icons.folder_open),
      ),
      if (rec != null)
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'mastering':
                await _masteringDialog();
              case 'loudness':
                await _pickLoudnessDialog();
              case 'format':
                await _pickFormatDialog();
              case 'batch':
                await _batchExport();
              case 'snapA':
                _tapSnapshot('A');
              case 'snapB':
                _tapSnapshot('B');
              case 'storeA':
                _storeSnapshot('A');
              case 'storeB':
                _storeSnapshot('B');
              case 'link':
                state.toggleLinkPairs();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
                value: 'mastering',
                child: Text(state.masteringEnabled
                    ? 'Mastering: ${state.masteringReferenceName}'
                    : 'Reference mastering…')),
            PopupMenuItem(
                value: 'loudness',
                enabled: !state.masteringEnabled,
                child: Text(state.masteringEnabled
                    ? 'Loudness: follows reference'
                    : 'Loudness: ${state.loudness == LoudnessChoice.lufsCustom ? '${state.customLufs.toStringAsFixed(1)} LUFS' : state.loudness.label}')),
            PopupMenuItem(
                value: 'format',
                child: Text('Format: ${formatLabels[state.format]}')),
            if (_batchAvailable)
              const PopupMenuItem(value: 'batch', child: Text('Batch export…')),
            for (final slot in ['A', 'B']) ...[
              PopupMenuItem(
                  value: 'snap$slot',
                  child: Text(state.hasSnapshot(slot)
                      ? 'Recall mix snapshot $slot'
                      : 'Store mix snapshot $slot')),
              if (state.hasSnapshot(slot))
                PopupMenuItem(
                    value: 'store$slot',
                    child: Text('Overwrite mix snapshot $slot')),
            ],
            CheckedPopupMenuItem(
                value: 'link',
                checked: state.linkPairs,
                child: const Text('Link stereo pairs')),
          ],
        ),
    ];
  }

  /// Tap: store into an empty slot, recall from a filled one. The absence of
  /// visible feedback made storing look broken, hence the snack bar.
  void _tapSnapshot(String slot) {
    final existed = state.hasSnapshot(slot);
    state.recallOrStoreSnapshot(slot);
    _snack(existed ? 'Mix snapshot $slot recalled' : 'Mix snapshot $slot stored');
  }

  /// Overwrite unconditionally (long-press / right-click / menu entry).
  void _storeSnapshot(String slot) {
    state.storeSnapshot(slot);
    _snack('Mix snapshot $slot stored');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        width: 280,
      ));
  }

  Future<void> _pickLoudnessDialog() async {
    final choice = await showDialog<LoudnessChoice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Loudness target'),
        children: [
          for (final c in LoudnessChoice.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c),
              child: Text(
                c == LoudnessChoice.lufsCustom &&
                        state.loudness == LoudnessChoice.lufsCustom
                    ? '${state.customLufs.toStringAsFixed(1)} LUFS'
                    : c.label,
                style: TextStyle(
                  fontWeight:
                      c == state.loudness ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == LoudnessChoice.lufsCustom) {
      final v = await _askCustomLufs();
      if (v == null) return;
      state.customLufs = v;
    }
    state.setLoudness(choice);
  }

  Future<void> _pickFormatDialog() async {
    final choice = await showDialog<rust.ApiFormat>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Export format'),
        children: [
          for (final f in rust.ApiFormat.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(f),
              child: Text(
                formatLabels[f]!,
                style: TextStyle(
                  fontWeight:
                      f == state.format ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
        ],
      ),
    );
    if (choice != null) state.setFormat(choice);
  }

  /// The main window's empty track area doubles as the start screen: the
  /// logo (animated while a file loads) and a tappable folder affordance.
  Widget _emptyView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedLogo(size: 160, animate: state.opening),
          const SizedBox(height: 8),
          if (state.opening)
            Text(
              'Loading ${state.displayName ?? 'recording'}…',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            )
          else ...[
            Text('Choose a folder with DUREC recordings',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folder'),
            ),
          ],
          if (state.error != null) ...[
            const SizedBox(height: 16),
            Text(state.error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      ),
    );
  }

  Widget _mixerView(rust.RecordingInfo rec) {
    final content = _mixerContent(rec);
    if (!state.opening) return content;
    // Switching takes: dim the stale mix and swing the logo until the new
    // file's tracks land (multi-GB over USB takes a moment).
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        ColoredBox(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AnimatedLogo(size: 120, animate: true),
                const SizedBox(height: 8),
                Text(
                  'Loading ${state.displayName ?? 'recording'}…',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _mixerContent(rust.RecordingInfo rec) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Text(
                '${rec.channels} ch · ${rec.sampleRate} Hz · ${rec.bitsPerSample}-bit · '
                '${_fmtTime(rec.durationSeconds)}'
                '${state.bpm != null ? ' · ${state.bpm!.round()} BPM' : ''}'
                '${state.trimStartSeconds != null || state.trimEndSeconds != null ? ' · trim ${_fmtTime(state.trimStartSeconds ?? 0)}–${_fmtTime(state.trimEndSeconds ?? rec.durationSeconds)}' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
              const Spacer(),
              if (state.analyzing)
                const Row(children: [
                  // The analysis pass is the one reliably long wait — this
                  // is where the swinging-logo animation actually lives
                  // (opening a file is header-only and over in a blink).
                  AnimatedLogo(size: 26, animate: true, amplitude: 90),
                  SizedBox(width: 6),
                  Text('analysing waveforms…',
                      style: TextStyle(fontSize: 12, color: Colors.white54)),
                ]),
              if (state.error != null)
                Flexible(
                  child: Text(state.error!,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.redAccent)),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: state.tracks.length,
            itemBuilder: (context, i) {
              final t = state.tracks[i];
              final waves = state.waveforms;
              return TrackStrip(
                state: state,
                track: t,
                waveform: waves != null && t.index - 1 < waves.length
                    ? waves[t.index - 1]
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _transportBar(rust.RecordingInfo rec) {
    // Every row is always present so the bar NEVER changes height — it used
    // to wobble on phones whenever playback or an export started/stopped.
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _statusSlot(),
              // Phones get the meters on their own line; the single wide row
              // otherwise overflows and squeezes the seek slider unusably.
              if (MediaQuery.sizeOf(context).width < 640) ...[
                Row(children: _transportControls(rec)),
                Row(
                  children: [
                    StereoPeakMeter(peakL: state.peakL, peakR: state.peakR),
                    const SizedBox(width: 12),
                    Expanded(child: _meterText(oneLine: true)),
                  ],
                ),
              ] else
                Row(
                  children: [
                    ..._transportControls(rec),
                    const SizedBox(width: 16),
                    StereoPeakMeter(peakL: state.peakL, peakR: state.peakR),
                    const SizedBox(width: 12),
                    SizedBox(width: 170, child: _meterText()),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fixed-height status line above the transport: export progress while
  /// rendering, otherwise the last report (single line — hover shows the
  /// full text, tapping opens the detail dialog, which is the phone's
  /// hover replacement), otherwise blank.
  Widget _statusSlot() {
    final report = state.lastReport;
    final Widget child;
    if (state.rendering) {
      child = Center(
        child: LinearProgressIndicator(value: state.renderProgress),
      );
    } else if (report != null) {
      final summary = _reportSummary(report);
      child = Tooltip(
        message: summary,
        child: InkWell(
          onTap: () => _showReportDialog(report),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        ),
      );
    } else {
      child = const SizedBox.shrink();
    }
    return SizedBox(height: 20, child: child);
  }

  String _signedDb(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}';

  String _reportSummary(rust.ApiRenderReport report) =>
      'Exported: ${_fmtLufs(report.integratedLufs)} LUFS-I · '
      'TP ${report.truePeakDbtp.toStringAsFixed(1)} dBTP · '
      'LRA ${report.lraLu.toStringAsFixed(1)} LU · '
      '${report.masteringApplied ? 'matched to ${state.masteringReferenceName} '
          '(${_signedDb(report.masteringGainDb)} dB) ' : 'gain ${_signedDb(report.gainAppliedDb)} dB '}'
      '→ ${state.lastOutputPath ?? ''}';

  void _showReportDialog(rust.ApiRenderReport report) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Last export'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _reportRow('Loudness', '${_fmtLufs(report.integratedLufs)} LUFS-I'),
            _reportRow(
                'True peak', '${report.truePeakDbtp.toStringAsFixed(2)} dBTP'),
            _reportRow(
                'Loudness range', '${report.lraLu.toStringAsFixed(1)} LU'),
            if (report.masteringApplied)
              _reportRow(
                  'Mastering',
                  'matched to ${state.masteringReferenceName} '
                      '(${_signedDb(report.masteringGainDb)} dB)')
            else
              _reportRow('Gain', '${_signedDb(report.gainAppliedDb)} dB'),
            _reportRow('Source loudness',
                '${_fmtLufs(report.sourceIntegratedLufs)} LUFS-I'),
            _reportRow('Duration', _fmtTime(report.durationSeconds)),
            const SizedBox(height: 8),
            SelectableText(
              state.lastOutputPath ?? '',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _reportRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 130,
              child: Text(label,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white54)),
            ),
            Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );

  List<Widget> _transportControls(rust.RecordingInfo rec) {
    return [
      IconButton.filled(
        onPressed: state.togglePlay,
        icon: Icon(state.playing ? Icons.stop : Icons.play_arrow),
      ),
      const SizedBox(width: 6),
      // The logo doubles as the "signal is flowing" light: still when
      // stopped, channels swinging while the mix plays.
      AnimatedLogo(size: 30, animate: state.playing, amplitude: 90),
      const SizedBox(width: 2),
      IconButton(
        tooltip: 'Set trim-in at playhead (long-press to clear)',
        onPressed: () => state.setTrimStart(state.positionSeconds),
        icon: GestureDetector(
          onLongPress: () => state.setTrimStart(null),
          child: Icon(Icons.first_page,
              size: 18,
              color: state.trimStartSeconds != null
                  ? Colors.lightBlueAccent
                  : Colors.white38),
        ),
      ),
      IconButton(
        tooltip: 'Set trim-out at playhead (long-press to clear)',
        onPressed: () => state.setTrimEnd(state.positionSeconds),
        icon: GestureDetector(
          onLongPress: () => state.setTrimEnd(null),
          child: Icon(Icons.last_page,
              size: 18,
              color: state.trimEndSeconds != null
                  ? Colors.lightBlueAccent
                  : Colors.white38),
        ),
      ),
      const SizedBox(width: 4),
      Text(_fmtTime(state.positionSeconds),
          style:
              const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      Expanded(
        child: Slider(
          value:
              state.positionSeconds.clamp(0, rec.durationSeconds).toDouble(),
          max: rec.durationSeconds,
          onChanged: state.seek,
        ),
      ),
      Text(_fmtTime(rec.durationSeconds),
          style:
              const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
    ];
  }

  Widget _meterText({bool oneLine = false}) {
    final tp = state.truePeak > 0
        ? (20 * math.log(state.truePeak) / math.ln10).toStringAsFixed(1)
        : '−∞';
    final separator = oneLine ? ' · ' : '\n';
    return Text(
      state.playing
          ? '${_fmtLufs(state.lufsMomentary)} LUFS-M · ${_fmtLufs(state.lufsIntegrated)} LUFS-I$separator'
              'TP $tp dBTP · corr ${state.correlation.toStringAsFixed(2)}'
          : '',
      // Never wrap: a second line would change the bar height mid-playback.
      maxLines: oneLine ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 10, color: Colors.white54),
    );
  }

  Widget _loudnessSelector() {
    return Tooltip(
      message: state.masteringEnabled
          ? 'Level follows the mastering reference'
          : 'Applied on export; preview plays pre-normalisation',
      child: DropdownButton<LoudnessChoice>(
        value: state.loudness,
        underline: const SizedBox.shrink(),
        items: LoudnessChoice.values
            .map((c) => DropdownMenuItem(
                value: c,
                child: Text(c == LoudnessChoice.lufsCustom &&
                        state.loudness == LoudnessChoice.lufsCustom
                    ? '${state.customLufs.toStringAsFixed(1)} LUFS'
                    : c.label)))
            .toList(),
        // Greyed out while mastering: the reference owns the level.
        onChanged: state.masteringEnabled
            ? null
            : (c) async {
                if (c == null) return;
                if (c == LoudnessChoice.lufsCustom) {
                  final v = await _askCustomLufs();
                  if (v == null) return;
                  state.customLufs = v;
                }
                state.setLoudness(c);
              },
      ),
    );
  }

  // ── reference mastering ─────────────────────────────────────────────────

  Future<void> _masteringDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reference mastering'),
        content: SizedBox(
          width: 400,
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final profile = state.referenceProfile;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Matches the export to a reference track: loudness, tone '
                    '(matching EQ) and stereo width. The loudness target is '
                    'ignored while active; the true-peak limiter stays on.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Master to reference'),
                    value: state.masteringEnabled,
                    onChanged: state.masteringReferencePath.isEmpty
                        ? null
                        : state.setMasteringEnabled,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.library_music, size: 20),
                    title: Text(
                      state.masteringReferenceName.isEmpty
                          ? 'No reference chosen'
                          : state.masteringReferenceName,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: profile == null
                        ? null
                        : Text(
                            '${_fmtDuration(profile.durationSeconds)}'
                            '${profile.sideRms < profile.midRms * 1e-4 ? ' · mono (width kept from mix)' : ''}',
                            style: const TextStyle(fontSize: 11),
                          ),
                    trailing: TextButton(
                      onPressed:
                          state.analyzingReference ? null : _pickReference,
                      child: const Text('Choose…'),
                    ),
                  ),
                  if (state.analyzingReference) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                        value: state.referenceProgress > 0
                            ? state.referenceProgress
                            : null),
                    const SizedBox(height: 4),
                    const Text('Analyzing reference…',
                        style:
                            TextStyle(fontSize: 11, color: Colors.white54)),
                  ],
                  const Divider(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Preview mastered playback'),
                    subtitle: const Text(
                      'Analyzes the current mix once; meters then show the '
                      'mastered signal',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: state.masteringPreview,
                    onChanged: !state.masteringEnabled || state.analyzingMix
                        ? null
                        : (v) => v
                            ? _enableMasteringPreview()
                            : state.disableMasteringPreview(),
                  ),
                  if (state.analyzingMix) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                        value: state.mixAnalysisProgress > 0
                            ? state.mixAnalysisProgress
                            : null),
                    const SizedBox(height: 4),
                    const Text('Analyzing mix…',
                        style:
                            TextStyle(fontSize: 11, color: Colors.white54)),
                  ],
                  if (state.masteringPreview && state.mixStatsStale)
                    Row(
                      children: [
                        const Icon(Icons.warning_amber,
                            size: 16, color: Colors.amberAccent),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'Mix changed — preview uses the old analysis',
                            style: TextStyle(
                                fontSize: 11, color: Colors.amberAccent),
                          ),
                        ),
                        TextButton(
                          onPressed: state.analyzingMix
                              ? null
                              : _refreshMasteringPreview,
                          child: const Text('Refresh'),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickReference() async {
    String? path;
    String? name;
    if (Saf.isAvailable) {
      path = await Saf.pickAudio();
      if (path != null) name = await Saf.displayName(path);
    } else if (IosFiles.isAvailable) {
      path = await IosFiles.pickAudio();
    } else {
      const group = XTypeGroup(
          label: 'Audio',
          extensions: ['wav', 'flac', 'mp3', 'ogg', 'WAV', 'FLAC', 'MP3']);
      final file = await openFile(acceptedTypeGroups: [group]);
      path = file?.path;
      name = file?.name;
    }
    if (path == null) return;
    try {
      await state.chooseReference(path, name ?? path.split('/').last);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reference analysis failed: $e')));
    }
  }

  Future<void> _enableMasteringPreview() async {
    try {
      await state.enableMasteringPreview();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Mix analysis failed: $e')));
    }
  }

  Future<void> _refreshMasteringPreview() async {
    try {
      await state.refreshMasteringPreview();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Mix analysis failed: $e')));
    }
  }

  String _fmtDuration(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).round();
    return '$m:${s.toString().padLeft(2, '0')} min';
  }

  Future<double?> _askCustomLufs() async {
    final controller =
        TextEditingController(text: state.customLufs.toStringAsFixed(1));
    return showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom LUFS target'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(signed: true, decimal: true),
          decoration: const InputDecoration(
            labelText: 'Integrated loudness (−30 … −6 LUFS)',
          ),
          onSubmitted: (_) => Navigator.of(context)
              .pop(double.tryParse(controller.text)?.clamp(-30.0, -6.0)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(double.tryParse(controller.text)?.clamp(-30.0, -6.0)),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _formatSelector() {
    return DropdownButton<rust.ApiFormat>(
      value: state.format,
      underline: const SizedBox.shrink(),
      items: rust.ApiFormat.values
          .map((f) => DropdownMenuItem(value: f, child: Text(formatLabels[f]!)))
          .toList(),
      onChanged: (f) => f != null ? state.setFormat(f) : null,
    );
  }
}



String _fmtLufs(double v) => v <= -70 ? '−∞' : v.toStringAsFixed(1);

String _fmtTime(double seconds) {
  final s = seconds.clamp(0, double.infinity);
  final m = s ~/ 60;
  final rest = (s - m * 60).floor();
  return '$m:${rest.toString().padLeft(2, '0')}';
}
