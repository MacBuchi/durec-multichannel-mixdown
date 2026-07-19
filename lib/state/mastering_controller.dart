import '../io/saf.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'package:flutter/foundation.dart' show listEquals;

import 'mixer_state.dart';
import 'reference_profile_cache.dart';

/// Reference mastering: the chosen reference set, its analyzed (and merged)
/// profile, and the mastered playback preview. Owned and composed by
/// [MixerState], which stays the single rebuild root.
class MasteringController {
  MasteringController(this._owner);

  final MixerState _owner;

  /// Session state only — the analyzed profiles live in the profile cache,
  /// keyed per reference file. Multiple references average into one genre
  /// target curve (one vote per song).
  bool enabled = false;
  List<rust.ApiMasteringReference> references = [];

  /// Display label: single reference name, or "N references".
  String get referenceName => references.isEmpty
      ? ''
      : references.length == 1
          ? references.first.name
          : '${references.length} references';

  /// Analyzed profile of the chosen reference (runtime only; backed by
  /// [ReferenceProfileCache]).
  rust.ApiReferenceProfile? profile;
  bool analyzingReference = false;
  double referenceProgress = 0;
  String analyzingReferenceLabel = '';

  /// Mastering preview (runtime only, off after opening a take): playback
  /// runs through the matching FIRs designed from [mixStats] + [profile].
  /// Mix edits mark the stats stale instead of re-scanning the file — the
  /// user refreshes explicitly.
  bool preview = false;
  rust.ApiMixStats? mixStats;
  bool mixStatsStale = false;
  bool analyzingMix = false;
  double mixAnalysisProgress = 0;

  /// Stats+profile pair handed to the player while the preview is active.
  rust.ApiMixStats? get previewStats => preview && enabled ? mixStats : null;

  /// Every mix edit invalidates the preview's whole-file analysis; the
  /// preview keeps playing on the frozen plan until the user refreshes.
  void markMixEdited() {
    if (preview) mixStatsStale = true;
  }

  /// Runtime preview state never survives a take switch.
  void resetForNewTake() {
    preview = false;
    mixStats = null;
    mixStatsStale = false;
  }

  /// Adopt the mastering part of a freshly loaded session's master.
  void restoreFromMaster(rust.ApiMaster m) {
    enabled = m.masteringEnabled;
    if (!listEquals(references.map((r) => r.path).toList(),
        m.masteringReferences.map((r) => r.path).toList())) {
      profile = null; // different reference set → profile is stale
    }
    references = List.of(m.masteringReferences);
  }

  void setEnabled(bool value) {
    enabled = value && references.isNotEmpty;
    if (!enabled) preview = false;
    _owner.scheduleSave();
    _owner.notify();
    _owner.playback.pushLiveParams();
  }

  /// Add a reference track and analyze it (cache-backed). Throws on
  /// analysis failure — the previous reference set stays active then.
  Future<void> addReference(String path, String name) async {
    if (references.any((r) => r.path == path)) return;
    final previous = references;
    final previousProfile = profile;
    references = [
      ...references,
      rust.ApiMasteringReference(path: path, name: name),
    ];
    profile = null; // merged target must include the new song
    _owner.notify();
    try {
      await ensureProfile();
      enabled = true;
      _owner.scheduleSave();
      _owner.playback.pushLiveParams(); // preview follows the new target
    } catch (_) {
      references = previous;
      profile = previousProfile;
      rethrow;
    } finally {
      _owner.notify();
    }
  }

  Future<void> removeReference(rust.ApiMasteringReference ref) async {
    references = references.where((r) => r.path != ref.path).toList();
    profile = null;
    if (references.isEmpty) {
      enabled = false;
      preview = false;
    }
    _owner.scheduleSave();
    _owner.notify();
    if (references.isNotEmpty) {
      // Remaining profiles come from the cache — re-merge is instant.
      try {
        await ensureProfile();
      } catch (_) {
        // The removal itself already applied; a failed re-merge surfaces
        // on the next export, which re-runs ensureProfile.
      }
    }
    _owner.playback.pushLiveParams();
  }

  /// Merged target profile of the current reference set: memory → per-file
  /// cache → fresh analysis (streams progress into [referenceProgress]),
  /// then averaged engine-side when more than one reference is chosen.
  Future<rust.ApiReferenceProfile?> ensureProfile() async {
    if (references.isEmpty) return null;
    if (profile != null) return profile;
    final refs = List.of(references);
    final profiles = <rust.ApiReferenceProfile>[];
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      var p = await ReferenceProfileCache.load(ref.path);
      p ??= await _analyzeSingleReference(ref, i + 1, refs.length);
      if (p == null) {
        throw StateError('reference analysis failed: ${ref.name}');
      }
      profiles.add(p);
    }
    profile = profiles.length == 1
        ? profiles.single
        : await rust.mergeReferenceProfiles(profiles: profiles);
    _owner.notify();
    return profile;
  }

  Future<rust.ApiReferenceProfile?> _analyzeSingleReference(
      rust.ApiMasteringReference ref, int index, int total) async {
    analyzingReference = true;
    referenceProgress = 0;
    analyzingReferenceLabel = total > 1 ? '${ref.name} ($index/$total)' : ref.name;
    _owner.notify();
    rust.ApiReferenceProfile? result;
    try {
      final fd = Saf.isContentUri(ref.path) ? await Saf.openFd(ref.path) : null;
      await for (final ev in rust.analyzeReference(path: ref.path, fd: fd)) {
        referenceProgress = ev.progress;
        if (ev.profile != null) result = ev.profile;
        _owner.notify();
      }
      if (result != null) {
        await ReferenceProfileCache.save(ref.path, result);
      }
      return result;
    } finally {
      analyzingReference = false;
      _owner.notify();
    }
  }

  /// Turn the mastered preview on: analyze the current mix once (whole-file
  /// pass, streamed progress), then feed the running player.
  Future<void> enablePreview() async {
    if (_owner.recording == null || references.isEmpty) return;
    await ensureProfile();
    await _analyzeMix();
    if (mixStats == null) return;
    preview = true;
    mixStatsStale = false;
    _owner.notify();
    _owner.playback.pushLiveParams();
  }

  void disablePreview() {
    preview = false;
    _owner.notify();
    _owner.playback.pushLiveParams();
  }

  /// Re-analyze after mix edits (explicit — never scans behind the user's
  /// back).
  Future<void> refreshPreview() async {
    await _analyzeMix();
    mixStatsStale = false;
    _owner.notify();
    _owner.playback.pushLiveParams();
  }

  Future<void> _analyzeMix() async {
    final rec = _owner.recording;
    if (rec == null) return;
    analyzingMix = true;
    mixAnalysisProgress = 0;
    _owner.notify();
    try {
      await for (final ev in rust.analyzeMixMastering(
        path: rec.path,
        tracks: _owner.tracks.map((t) => t.toApi()).toList(),
        master: _owner.master,
        fd: _owner.isSafSource ? await _owner.inputFdFor(rec.path) : null,
      )) {
        mixAnalysisProgress = ev.progress;
        if (ev.stats != null) mixStats = ev.stats;
        _owner.notify();
      }
    } finally {
      analyzingMix = false;
      _owner.notify();
    }
  }
}
