import 'package:flutter/material.dart';

import '../state/wav_browser.dart';

/// Returned from the browser when the user wants the OS picker instead
/// (one-off files outside any folder).
const useSystemPicker = 'use-system-picker';

/// Full-screen WAV browser: the folder's .wav files, annotated lazily with
/// probed metadata (channels · rate · bits · duration · iXML tracks) so
/// DUREC takes are distinguishable at a glance. Pops the tapped [WavEntry].
class WavBrowserPage extends StatefulWidget {
  const WavBrowserPage({super.key, required this.browser, this.currentSource});

  final WavBrowser browser;

  /// Source of the currently loaded recording (gets the check mark).
  final String? currentSource;

  @override
  State<WavBrowserPage> createState() => _WavBrowserPageState();
}

class _WavBrowserPageState extends State<WavBrowserPage> {
  @override
  void dispose() {
    widget.browser.cancel();
    super.dispose();
  }

  Future<void> _changeFolder() async {
    final picked = await widget.browser.pickFolder();
    if (picked != null) {
      await widget.browser.openFolder(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.browser;
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(
            b.folderName == null ? 'Open recording' : b.folderName!,
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            IconButton(
              tooltip: b.sortByDate ? 'Sorted newest first' : 'Sorted by name',
              onPressed: b.toggleSort,
              icon: Icon(
                b.sortByDate ? Icons.schedule : Icons.sort_by_alpha,
                size: 20,
              ),
            ),
            IconButton(
              tooltip: 'Choose a different folder',
              onPressed: _changeFolder,
              icon: const Icon(Icons.drive_folder_upload, size: 20),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => Navigator.of(context).pop(v),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: useSystemPicker,
                  child: Text('Use system picker…'),
                ),
              ],
            ),
          ],
        ),
        body: _body(b),
      ),
    );
  }

  Widget _body(WavBrowser b) {
    if (b.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(b.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _changeFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folder'),
            ),
          ],
        ),
      );
    }
    if (b.folder == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: _changeFolder,
          icon: const Icon(Icons.folder_open),
          label: const Text('Choose folder'),
        ),
      );
    }
    if (b.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (b.entries.isEmpty) {
      return const Center(
        child: Text('No .wav files in this folder',
            style: TextStyle(color: Colors.white54)),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.builder(
          itemCount: b.entries.length,
          itemBuilder: (context, i) => _row(b.entries[i]),
        ),
      ),
    );
  }

  Widget _row(WavEntry e) {
    final isCurrent = e.source == widget.currentSource;
    return ListTile(
      enabled: e.probeError == null,
      leading: Icon(
        isCurrent ? Icons.check_circle : Icons.graphic_eq,
        color: isCurrent ? Colors.lightBlueAccent : Colors.white38,
        size: 22,
      ),
      title: Text(
        e.name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: isCurrent ? Colors.lightBlueAccent : null,
        ),
      ),
      subtitle: _subtitle(e),
      onTap: () => Navigator.of(context).pop(e),
    );
  }

  Widget _subtitle(WavEntry e) {
    if (e.probeError != null) {
      return Text('Not readable as WAV',
          style: TextStyle(fontSize: 12, color: Colors.redAccent.shade100));
    }
    final probe = e.probe;
    if (probe == null) {
      return const Row(children: [
        SizedBox(
            width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
        SizedBox(width: 6),
        Text('reading…', style: TextStyle(fontSize: 12, color: Colors.white38)),
      ]);
    }
    final multichannel = probe.channels > 2;
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: '${probe.channels} ch',
          style: TextStyle(
            fontWeight: multichannel ? FontWeight.bold : FontWeight.normal,
            color: multichannel ? Colors.lightBlueAccent : Colors.white38,
          ),
        ),
        TextSpan(
          text: ' · ${_fmtKhz(probe.sampleRate)} · ${probe.bitsPerSample}-bit'
              ' · ${_fmtTime(probe.durationSeconds)}'
              '${probe.ixmlTrackCount > 0 ? ' · ${probe.ixmlTrackCount} trk' : ''}'
              '${_fmtTail(e)}',
        ),
      ]),
      style: const TextStyle(fontSize: 12, color: Colors.white54),
    );
  }

  static String _fmtKhz(int rate) {
    final khz = rate / 1000;
    return khz == khz.roundToDouble()
        ? '${khz.round()} kHz'
        : '${khz.toStringAsFixed(1)} kHz';
  }

  static String _fmtTime(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds - m * 60).floor();
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _fmtTail(WavEntry e) {
    final parts = <String>[];
    final size = e.sizeBytes;
    if (size != null && size > 0) {
      parts.add(size >= 1 << 30
          ? '${(size / (1 << 30)).toStringAsFixed(1)} GB'
          : '${(size / (1 << 20)).round()} MB');
    }
    final mod = e.modified;
    if (mod != null) {
      String two(int v) => v.toString().padLeft(2, '0');
      parts.add('${mod.year}-${two(mod.month)}-${two(mod.day)} '
          '${two(mod.hour)}:${two(mod.minute)}');
    }
    return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
  }
}
