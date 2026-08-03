/// How the browser preview paces itself against the machine it runs on.
///
/// A parameter change drops the buffered audio and mixes it again, so that a
/// fader move is heard now instead of a ring's length later (#109). What may
/// never happen is that the kept remainder runs out before the replacement
/// arrives: the worklet then plays silence, and that is the click reported
/// from the iPad (#114).
///
/// The safe remainder is not a constant. It is the wall-clock time one mixing
/// round takes, and that differs by an order of magnitude between a desktop
/// and a tablet mixing 34 channels. So the pump measures its own throughput
/// and these functions turn the measurement into the two numbers that depend
/// on it. Pure on purpose — the pacing rules are unit-tested without a browser.
library;

/// Lower bound for the kept remainder.
///
/// The value #109 chose, and on a fast machine the measurement lands far
/// below it: three pump ticks, short enough to hear the change immediately.
const minTailSeconds = 0.12;

/// Upper bound for the kept remainder.
///
/// Past this, re-mixing stops being worth it — the pre-#109 behaviour was to
/// keep the whole ring (about a second), which is exactly the latency the
/// re-mix exists to avoid. A device slower than this budget allows keeps its
/// audio intact and just reacts late.
const maxTailSeconds = 0.75;

/// Safety factor on the measured mixing time.
///
/// The measurement is an average; a single tick can take longer because the
/// browser scheduled something else. Two is the smallest factor that survives
/// one such tick without a dropout.
const _tailSafety = 2.0;

/// How much a single observed dropout adds to the remainder.
///
/// Around one and a half pump ticks: small enough that a device which drops
/// out once does not jump to a sluggish fader, large enough that a handful of
/// dropouts during one drag converge on a working buffer rather than creeping.
const tailBonusStep = 0.06;

/// Audio the pump must keep in the ring when it re-mixes for changed
/// parameters, given how fast this machine mixes.
///
/// [mixRate] is audio seconds produced per wall-clock second — 12 on a laptop,
/// possibly close to 1 on a tablet with many channels. [chunkSeconds] is how
/// much audio one pump call produces, [tickSeconds] the pump's period: the
/// replacement can only arrive one tick after the trim at the earliest.
double previewTailSeconds(
  double mixRate, {
  required double chunkSeconds,
  required double tickSeconds,
}) {
  if (!mixRate.isFinite || mixRate <= 0) return maxTailSeconds;
  final mixingTime = chunkSeconds / mixRate;
  return (mixingTime * _tailSafety + tickSeconds).clamp(
    minTailSeconds,
    maxTailSeconds,
  );
}

/// How long to wait between two re-mixes while a fader is being dragged.
///
/// A drag pushes on every pointer move. Re-mixing faster than the machine can
/// finish a round means every round is thrown away by the next one and the
/// ring only ever shrinks — so the floor is the measured mixing time, not a
/// constant. [floor] keeps the fast-machine behaviour of #109 unchanged.
Duration previewRewindInterval(
  double mixRate, {
  required double chunkSeconds,
  required Duration floor,
}) {
  if (!mixRate.isFinite || mixRate <= 0) return floor;
  final mixingTime = chunkSeconds / mixRate * _tailSafety;
  final micros = (mixingTime * Duration.microsecondsPerSecond).round();
  return micros > floor.inMicroseconds ? Duration(microseconds: micros) : floor;
}

/// Extra remainder a device has earned by dropping out anyway.
///
/// [previewTailSeconds] is derived from an *average* round, so it carries about
/// one round of margin — and a browser main thread can spend several times its
/// average on one round (garbage collection, laying out thirty-odd channel
/// strips while the finger moves). Prediction alone therefore cannot get this
/// right on every device, so the pacing also learns from the outcome:
/// [dropouts] observed since the previous re-mix each add a [tailBonusStep],
/// and a clean re-mix gives one step back.
///
/// Not every dropout is caused by re-mixing — an unrelated main-thread stall
/// counts too. That errs towards a longer buffer, which is also the answer for
/// a stall, so it is left uncorrected on purpose.
double nextTailBonus(double bonus, {required int dropouts}) {
  final next = dropouts > 0
      ? bonus + tailBonusStep * dropouts
      : bonus - tailBonusStep;
  // The cap is the whole tail budget: past it the remainder is what
  // [maxTailSeconds] allows and the re-mix stops happening at all, which is
  // the honest outcome for a device that cannot keep up.
  return next.clamp(0.0, maxTailSeconds - minTailSeconds);
}

/// Fold a fresh throughput sample into the running estimate.
///
/// Deliberately asymmetric: a drop is adopted quickly and a recovery slowly,
/// because being wrong on the low side costs audible silence while being
/// wrong on the high side only costs a few milliseconds of latency.
double blendMixRate(double current, double sample) {
  if (!sample.isFinite || sample <= 0) return current;
  final alpha = sample < current ? 0.5 : 0.1;
  return current + alpha * (sample - current);
}
