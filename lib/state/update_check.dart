import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// The public GitHub repo powering the update check and feedback issues.
const repoSlug = 'MacBuchi/durec-multichannel-mixdown';

/// Info about an available update, from the latest GitHub release.
class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.htmlUrl,
    this.apkUrl,
    this.releaseNotes,
  });

  final String latestVersion;

  /// Release page — the download target on desktop platforms.
  final String htmlUrl;

  /// Direct APK asset for the in-app Android update; null when absent.
  final String? apkUrl;
  final String? releaseNotes;
}

/// `true` when [latest] is newer than [current] (numeric per-segment
/// compare, so 0.10.0 > 0.9.2).
bool isNewerVersion(String latest, String current) {
  List<int> parse(String v) =>
      v.split('.').map((part) => int.tryParse(part.trim()) ?? 0).toList();
  final l = parse(latest);
  final c = parse(current);
  for (var i = 0; i < 3; i++) {
    final li = i < l.length ? l[i] : 0;
    final ci = i < c.length ? c[i] : 0;
    if (li != ci) return li > ci;
  }
  return false;
}

class UpdateCheck {
  /// Disabled by the integration test — the check must never make CI
  /// flaky or depend on the network.
  static bool enabled = true;

  /// Fetch the latest GitHub release and compare against the installed
  /// version. Returns `null` when up to date — or on ANY failure: an
  /// update check must never disturb the app.
  static Future<UpdateInfo?> check() async {
    if (!enabled) return null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(
          Uri.parse('https://api.github.com/repos/$repoSlug/releases/latest'),
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if (response.statusCode != 200) return null;
        final body = await response.transform(utf8.decoder).join();
        final release = jsonDecode(body) as Map<String, dynamic>;

        final tag = release['tag_name'] as String? ?? '';
        final latest = tag.startsWith('v') ? tag.substring(1) : tag;
        if (latest.isEmpty || !isNewerVersion(latest, packageInfo.version)) {
          return null;
        }

        final assets = (release['assets'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>();
        final apk = assets
            .where((a) => (a['name'] as String? ?? '').endsWith('.apk'))
            .toList();
        return UpdateInfo(
          latestVersion: latest,
          htmlUrl:
              release['html_url'] as String? ??
              'https://github.com/$repoSlug/releases',
          apkUrl: apk.isEmpty
              ? null
              : apk.first['browser_download_url'] as String?,
          releaseNotes: release['body'] as String?,
        );
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null;
    }
  }
}
