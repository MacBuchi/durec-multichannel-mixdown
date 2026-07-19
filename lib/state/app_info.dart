import 'package:package_info_plus/package_info_plus.dart';

import 'update_check.dart' show repoSlug;

/// Public links shown in the About dialog.
class AppInfo {
  static const githubUrl = 'https://github.com/$repoSlug';
  static const releasesUrl = 'https://github.com/$repoSlug/releases/latest';
  static const guideUrl =
      'https://github.com/$repoSlug/blob/main/docs/GUIDE.md';

  /// Installed app version (e.g. "0.12.0"); "–" if unavailable.
  static Future<String> version() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '–';
    }
  }
}
