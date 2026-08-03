import 'package:flutter/material.dart';

import '../../state/app_settings.dart';
import 'about_dialog.dart';

/// App settings: appearance, plus the way into the About dialog.
///
/// The gear in the app bar opens this; About sits at the bottom because it
/// is reference material, not something you come here to change.
///
/// [playbackUnderruns], [mixRate] and [tailSeconds] are the browser preview's
/// diagnostics (#114): they only appear once something has played in a
/// browser, because on a device one cannot attach a debugger to, these three
/// numbers are the only way to tell whether the pacing holds — and if it does
/// not, which of the two knobs was wrong.
///
/// [storagePersists] is web-only in the same way: `null` on a platform with a
/// real filesystem, where a saved mix staying saved needs no explanation.
Future<void> showSettingsDialog(
  BuildContext context, {
  int? playbackUnderruns,
  double? mixRate,
  double? tailSeconds,
  bool? storagePersists,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Appearance',
              style: Theme.of(dialogContext).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            // Rebuilds itself, so the segment highlight follows the tap even
            // though the surrounding dialog route never rebuilds.
            ValueListenableBuilder<ThemeMode>(
              valueListenable: AppSettings.themeMode,
              builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto),
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode),
                    label: Text('Dark'),
                  ),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (selection) async =>
                    (await AppSettings.load()).setThemeMode(selection.first),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'System follows your device’s light/dark setting.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            if (storagePersists != null) ...[
              const Divider(height: 24),
              Text(
                'Storage',
                style: Theme.of(dialogContext).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              Text(
                storagePersists
                    ? 'Your mixes and settings are kept in this browser. The '
                          'recording itself is not — after a reload, choose '
                          'the same file again and its mix comes back.'
                    : 'This browser is not storing anything, so mixes are '
                          'lost when the page reloads. Private windows block '
                          'storage; a normal window keeps it.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
            if (playbackUnderruns != null) ...[
              const Divider(height: 24),
              Text(
                'Playback diagnostics',
                style: Theme.of(dialogContext).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              Text(
                [
                  playbackUnderruns == 0
                      ? 'No dropouts'
                      : '$playbackUnderruns dropout'
                            '${playbackUnderruns == 1 ? '' : 's'}',
                  if (mixRate != null)
                    'mixes at ${mixRate.toStringAsFixed(1)}× realtime',
                  if (tailSeconds != null)
                    'keeps ${(tailSeconds * 1000).round()} ms on a fader move',
                ].join(' · '),
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                'Counted since this take started playing. Dropouts are heard '
                'as clicks; the mixing speed sets how much audio stays '
                'buffered when you move a fader, and every dropout raises '
                'that buffer a little.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
            const Divider(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: const Text('About DurecMix'),
              subtitle: const Text('Version, update status, links, feedback'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                showAboutDurecMixDialog(context);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
