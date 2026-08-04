/// The log that a bug report carries (v0.18.0).
///
/// Two things are worth testing here and nothing else is: that a user name
/// never survives into a line — the repo is public and the PII rule names file
/// paths explicitly — and that the ring keeps the *newest* entries, because a
/// report which dropped the ones next to the failure is worthless.
library;

import 'package:durecmix/state/debug_log.dart';
import 'package:durecmix/state/feedback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(DebugLog.clear);

  group('redaction', () {
    test('a macOS home directory loses the user name, keeps the rest', () {
      expect(
        redactPaths('/Users/macbuch/Library/Containers/x/sessions/Take.json'),
        '~/Library/Containers/x/sessions/Take.json',
      );
    });

    test('Linux and Windows homes too', () {
      expect(redactPaths('/home/jane/durec/UFX33.WAV'), '~/durec/UFX33.WAV');
      expect(
        redactPaths(r'C:\Users\Jane Doe\Music\UFX33.WAV'),
        // The name is gone; that the rest keeps its backslashes is fine.
        r'~\Music\UFX33.WAV',
      );
    });

    test('paths without a user name are left alone', () {
      // The take's own location is diagnostically useful and not PII.
      const p = '/Volumes/MacStore/Durec_Export/2025_10_23/UFX33_00.WAV';
      expect(redactPaths(p), p);
      expect(
        redactPaths('content://com.android.providers/document/42'),
        'content://com.android.providers/document/42',
      );
    });

    test('several paths in one line are all redacted', () {
      expect(
        redactPaths('copy /Users/a/one.wav → /Users/b/two.wav'),
        'copy ~/one.wav → ~/two.wav',
      );
    });

    test('a logged error cannot smuggle a user name out', () {
      DebugLog.error(
        'session save',
        StateError('cannot write /Users/macbuch/Library/x.json'),
      );
      final out = DebugLog.recent();
      expect(out, contains('~/Library/x.json'));
      expect(out, isNot(contains('macbuch')));
    });
  });

  group('the ring', () {
    test('keeps what happened, in order', () {
      DebugLog.info('opened a take');
      DebugLog.info('analysis done');
      final out = DebugLog.recent();
      expect(out.indexOf('opened a take'), lessThan(out.indexOf('analysis')));
    });

    test('an error entry names the failure type', () {
      DebugLog.error('export', const FormatException('bad header'));
      final out = DebugLog.recent();
      expect(out, contains('ERROR export'));
      expect(
        out,
        contains('FormatException'),
        reason: 'the kind of failure has to survive truncation',
      );
    });

    test('drops the oldest beyond its capacity, never the newest', () {
      for (var i = 0; i < debugLogCapacity + 50; i++) {
        DebugLog.info('entry $i');
      }
      final out = DebugLog.recent(maxChars: 1 << 20);
      expect(out, contains('entry ${debugLogCapacity + 49}'));
      expect(out, isNot(contains('entry 0')));
    });

    test('a long stack is clipped and says so', () {
      final frames = List.generate(60, (i) => '#$i  Some.frame (file:$i)');
      DebugLog.error(
        'render',
        Exception('boom'),
        StackTrace.fromString(frames.join('\n')),
      );
      final out = DebugLog.recent(maxChars: 1 << 20);
      expect(out, contains('#0  Some.frame'));
      expect(out, contains('#${debugLogStackFrames - 1}  Some.frame'));
      expect(out, isNot(contains('#$debugLogStackFrames  Some.frame')));
      expect(out, contains('more frames'));
    });
  });

  group('recent()', () {
    test('nothing logged means an empty string, not a heading', () {
      expect(DebugLog.recent(), isEmpty);
      expect(DebugLog.hasEntries, isFalse);
    });

    test('a tight budget keeps the newest entries and says what it cut', () {
      for (var i = 0; i < 40; i++) {
        DebugLog.info('entry $i padded out to make it longer than a few bytes');
      }
      final out = DebugLog.recent(maxChars: 400);
      expect(out.length, lessThanOrEqualTo(500)); // budget + the note
      expect(out, contains('entry 39'));
      expect(out, isNot(contains('entry 0')));
      expect(out, contains('earlier entries dropped'));
    });

    test('one entry longer than the whole budget is clipped, not dropped', () {
      DebugLog.info('x' * 5000);
      final out = DebugLog.recent(maxChars: 100);
      expect(out.length, 100);
    });
  });

  group('what reaches the issue', () {
    test('a bug report body carries the log in a fenced block', () {
      final body = issueBody(
        message: 'export fails',
        version: '0.18.0',
        platform: 'macOS',
        log: 'ERROR export\n  FormatException: bad header',
      );
      expect(body, contains('### Recent log'));
      expect(body, contains('```'));
      expect(body, contains('FormatException'));
    });

    test('without a log there is no empty heading', () {
      final body = issueBody(
        message: 'nice to have',
        version: '0.18.0',
        platform: 'macOS',
      );
      expect(body, isNot(contains('Recent log')));
    });

    test('the pre-filled form URL carries a log field the template has', () {
      final url = issueFormUrl(
        FeedbackType.bug,
        message: 'export fails',
        version: '0.18.0',
        platform: 'Web',
        log: 'ERROR export',
      );
      // The id must match `.github/ISSUE_TEMPLATE/bug_report.yml`, or GitHub
      // drops the value without a word.
      expect(url.queryParameters['log'], 'ERROR export');
      expect(url.queryParameters['platform'], 'Web');
    });

    test('a long log is cut from the front for the URL, keeping the tail', () {
      final long = List.generate(400, (i) => 'line $i').join('\n');
      final url = issueFormUrl(
        FeedbackType.bug,
        message: 'x',
        version: '0.18.0',
        platform: 'macOS',
        log: long,
      );
      final sent = url.queryParameters['log']!;
      expect(sent.length, urlLogChars);
      expect(sent, endsWith('line 399'));
    });
  });
}
