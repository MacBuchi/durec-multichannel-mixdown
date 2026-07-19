import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_check.dart' show repoSlug;

enum FeedbackType { feature, bug }

/// Build-time token from the release workflow (fine-grained PAT, issues-only
/// on the public repo). Empty in debug/PR builds → browser fallback.
const _token = String.fromEnvironment('DURECMIX_FEEDBACK_TOKEN');

String issueTitle(FeedbackType type, String message) {
  final prefix =
      type == FeedbackType.bug ? 'Bug report: ' : 'Feature request: ';
  final head = message.trim().split('\n').first.trim();
  return prefix + (head.length <= 60 ? head : '${head.substring(0, 60)}…');
}

/// Mirrors the section structure GitHub renders for the issue-form
/// templates (.github/ISSUE_TEMPLATE), so API-filed and browser-filed
/// issues look identical.
String issueBody({
  required String message,
  required String version,
  required String platform,
}) =>
    '### Description\n\n${message.trim()}\n\n'
    '### App version\n\n$version\n\n'
    '### Platform\n\n$platform\n\n'
    '_Automatically filed from the app._';

/// Pre-filled issue-form URL (the no-token path): GitHub fills YAML-form
/// fields from query params whose names match the field ids.
Uri issueFormUrl(
  FeedbackType type, {
  required String message,
  required String version,
  required String platform,
}) {
  final template =
      type == FeedbackType.bug ? 'bug_report.yml' : 'feature_request.yml';
  return Uri.https('github.com', '/$repoSlug/issues/new', {
    'template': template,
    'title': issueTitle(type, message),
    'description': message.trim(),
    'app-version': version,
    'platform': platform,
  });
}

String currentPlatform() {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  return Platform.operatingSystem;
}

/// File the feedback. Returns `true` when the issue was created directly
/// via the API, `false` when the pre-filled browser form was opened
/// instead (no token). Throws on failure.
Future<bool> submitFeedback(FeedbackType type, String message) async {
  final version = (await PackageInfo.fromPlatform()).version;
  final platform = currentPlatform();

  if (_token.isEmpty) {
    final ok = await launchUrl(
      issueFormUrl(type,
          message: message, version: version, platform: platform),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) throw Exception('could not open the browser');
    return false;
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .postUrl(Uri.parse('https://api.github.com/repos/$repoSlug/issues'));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $_token')
      ..contentType = ContentType.json;
    request.write(jsonEncode({
      'title': issueTitle(type, message),
      'body': issueBody(
          message: message, version: version, platform: platform),
      'labels': [type == FeedbackType.bug ? 'bug' : 'enhancement'],
    }));
    final response =
        await request.close().timeout(const Duration(seconds: 15));
    await response.drain<void>();
    if (response.statusCode != 201) {
      throw HttpException('GitHub responded ${response.statusCode}');
    }
    return true;
  } finally {
    client.close(force: true);
  }
}
