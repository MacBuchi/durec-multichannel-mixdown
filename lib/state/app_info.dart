import 'package:package_info_plus/package_info_plus.dart';

import 'update_check.dart' show repoSlug;

/// Public links shown in the About dialog.
class AppInfo {
  static const githubUrl = 'https://github.com/$repoSlug';
  static const releasesUrl = 'https://github.com/$repoSlug/releases/latest';
  static const guideUrl =
      'https://github.com/$repoSlug/blob/main/docs/GUIDE.md';

  /// Hosted next to the PWA — `web/datenschutz.html`, which `pages.yml`
  /// deploys along with the rest of `build/web`.
  ///
  /// Written out rather than built from [repoSlug]: a Pages host is
  /// lower-cased while the path keeps the repository's own spelling, so a
  /// constructed URL would be wrong on one half or the other.
  static const privacyUrl =
      'https://macbuchi.github.io/durec-multichannel-mixdown/datenschutz.html';

  /// Installed app version (e.g. "0.12.0"); "–" if unavailable.
  static Future<String> version() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '–';
    }
  }
}
