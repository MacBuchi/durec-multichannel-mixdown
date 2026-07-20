import 'package:flutter/material.dart';

import '../../state/app_settings.dart';
import 'about_dialog.dart';

/// App settings: appearance, plus the way into the About dialog.
///
/// The gear in the app bar opens this; About sits at the bottom because it
/// is reference material, not something you come here to change.
Future<void> showSettingsDialog(BuildContext context) {
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
