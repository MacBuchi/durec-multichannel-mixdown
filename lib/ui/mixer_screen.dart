import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import '../state/mixer_state.dart';
import 'meters.dart';
import 'track_strip.dart';

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

  Future<void> _openFile() async {
    if (Saf.isAvailable) {
      // Android: SAF returns a content URI; the engine reads it through raw
      // fds without ever copying the multi-GB file.
      final uri = await Saf.pickWav();
      if (uri != null) {
        await state.open(uri, name: await Saf.displayName(uri));
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
                  Text(_formatLabels[f]!, style: const TextStyle(fontSize: 13))))
          .toList(),
      onChanged: (f) =>
          f != null ? setDialogState(() => job.format = f) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final rec = state.recording;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              rec == null ? 'DurecMix' : (state.displayName ?? rec.path.split('/').last),
              style: const TextStyle(fontSize: 16),
            ),
            actions: [
              if (rec != null) ...[
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
                if (!Saf.isAvailable)
                  IconButton(
                    tooltip: 'Batch export: render several targets/formats '
                        'into one folder',
                    onPressed: state.rendering ? null : _batchExport,
                    icon: const Icon(Icons.playlist_add_check, size: 20),
                  ),
                const SizedBox(width: 8),
              ],
              if (rec != null)
                for (final slot in ['A', 'B'])
                  Tooltip(
                    message: state.hasSnapshot(slot)
                        ? 'Recall mix snapshot $slot (long-press to overwrite)'
                        : 'Store current mix as snapshot $slot',
                    child: InkWell(
                      onTap: () => state.recallOrStoreSnapshot(slot),
                      onLongPress: () => state.storeSnapshot(slot),
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
                tooltip: 'Open multichannel WAV',
                onPressed: _openFile,
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

  Widget _emptyView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.graphic_eq, size: 64, color: Colors.white24),
          const SizedBox(height: 16),
          Text('Open a DUREC multichannel WAV to start mixing',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _openFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open recording'),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 16),
            Text(state.error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      ),
    );
  }

  Widget _mixerView(rust.RecordingInfo rec) {
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
                  SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2)),
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
    final report = state.lastReport;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.rendering)
                LinearProgressIndicator(value: state.renderProgress),
              if (report != null && !state.rendering)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Exported: ${_fmtLufs(report.integratedLufs)} LUFS-I · '
                    'TP ${report.truePeakDbtp.toStringAsFixed(1)} dBTP · '
                    'LRA ${report.lraLu.toStringAsFixed(1)} LU · '
                    'gain ${report.gainAppliedDb >= 0 ? '+' : ''}${report.gainAppliedDb.toStringAsFixed(1)} dB '
                    '→ ${state.lastOutputPath ?? ''}',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Row(
                children: [
                  IconButton.filled(
                    onPressed: state.togglePlay,
                    icon: Icon(state.playing ? Icons.stop : Icons.play_arrow),
                  ),
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
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()])),
                  Expanded(
                    child: Slider(
                      value: state.positionSeconds
                          .clamp(0, rec.durationSeconds)
                          .toDouble(),
                      max: rec.durationSeconds,
                      onChanged: state.seek,
                    ),
                  ),
                  Text(_fmtTime(rec.durationSeconds),
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()])),
                  const SizedBox(width: 16),
                  StereoPeakMeter(peakL: state.peakL, peakR: state.peakR),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 170,
                    child: Text(
                      state.playing
                          ? '${_fmtLufs(state.lufsMomentary)} LUFS-M · ${_fmtLufs(state.lufsIntegrated)} LUFS-I\n'
                              'TP ${state.truePeak > 0 ? (20 * math.log(state.truePeak) / math.ln10).toStringAsFixed(1) : '−∞'} dBTP · corr ${state.correlation.toStringAsFixed(2)}'
                          : '',
                      style: const TextStyle(fontSize: 10, color: Colors.white54),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loudnessSelector() {
    return Tooltip(
      message: 'Applied on export; preview plays pre-normalisation',
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
        onChanged: (c) async {
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
          .map((f) => DropdownMenuItem(value: f, child: Text(_formatLabels[f]!)))
          .toList(),
      onChanged: (f) => f != null ? state.setFormat(f) : null,
    );
  }
}

const _formatLabels = {
  rust.ApiFormat.wav16: 'WAV 16',
  rust.ApiFormat.wav24: 'WAV 24',
  rust.ApiFormat.wav32Float: 'WAV 32f',
  rust.ApiFormat.flac16: 'FLAC 16',
  rust.ApiFormat.flac24: 'FLAC 24',
  rust.ApiFormat.mp3: 'MP3 320',
};

String _fmtLufs(double v) => v <= -70 ? '−∞' : v.toStringAsFixed(1);

String _fmtTime(double seconds) {
  final s = seconds.clamp(0, double.infinity);
  final m = s ~/ 60;
  final rest = (s - m * 60).floor();
  return '$m:${rest.toString().padLeft(2, '0')}';
}
