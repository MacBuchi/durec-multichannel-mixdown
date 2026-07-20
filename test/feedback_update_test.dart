import 'package:durecmix/state/feedback.dart';
import 'package:durecmix/state/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isNewerVersion', () {
    test('per-segment numeric compare', () {
      expect(isNewerVersion('0.10.0', '0.9.9'), isTrue);
      expect(isNewerVersion('1.0.0', '0.11.2'), isTrue);
      expect(isNewerVersion('0.11.1', '0.11.1'), isFalse);
      expect(isNewerVersion('0.11.0', '0.11.1'), isFalse);
      expect(isNewerVersion('0.11.1.9', '0.11.1'), isFalse); // 4th ignored
      expect(isNewerVersion('0.12', '0.11.5'), isTrue); // short form
    });
  });

  group('issue building', () {
    test('title prefixes and truncates to the first line', () {
      expect(
        issueTitle(FeedbackType.bug, 'Crash on export\nmore text'),
        'Bug report: Crash on export',
      );
      final long = 'x' * 100;
      final title = issueTitle(FeedbackType.feature, long);
      expect(title, startsWith('Feature request: '));
      expect(title, endsWith('…'));
      expect(title.length, 'Feature request: '.length + 61);
    });

    test('body mirrors the issue-form section structure', () {
      final body = issueBody(
        message: 'It broke',
        version: '0.12.0',
        platform: 'macOS',
      );
      expect(
        body,
        '### Description\n\nIt broke\n\n'
        '### App version\n\n0.12.0\n\n'
        '### Platform\n\nmacOS\n\n'
        '_Automatically filed from the app._',
      );
    });

    test('browser fallback URL pre-fills the matching template', () {
      final url = issueFormUrl(
        FeedbackType.bug,
        message: 'Trim & fade broken',
        version: '0.12.0',
        platform: 'Android',
      );
      expect(url.host, 'github.com');
      expect(url.path, '/$repoSlug/issues/new');
      expect(url.queryParameters['template'], 'bug_report.yml');
      expect(url.queryParameters['title'], 'Bug report: Trim & fade broken');
      expect(url.queryParameters['description'], 'Trim & fade broken');
      expect(url.queryParameters['app-version'], '0.12.0');
      expect(url.queryParameters['platform'], 'Android');
      // & must survive encoding round-trips (query encodes spaces as +)
      expect(url.toString(), contains('Trim+%26+fade'));
      final feature = issueFormUrl(
        FeedbackType.feature,
        message: 'idea',
        version: '1',
        platform: 'macOS',
      );
      expect(feature.queryParameters['template'], 'feature_request.yml');
    });
  });
}
