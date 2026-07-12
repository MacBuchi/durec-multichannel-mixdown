# M3a Plan — Session fix, CI/releases, integration testing, DSP chain

Decisions made with the user (2026-07-12):

- Sessions move to the **app container** (macOS sandbox forbids writing `.durecmix.json` next to the WAV; Android SAF will too). Legacy sibling files are read once as migration.
- M3 is split: **M3a = DSP** (this plan), M3b = FLAC/MP3, trim/fade, BPM, filename templating.
- **CI must be green and releases tagged** before/alongside M3a feature work.
- Automated integration tests use a **small synthetic fixture WAV**, never the real multi-GB recordings.

## Workstream 1 — CI green + release tags

1. `ci.yml` rust job: install `libasound2-dev` (cpal on ubuntu). *(done)*
2. cargokit podspecs: link CoreAudio/AudioToolbox (cpal symbols in the app link). *(done, verified locally)*
3. Watch the four build-matrix jobs; fix Android (NDK/cargokit targets) and Windows if they still fail.
4. `release.yml`: on tag `v*` — build macOS (zip the .app), Windows zip, Android APK; create a GitHub Release with artifacts. Versioning via conventional commits (manual tag for now; release-please later).

## Workstream 2 — Integration-test infrastructure

- `engine/examples/gen_fixture.rs`: writes `fixture_8ch.wav` — 8 ch, 24-bit, 44.1 kHz, ~5 s, deterministic per-channel content (distinct sine/noise per channel), iXML with DUREC-style names incl. a stereo pair (`Keys L`/`Keys R`) and monitor buses (`Phones L`, `Out L`) to exercise pan/exclude heuristics.
- Engine golden tests render the fixture and assert report values (peak, LUFS-I) exactly.
- Flutter `integration_test/`: runs the **real app** on macOS/CI, injects the fixture path (bypassing the native picker by calling `MixerState.open()` / overriding the `file_selector` platform interface), drives real widgets with `WidgetTester` (tap mute, drag fader, export), asserts state + output file. This is the professional pattern (see also: XCUITest for pure-native apps; the picker itself stays a thin manual-test surface).
- The ad-hoc VM-service driver used for the 2026-07-12 verification lives in the session scratchpad; `integration_test` replaces it for CI use.

## Workstream 3 — Session persistence fix (bug from M2 verification)

Engine (`session.rs`): rename `session_path_for` → `legacy_sibling_path`; add `load_or_migrate(session_path, wav_path)` (primary wins, falls back once to legacy sibling); `save` runs `create_dir_all` on the parent.
Bridge (`mixer.rs`): `load_recording(path, session_path)`, `save_session(session_path, …)` — Dart owns location policy.
Dart: add `path_provider`; `lib/state/session_paths.dart` → `Application Support/sessions/<basename>_<fnv1a64(path)>.durecmix.json`; save once after open (persists migrated sessions); **un-swallow the save error** in `mixer_state.dart` (`catch (_) {}` hid this bug).
Update AGENTS.md rule 5. Tests: migration, parent-dir creation, v1 JSON loads with defaults.

## Workstream 4 — DSP chain (engine → bridge → UI)

Shared stateful `MixChain` (new `engine/src/chain.rs`) used identically by render pass 1 (EQ+mix, no limiter, fresh state), render pass 2 (+ master gain + limiter + dither, fresh state), and the playback decode thread (persistent state; `adopt_state_from(old)` on param epoch bump, `reset()` on seek):

per-channel: HPF (RBJ biquad ×1 or ×2, 12/24 dB/oct Butterworth) → low shelf → mid peak → high shelf → gain/pan/ø coeffs → stereo sum → master gain → true-peak limiter → (quantize + TPDF dither, 16-bit only)

- `engine/src/dsp/` split: `biquad.rs` (hand-rolled RBJ, TDF2, f64, param clamps, `magnitude_at` for tests), `limiter.rs`, `dither.rs` (xorshift64* TPDF, no rand dep).
- Limiter: 4× polyphase true-peak detection (BS.1770-4 FIR), release stage + sliding-min + moving-average lookahead (~2.5 ms) → hard ceiling guarantee, sample-aligned output via priming/`flush` (length-preserving renders).
- Loudness: `LoudnessMode::LufsIntegrated(target)`; pass 1 measures with ebur128 `Mode::I|TRUE_PEAK`; pass 2 re-measures the delivered signal (`I|LRA|TRUE_PEAK`) for the report.
- **Playback parity statement**: preview runs EQ + limiter but **no normalization gain** (integrated loudness is unknowable mid-stream); live meters gain LUFS-I (running) and true peak so the user sees what pass 1 will measure.
- Session schema v2 (serde defaults; v1 loads cleanly): per-track `TrackEq {hpf_enabled, hpf_freq, hpf_slope, low/mid/high: EqBand{enabled,freq,gain_db,q}}`; master `{limiter_enabled: true, ceiling_dbtp: −1.0, dither: true}`.
- Bridge DTOs mirror 1:1 (`ApiTrackEq`, `ApiLoudness`, `ApiMaster`, extended report/player state); regenerate FRB.
- UI: EQ chip per strip expanding an inline 4-row panel (HPF/low/mid/high, log-frequency sliders, double-tap reset); loudness dropdown gains −14/−16/−23/custom LUFS; transport meter block gains LUFS-I + TP; export line shows `LUFS-I · TP · LRA · gain`.

### Commit order

0. `fix:` podspec CoreAudio link + `ci:` alsa headers + docs *(this commit)*
1. `fix:` app-container sessions + migration (Workstream 3)
2. `test:` fixture generator + engine golden test (Workstream 2, engine half)
3. `feat(engine):` RBJ biquads
4. `feat(engine):` TrackEq + MixChain, render/playback switched over (bit-identical when EQ off)
5. `feat(engine):` true-peak limiter + TPDF dither
6. `feat(engine):` LUFS targets + limiter/dither in render + extended report
7. `feat(engine):` playback limiter + LUFS-I/TP meters
8. `feat(bridge):` M3a DTOs + codegen
9. `feat(ui):` EQ panels, loudness targets, report, meters
10. `test:` Flutter integration_test with fixture (Workstream 2, app half)
11. `ci:` release.yml + first tag once everything is green

### Key engine test cases

HPF/EQ frequency-response spot checks (−3 dB at fc, slope per octave, `magnitude_at` vs time-domain agreement); chain == MixBus when EQ off; state adoption click-free; limiter holds −1 dBTP on inter-sample-peak fixture (fs/4 sine at 45° phase) and is transparent below ceiling; length/alignment preservation across odd block sizes; TPDF statistics (triangular PDF, variance 1/6); LUFS target hit ±0.5 LU on synthetic render; session v1→v2 migration + legacy sibling migration.
