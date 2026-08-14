import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../io/platform_shim.dart';
import 'debug_log.dart';
import 'update_check.dart' show repoSlug;

enum FeedbackType { feature, bug }

/// Build-time token from the release workflow (fine-grained PAT, issues-only
/// on the public repo). Empty in debug/PR builds → browser fallback.
const _token = String.fromEnvironment('DURECMIX_FEEDBACK_TOKEN');

String issueTitle(FeedbackType type, String message) {
  final prefix = type == FeedbackType.bug
      ? 'Bug report: '
      : 'Feature request: ';
  final head = message.trim().split('\n').first.trim();
  return prefix + (head.length <= 60 ? head : '${head.substring(0, 60)}…');
}

/// Mirrors the section structure GitHub renders for the issue-form
/// templates (.github/ISSUE_TEMPLATE), so API-filed and browser-filed
/// issues look identical.
///
/// [log] is the tail of [DebugLog] on a bug report — the difference between
/// "export failed" and knowing which call threw where. Left out when empty,
/// so a report never carries a heading with nothing under it.
String issueBody({
  required String message,
  required String version,
  required String platform,
  String log = '',
}) =>
    '### Description\n\n${message.trim()}\n\n'
    '### App version\n\n$version\n\n'
    '### Platform\n\n$platform\n\n'
    '${log.isEmpty ? '' : '### Recent log\n\n```\n$log\n```\n\n'}'
    '_Automatically filed from the app._';

/// Pre-filled issue-form URL (the no-token path): GitHub fills YAML-form
/// fields from query params whose names match the field ids.
/// The URL carries a **much shorter** log than the API path: a pre-filled
/// form is a GET, and browsers start dropping query strings well before
/// GitHub's own limit. What survives is the tail — the part next to the
/// failure.
const urlLogChars = 1200;

Uri issueFormUrl(
  FeedbackType type, {
  required String message,
  required String version,
  required String platform,
  String log = '',
}) {
  final template = type == FeedbackType.bug
      ? 'bug_report.yml'
      : 'feature_request.yml';
  return Uri.https('github.com', '/$repoSlug/issues/new', {
    'template': template,
    'title': issueTitle(type, message),
    'description': message.trim(),
    'app-version': version,
    'platform': platform,
    if (log.isNotEmpty)
      'log': log.length <= urlLogChars
          ? log
          : log.substring(log.length - urlLogChars),
  });
}

String currentPlatform() {
  if (isAndroidPlatform) return 'Android';
  if (isIOSPlatform) return 'iOS';
  if (isMacOSPlatform) return 'macOS';
  if (isWindowsPlatform) return 'Windows';
  return operatingSystemName;
}

/// File the feedback. Returns `true` when the issue was created directly
/// via the API, `false` when the pre-filled browser form was opened
/// instead (no token). Throws on failure.
Future<bool> submitFeedback(FeedbackType type, String message) async {
  final version = (await PackageInfo.fromPlatform()).version;
  final platform = currentPlatform();
  // Only bug reports: a feature request has nothing to diagnose, and the log
  // would just make it unreadable. The PII rule is satisfied by construction —
  // `DebugLog` redacts on the way in, and the user pressed send.
  final log = type == FeedbackType.bug ? DebugLog.recent() : '';

  // No network in the web build, so a build token is unusable there: posting
  // would throw `UnsupportedError` and the dialog blamed the connection
  // ("Sending failed. Are you online?"). The pre-filled browser form is the
  // route that actually works, and in a browser it costs the user nothing.
  //
  // A Play build takes the same route for a different reason: `_token` is a
  // compile-time constant and therefore sits extractable in the shipped
  // bundle. A GitHub APK is downloaded by people who could read the repo's
  // secrets policy anyway; a store listing is handed to strangers, so the
  // token stays out of it even if the workflow injects one.
  if (_token.isEmpty || !hasNetwork || isPlayStoreBuild) {
    final ok = await launchUrl(
      issueFormUrl(
        type,
        message: message,
        version: version,
        platform: platform,
        log: log,
      ),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) throw Exception('could not open the browser');
    return false;
  }

  final response = await httpPostJson(
    Uri.parse('https://api.github.com/repos/$repoSlug/issues'),
    headers: {
      'accept': 'application/vnd.github+json',
      'authorization': 'Bearer $_token',
    },
    body: jsonEncode({
      'title': issueTitle(type, message),
      'body': issueBody(
        message: message,
        version: version,
        platform: platform,
        log: log,
      ),
      'labels': [type == FeedbackType.bug ? 'bug' : 'enhancement'],
    }),
  );
  if (response.statusCode != 201) {
    throw Exception('GitHub responded ${response.statusCode}');
  }
  return true;
}
