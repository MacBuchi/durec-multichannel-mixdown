/// The app's one logger, and the ring buffer a bug report is built from.
///
/// Why this exists: DurecMix ships past the stores, so there are no Play
/// Vitals and no crash clusters — an error on the user's device is invisible
/// unless the app can hand it over. Until v0.18.0 there was neither a global
/// handler nor a log, and it cost real diagnosis: when the app disappeared on
/// the iPad after eight minutes, nothing distinguished "the system killed a
/// backgrounded app" from "it crashed".
///
/// The sink is deliberately *not* a service. The last lines ride along with a
/// bug report the user files anyway ([recent]) — that is the whole of route A
/// for an app with no backend, see the DocuHub's `observability.md`.
///
/// Two jobs, split on purpose: `logger` formats for a console someone is
/// watching, and [recent] formats for a text report someone will read weeks
/// later. Only the second one ever leaves the device, which is why the
/// redaction lives there.
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logger/logger.dart';

/// How many entries the ring keeps. Two hundred covers opening a take,
/// analysing it, playing and exporting — the span a report needs — without
/// holding a session's worth of noise.
const debugLogCapacity = 200;

/// Frames kept per stack trace. A Flutter stack runs past a hundred lines,
/// nearly all framework; the top frames carry the answer.
const debugLogStackFrames = 15;

/// Strip user names out of paths, keeping everything that helps diagnose.
///
/// `/Users/someone/Library/…` → `~/Library/…`. The rest of the path stays: the
/// directory structure and the take's name are what make a report readable,
/// and neither is what the PII rule is about. **Everything that travels goes
/// through here** — the repo is public, and the rule is explicit that stack
/// traces and log lines may be sent while paths carrying a user name may not.
///
/// The name segment runs to the next separator, **spaces included**: a Windows
/// home is the display name, so `C:\Users\Jane Doe\…` is the normal case, and
/// stopping at the space would have published "Doe". The cost is that a message
/// which mentions a home directory without a following separator loses its tail
/// to the redaction — the cheaper of the two mistakes by a wide margin. Bounded
/// to the line so it can never swallow the next entry or a stack frame.
String redactPaths(String text) => text
    .replaceAll(RegExp(r'/(?:Users|home)/[^/\n]+'), '~')
    .replaceAll(RegExp(r'(?:[A-Za-z]:)?\\Users\\[^\\\n]+'), r'~');

/// Central log. Static because the global error handlers run before any widget
/// exists — there is nothing to inject them into.
class DebugLog {
  DebugLog._();

  static final List<String> _lines = <String>[];

  static final Logger _logger = Logger(
    // A release build has no console anyone reads, and `logger`'s output does
    // cost work; warnings and errors are the ones worth the cycles.
    level: kDebugMode ? Level.debug : Level.warning,
    printer: SimplePrinter(printTime: true),
  );

  /// A milestone worth having in a report: a take opened, an export started.
  /// Not for anything per-frame — the ring is [debugLogCapacity] deep.
  static void info(String message) {
    _add('INFO ', message);
    _logger.i(message);
  }

  /// Something failed. [context] says *where*, in words a report can carry
  /// ("session save", "export", "reference analysis").
  static void error(String context, Object error, [StackTrace? stack]) {
    _add('ERROR', context, error: error, stack: stack);
    _logger.e(context, error: error, stackTrace: stack);
  }

  static void _add(
    String level,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    final buffer = StringBuffer(
      '${DateTime.now().toUtc().toIso8601String()} $level $message',
    );
    if (error != null) {
      // Runtime type first: "which kind of failure" survives truncation
      // better than a message that opens with a sentence.
      buffer.write('\n  ${error.runtimeType}: $error');
    }
    if (stack != null) {
      final frames = stack.toString().trim().split('\n');
      for (final frame in frames.take(debugLogStackFrames)) {
        buffer.write('\n  $frame');
      }
      if (frames.length > debugLogStackFrames) {
        buffer.write(
          '\n  … ${frames.length - debugLogStackFrames} more frames',
        );
      }
    }
    _lines.add(redactPaths(buffer.toString()));
    if (_lines.length > debugLogCapacity) {
      _lines.removeRange(0, _lines.length - debugLogCapacity);
    }
  }

  /// The tail of the log, newest last, at most [maxChars] long.
  ///
  /// Truncated from the **front**: the entries closest to a failure are the
  /// ones worth keeping, and a report that drops them to make room for the
  /// app's start-up is useless. Empty when nothing was logged, so a caller can
  /// leave the section out entirely rather than send an empty heading.
  static String recent({int maxChars = 4000}) {
    if (_lines.isEmpty) return '';
    final kept = <String>[];
    var used = 0;
    for (final line in _lines.reversed) {
      if (used + line.length + 1 > maxChars) break;
      kept.add(line);
      used += line.length + 1;
    }
    // Everything too long for the budget on its own would otherwise return an
    // empty log with a note — keep the newest entry, clipped.
    if (kept.isEmpty) return _lines.last.substring(0, maxChars);
    final dropped = _lines.length - kept.length;
    final body = kept.reversed.join('\n');
    return dropped == 0
        ? body
        : '… $dropped earlier ${dropped == 1 ? 'entry' : 'entries'} dropped\n'
              '$body';
  }

  /// True when there is anything to report.
  static bool get hasEntries => _lines.isNotEmpty;

  /// Tests only — the ring is process-wide.
  static void clear() => _lines.clear();
}
