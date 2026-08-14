import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../io/platform_shim.dart';
import '../../state/app_info.dart';
import '../../state/update_check.dart';
import '../app_banners.dart';
import 'changelog_dialog.dart';

/// About dialog: installed version + update status, project links, and a
/// shortcut into the feedback flow.
Future<void> showAboutDurecMixDialog(BuildContext context) {
  Future<void> openUrl(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('About DurecMix'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<String>(
              future: AppInfo.version(),
              builder: (context, snap) => Text(
                'Version ${snap.data ?? '…'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 4),
            // Best-effort, never blocks: shows the update status once the
            // release check returns (silent on failure / when offline).
            //
            // Where there is no network at all (web build), the check throws
            // and the error is swallowed — which looked exactly like "no
            // update found". Saying "You're up to date" there is a claim the
            // app never verified, so it says nothing instead.
            //
            // Same reasoning for a Play build, where the check is off by
            // policy rather than by capability: Play owns the update channel
            // there, so this dialog has nothing to report either. The banner
            // and this line are two separate callers of the same check —
            // gating only one of them is how the app ends up claiming to be
            // up to date on the strength of a check it never ran.
            if (hasNetwork && canCheckForUpdates)
              FutureBuilder<UpdateInfo?>(
                future: UpdateCheck.check(),
                builder: (context, snap) {
                  final text = snap.connectionState != ConnectionState.done
                      ? 'Checking for updates…'
                      : snap.data != null
                      ? 'Update available: v${snap.data!.latestVersion} '
                            '— see the banner on the mixer.'
                      : "You're up to date.";
                  return Text(
                    text,
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                },
              ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.new_releases_outlined),
              title: const Text("What's new"),
              subtitle: const Text('Changes in every version'),
              // Opens on top of About, so Close leads back here.
              onTap: () => showChangelogDialog(dialogContext),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.code),
              title: const Text('GitHub project'),
              subtitle: const Text(AppInfo.githubUrl),
              onTap: () => openUrl(AppInfo.githubUrl),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.menu_book),
              title: const Text('User guide'),
              onTap: () => openUrl(AppInfo.guideUrl),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.gavel),
              title: const Text('Open-source licenses'),
              subtitle: const Text('Flutter, Dart packages and Rust crates'),
              onTap: () async {
                final version = await AppInfo.version();
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                showLicensePage(
                  context: context,
                  applicationName: 'DurecMix',
                  applicationVersion: version,
                );
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.feedback_outlined),
              title: const Text('Request a feature or report a bug'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                showFeedbackDialog(context);
              },
            ),
            const Divider(height: 20),
            // Naming a hardware brand to state what the app reads is
            // referential use (§ 23 Abs. 1 Nr. 3 MarkenG, Art. 14 Abs. 1
            // lit. c UMV) — permitted as long as it is honest and suggests no
            // commercial connection. This line is the "suggests no connection"
            // half, and it belongs in the app rather than only in the store
            // listing, because the app also travels as an APK and a PWA.
            Text(
              'RME and DUREC are trademarks of their respective owners. '
              'This app is not affiliated with, endorsed by or sponsored by '
              'Audio AG / RME.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
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
