import 'package:durecmix/state/preview_pacing.dart';
import 'package:flutter_test/flutter_test.dart';

/// The numbers the pump runs with: 200 ms of audio per call, a 40 ms period.
const _chunk = 0.2;
const _tick = 0.04;

double tail(double mixRate) =>
    previewTailSeconds(mixRate, chunkSeconds: _chunk, tickSeconds: _tick);

Duration gap(double mixRate) => previewRewindInterval(
  mixRate,
  chunkSeconds: _chunk,
  floor: const Duration(milliseconds: 300),
);

void main() {
  group('previewTailSeconds', () {
    test('a fast machine keeps the short tail #109 chose', () {
      // 12× realtime: mixing 200 ms takes 17 ms, so the floor decides.
      expect(tail(12.0), minTailSeconds);
    });

    test('a device mixing barely faster than realtime keeps much more', () {
      // The iPad case: 200 ms of audio costs ~130 ms, so 120 ms of remainder
      // is gone before the replacement lands — that is the click in #114.
      final t = tail(1.5);
      expect(t, greaterThan(0.25));
      expect(t, lessThanOrEqualTo(maxTailSeconds));
    });

    test('slower than realtime is capped, not unbounded', () {
      expect(tail(0.3), maxTailSeconds);
      expect(tail(0.01), maxTailSeconds);
    });

    test('the tail never falls below the floor or above the cap', () {
      for (final rate in [0.1, 0.5, 1.0, 2.0, 5.0, 50.0]) {
        expect(tail(rate), inInclusiveRange(minTailSeconds, maxTailSeconds));
      }
    });

    test('a slower machine never gets a shorter tail', () {
      var previous = 0.0;
      for (final rate in [20.0, 8.0, 4.0, 2.0, 1.0, 0.5]) {
        final t = tail(rate);
        expect(t, greaterThanOrEqualTo(previous));
        previous = t;
      }
    });

    test('a nonsense measurement falls back to the safe end', () {
      expect(tail(0), maxTailSeconds);
      expect(tail(-3), maxTailSeconds);
      expect(tail(double.nan), maxTailSeconds);
    });
  });

  group('previewRewindInterval', () {
    test('a fast machine keeps the 300 ms floor', () {
      expect(gap(12.0), const Duration(milliseconds: 300));
    });

    test('a slow machine waits at least one mixing round', () {
      // At 0.5× realtime a 200 ms chunk costs 400 ms; re-mixing every 300 ms
      // would throw away every round before it finished.
      expect(gap(0.5), greaterThan(const Duration(milliseconds: 300)));
    });

    test('a nonsense measurement falls back to the floor', () {
      expect(gap(0), const Duration(milliseconds: 300));
      expect(gap(double.infinity), const Duration(milliseconds: 300));
    });
  });

  group('nextTailBonus', () {
    test('a clean re-mix asks for nothing extra', () {
      expect(nextTailBonus(0, dropouts: 0), 0);
    });

    test('a dropout buys more remainder than the prediction gave', () {
      expect(nextTailBonus(0, dropouts: 1), tailBonusStep);
      // Three in one round is a badly wrong prediction, not a hiccup.
      expect(nextTailBonus(0, dropouts: 3), closeTo(3 * tailBonusStep, 1e-12));
    });

    test('a device that stops dropping out gets its response back', () {
      var bonus = nextTailBonus(0, dropouts: 4);
      for (var i = 0; i < 10; i++) {
        bonus = nextTailBonus(bonus, dropouts: 0);
      }
      expect(bonus, 0);
    });

    test('never grows past the tail budget', () {
      var bonus = 0.0;
      for (var i = 0; i < 100; i++) {
        bonus = nextTailBonus(bonus, dropouts: 5);
      }
      expect(bonus, maxTailSeconds - minTailSeconds);
      // Which is exactly enough to lift the fastest prediction to the cap,
      // and no further — past it the re-mix stops happening instead.
      expect(minTailSeconds + bonus, maxTailSeconds);
    });

    test('a struggling device converges within one drag', () {
      // 300 ms between re-mixes, so ten rounds is about three seconds of
      // holding a fader — the answer to one dropout per round has to arrive
      // inside that, not over the course of a session.
      double keep(double bonus) =>
          (tail(1.5) + bonus).clamp(minTailSeconds, maxTailSeconds);
      var bonus = 0.0;
      for (var i = 0; i < 3; i++) {
        bonus = nextTailBonus(bonus, dropouts: 1);
      }
      expect(keep(bonus), greaterThan(tail(1.5) + 0.15));
      for (var i = 0; i < 7; i++) {
        bonus = nextTailBonus(bonus, dropouts: 1);
      }
      expect(keep(bonus), maxTailSeconds);
    });
  });

  group('blendMixRate', () {
    test('adopts a drop faster than a recovery', () {
      // Being wrong on the low side costs silence, on the high side latency.
      final dropped = blendMixRate(10.0, 2.0);
      final recovered = blendMixRate(2.0, 10.0);
      expect(10.0 - dropped, greaterThan(recovered - 2.0));
    });

    test('converges on a steady measurement', () {
      var rate = 10.0;
      for (var i = 0; i < 40; i++) {
        rate = blendMixRate(rate, 1.5);
      }
      expect(rate, closeTo(1.5, 0.01));
    });

    test('ignores a garbage sample instead of poisoning the estimate', () {
      expect(blendMixRate(4.0, 0), 4.0);
      expect(blendMixRate(4.0, double.nan), 4.0);
    });
  });
}
