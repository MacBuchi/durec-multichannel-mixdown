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
import '../state/mixer_scope.dart';
import '../state/mixer_state.dart';
import '../state/wav_browser.dart';
import 'animated_logo.dart';
import 'app_colors.dart';
import 'app_banners.dart';
import 'dialogs/batch_export_dialog.dart';
import 'dialogs/custom_lufs_dialog.dart';
import 'dialogs/export_report_dialog.dart';
import 'dialogs/mastering_dialog.dart';
import 'dialogs/settings_dialog.dart';
import 'dialogs/target_pickers.dart';
import 'formats.dart';
import 'meters.dart';
import 'track_strip.dart';
import 'wav_browser_page.dart';

class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key});

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  /// Provided by the [MixerScope] above the app — the screen renders it but
  /// does not own it (tests inject their own instance there).
  late MixerState state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    state = MixerScope.of(context);
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
            reference: state.mastering.profile,
          ),
          onPickLoudness: () => pickLoudnessDialog(context, state),
          onPickFormat: () => pickFormatDialog(context, state),
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
      final uri = await Saf.createDocument(state.exporter.suggestedName(), mime);
      if (uri != null) {
        await state.exporter.export(uri);
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
      final tempPath = '${Directory.systemTemp.path}/${state.exporter.suggestedName()}';
      await state.exporter.export(tempPath);
      if (state.error == null) {
        final dest = await IosFiles.exportMove(tempPath);
        if (dest == null) {
          // Cancelled: don't leave a multi-GB orphan in tmp.
          try {
            File(tempPath).deleteSync();
          } catch (_) {
            // Cleanup only — worst case the OS purges tmp itself.
          }
        }
      }
      return;
    }
    final location = await getSaveLocation(suggestedName: state.exporter.suggestedName());
    if (location != null) {
      await state.exporter.export(location.path);
    }
  }

  /// Queue several loudness/format targets of the current mix, then render
  /// them one after another into a single folder. Desktop only for now —
  /// Android would need a SAF directory tree (planned with the phone work).
  Future<void> _batchExport() async {
    if (state.recording == null) return;
    if (state.exporter.batchQueue.isEmpty) state.exporter.addBatchJob();
    final proceed = await showBatchExportDialog(context, state);
    if (proceed != true || state.exporter.batchQueue.isEmpty) return;
    final directory = await getDirectoryPath();
    if (directory != null) {
      await state.exporter.exportBatch(directory);
    }
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
                          Icon(Icons.expand_more,
                              size: 18, color: AppColors.of(context).dim),
                        ],
                      ),
                    ),
                  ),
            actions: narrow ? _narrowActions(rec) : [
              if (rec != null) ...[
                IconButton(
                  tooltip: state.mastering.preview && state.mastering.mixStatsStale
                      ? 'Mastering preview is stale — mix changed since the '
                          'analysis'
                      : state.mastering.enabled
                          ? 'Reference mastering: '
                              '${state.mastering.referenceName}'
                          : 'Reference mastering — match the export to a '
                              'reference track',
                  onPressed: () => showMasteringDialog(context, state),
                  icon: Icon(Icons.auto_fix_high,
                      size: 20,
                      color: state.mastering.preview && state.mastering.mixStatsStale
                          ? AppColors.of(context).warning
                          : state.mastering.enabled
                              ? AppColors.of(context).accent
                              : AppColors.of(context).faint),
                ),
                _loudnessSelector(),
                const SizedBox(width: 8),
                _formatSelector(),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: state.exporter.rendering ? null : _export,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: Text(state.exporter.rendering
                      ? '${state.exporter.batchRunning ? '${state.exporter.batchCurrent}/${state.exporter.batchTotal} · ' : ''}'
                          '${(state.exporter.renderProgress * 100).round()} %'
                      : 'Export'),
                ),
                if (_batchAvailable)
                  IconButton(
                    tooltip: 'Export multiple formats of this mix into one '
                        'folder (all files of the folder: use the browser)',
                    onPressed: state.exporter.rendering ? null : _batchExport,
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
                                    ? AppColors.of(context).accent
                                    : AppColors.of(context).faint,
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
                          ? AppColors.of(context).accent
                          : AppColors.of(context).faint),
                ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => showSettingsDialog(context),
                icon: const Icon(Icons.settings_outlined),
                ),
              // Only once a recording is open: on the start screen the
              // centre button is the single folder affordance (#74).
              if (rec != null)
                IconButton(
                  tooltip: 'Choose recordings folder',
                  onPressed: _changeFolder,
                  icon: const Icon(Icons.folder_open),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              const AppBanners(),
              Expanded(child: rec == null ? _emptyView() : _mixerView(rec)),
            ],
          ),
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
          onPressed: state.exporter.rendering ? null : _export,
          child: Text(state.exporter.rendering
              ? '${state.exporter.batchRunning ? '${state.exporter.batchCurrent}/${state.exporter.batchTotal} · ' : ''}'
                  '${(state.exporter.renderProgress * 100).round()} %'
              : 'Export'),
        ),
      IconButton(
        tooltip: 'Settings',
        onPressed: () => showSettingsDialog(context),
        icon: const Icon(Icons.settings_outlined),
        ),
      // See the wide layout: hidden on the start screen (#74).
      if (rec != null)
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
                await showMasteringDialog(context, state);
              case 'loudness':
                await pickLoudnessDialog(context, state);
              case 'format':
                await pickFormatDialog(context, state);
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
                child: Text(state.mastering.enabled
                    ? 'Mastering: ${state.mastering.referenceName}'
                    : 'Reference mastering…')),
            PopupMenuItem(
                value: 'loudness',
                enabled: !state.mastering.enabled,
                child: Text(state.mastering.enabled
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
              style: TextStyle(color: AppColors.of(context).dim),
            )
          else ...[
            Text('Choose a folder with DUREC recordings',
                style: TextStyle(color: AppColors.of(context).dim)),
            const SizedBox(height: 16),
            // Always asks which folder, rather than silently reopening the
            // remembered one: on the start screen this is the ONLY folder
            // control, and a remembered SAF grant can be dead after an
            // update — which looked like a button that does nothing (#74).
            FilledButton.icon(
              onPressed: _changeFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folder'),
            ),
          ],
          if (state.error != null) ...[
            const SizedBox(height: 16),
            Text(state.error!, style: TextStyle(color: AppColors.of(context).error)),
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
          color: AppColors.scrim,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AnimatedLogo(size: 120, animate: true),
                const SizedBox(height: 8),
                Text(
                  'Loading ${state.displayName ?? 'recording'}…',
                  style: TextStyle(color: AppColors.overlayText),
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
                '${fmtTime(rec.durationSeconds)}'
                '${state.bpm != null ? ' · ${state.bpm!.round()} BPM' : ''}'
                '${state.trimStartSeconds != null || state.trimEndSeconds != null ? ' · trim ${fmtTime(state.trimStartSeconds ?? 0)}–${fmtTime(state.trimEndSeconds ?? rec.durationSeconds)}' : ''}',
                style: TextStyle(fontSize: 12, color: AppColors.of(context).dim),
              ),
              const Spacer(),
              if (state.analyzing)
                Row(children: [
                  // The analysis pass is the one reliably long wait — this
                  // is where the swinging-logo animation actually lives
                  // (opening a file is header-only and over in a blink).
                  AnimatedLogo(size: 26, animate: true, amplitude: 90),
                  SizedBox(width: 6),
                  Text('analysing waveforms…',
                      style: TextStyle(fontSize: 12, color: AppColors.of(context).dim)),
                ]),
              if (state.error != null)
                Flexible(
                  child: Text(state.error!,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: AppColors.of(context).error)),
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
                    StereoPeakMeter(
                        peakL: state.playback.peakL,
                        peakR: state.playback.peakR),
                    const SizedBox(width: 12),
                    Expanded(child: _meterText(oneLine: true)),
                  ],
                ),
              ] else
                Row(
                  children: [
                    ..._transportControls(rec),
                    const SizedBox(width: 16),
                    StereoPeakMeter(
                        peakL: state.playback.peakL,
                        peakR: state.playback.peakR),
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
    final report = state.exporter.lastReport;
    final Widget child;
    if (state.exporter.rendering) {
      child = Center(
        child: LinearProgressIndicator(value: state.exporter.renderProgress),
      );
    } else if (report != null) {
      final summary = _reportSummary(report);
      child = Tooltip(
        message: summary,
        child: InkWell(
          onTap: () => showExportReportDialog(context, state, report),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: AppColors.of(context).dim),
            ),
          ),
        ),
      );
    } else {
      child = const SizedBox.shrink();
    }
    return SizedBox(height: 20, child: child);
  }

  String _reportSummary(rust.ApiRenderReport report) =>
      'Exported: ${fmtLufs(report.integratedLufs)} LUFS-I · '
      'TP ${report.truePeakDbtp.toStringAsFixed(1)} dBTP · '
      'LRA ${report.lraLu.toStringAsFixed(1)} LU · '
      '${report.masteringApplied ? 'matched to ${state.mastering.referenceName} '
          '(${signedDb(report.masteringGainDb)} dB) ' : 'gain ${signedDb(report.gainAppliedDb)} dB '}'
      '→ ${state.exporter.lastOutputPath ?? ''}';

  List<Widget> _transportControls(rust.RecordingInfo rec) {
    return [
      IconButton.filled(
        onPressed: state.playback.togglePlay,
        icon: Icon(state.playback.playing ? Icons.stop : Icons.play_arrow),
      ),
      const SizedBox(width: 6),
      // The logo doubles as the "signal is flowing" light: still when
      // stopped, channels swinging while the mix plays.
      AnimatedLogo(size: 30, animate: state.playback.playing, amplitude: 90),
      const SizedBox(width: 2),
      IconButton(
        tooltip: 'Set trim-in at playhead (long-press to clear)',
        onPressed: () => state.setTrimStart(state.playback.positionSeconds),
        icon: GestureDetector(
          onLongPress: () => state.setTrimStart(null),
          child: Icon(Icons.first_page,
              size: 18,
              color: state.trimStartSeconds != null
                  ? AppColors.of(context).accent
                  : AppColors.of(context).faint),
        ),
      ),
      IconButton(
        tooltip: 'Set trim-out at playhead (long-press to clear)',
        onPressed: () => state.setTrimEnd(state.playback.positionSeconds),
        icon: GestureDetector(
          onLongPress: () => state.setTrimEnd(null),
          child: Icon(Icons.last_page,
              size: 18,
              color: state.trimEndSeconds != null
                  ? AppColors.of(context).accent
                  : AppColors.of(context).faint),
        ),
      ),
      const SizedBox(width: 4),
      Text(fmtTime(state.playback.positionSeconds),
          style:
              const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      Expanded(
        child: Slider(
          value: state.playback.positionSeconds
              .clamp(0, rec.durationSeconds)
              .toDouble(),
          max: rec.durationSeconds,
          onChanged: state.playback.seek,
        ),
      ),
      Text(fmtTime(rec.durationSeconds),
          style:
              const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
    ];
  }

  Widget _meterText({bool oneLine = false}) {
    final tp = state.playback.truePeak > 0
        ? (20 * math.log(state.playback.truePeak) / math.ln10)
            .toStringAsFixed(1)
        : '−∞';
    final separator = oneLine ? ' · ' : '\n';
    return Text(
      state.playback.playing
          ? '${fmtLufs(state.playback.lufsMomentary)} LUFS-M · ${fmtLufs(state.playback.lufsIntegrated)} LUFS-I$separator'
              'TP $tp dBTP · corr ${state.playback.correlation.toStringAsFixed(2)}'
          : '',
      // Never wrap: a second line would change the bar height mid-playback.
      maxLines: oneLine ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 10, color: AppColors.of(context).dim),
    );
  }

  Widget _loudnessSelector() {
    return Tooltip(
      message: state.mastering.enabled
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
        onChanged: state.mastering.enabled
            ? null
            : (c) async {
                if (c == null) return;
                if (c == LoudnessChoice.lufsCustom) {
                  final v = await askCustomLufs(context, state.customLufs);
                  if (v == null) return;
                  state.customLufs = v;
                }
                state.setLoudness(c);
              },
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
