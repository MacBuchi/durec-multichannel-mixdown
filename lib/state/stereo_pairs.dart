/// Stereo-pair heuristics for DUREC track names: tracks named
/// `"<base> L"` / `"<base> R"` (iXML naming convention) form a pair whose
/// edits mirror onto the partner, with pans inverted.
///
/// Pure functions over [TrackUi] lists — no engine, no notifier — so the
/// mirroring rules are unit-testable in isolation.
library;

import 'mix_types.dart';

/// Base name of a pair member (`"Keys L"` → `"Keys"`), or null when the
/// track is not named like a pair side.
String? pairBaseOf(String name) => name.endsWith(' L') || name.endsWith(' R')
    ? name.substring(0, name.length - 2)
    : null;

/// The other side of `track`'s pair within `tracks`, or null when the track
/// is unpaired or the partner is missing from the recording.
TrackUi? pairPartnerOf(List<TrackUi> tracks, TrackUi track) {
  final base = pairBaseOf(track.name);
  if (base == null) return null;
  final other = track.name.endsWith(' L') ? '$base R' : '$base L';
  for (final candidate in tracks) {
    if (candidate.name == other) return candidate;
  }
  return null;
}

/// Copy `from`'s parameters onto its pair partner: gain, mute, solo, in-mix,
/// polarity and the full EQ mirror as-is; the pan mirrors inverted.
void syncPairOnto(TrackUi partner, TrackUi from) {
  partner.gainDb = from.gainDb;
  partner.pan = -from.pan; // mirrored
  partner.muted = from.muted;
  partner.solo = from.solo;
  partner.inMix = from.inMix;
  partner.polarityInvert = from.polarityInvert;
  partner.eq
    ..hpfEnabled = from.eq.hpfEnabled
    ..hpfFreq = from.eq.hpfFreq
    ..hpfSlope = from.eq.hpfSlope;
  for (final (a, b) in [
    (partner.eq.low, from.eq.low),
    (partner.eq.mid, from.eq.mid),
    (partner.eq.high, from.eq.high),
  ]) {
    a
      ..enabled = b.enabled
      ..freq = b.freq
      ..gainDb = b.gainDb
      ..q = b.q;
  }
}
