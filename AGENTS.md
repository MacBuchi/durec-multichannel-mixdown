# Agent Instructions — DurecMix

Cross-platform (macOS/Windows/Android/iOS), fully offline downmixer for RME DUREC multichannel WAV recordings. Successor of [MultiChannelWavMixer](https://github.com/MacBuchi/MultiChannelWavMixer) (Python, stays untouched). The approved rework plan with the full audio-engineering gap analysis lives in `docs/PLAN.md` — read it before large changes.

## Architecture rules

```
engine/          Pure Rust DSP + file I/O — no FFI, no GUI, fully unit-tested
rust/            flutter_rust_bridge API layer — thin DTO conversion ONLY, no logic
lib/             Flutter app (UI, state, platform file access)
rust_builder/    cargokit glue (generated, don't touch)
```

1. **`engine/` must stay free of FFI and UI concerns.** All audio logic and tests live here. New engine functions need tests in `engine/tests/engine_tests.rs`.
2. **`rust/` must stay logic-free** — it only converts bridge DTOs ↔ engine types.
3. **Audio is never fully loaded into RAM** — stream in blocks (`BLOCK_FRAMES`), render in two passes. DUREC files are multi-GB; this must work on phones.
4. After changing `rust/src/api/`, regenerate bindings: `flutter_rust_bridge_codegen generate` (tool is installed via cargo).
5. Session files (`<take>_<pathhash>.durecmix.json`) live in the app container (`Application Support/sessions/`, path built by `lib/state/session_paths.dart`) — sandboxed platforms forbid writing next to the source WAV. A legacy sibling `<take>.durecmix.json` is read once as migration fallback.

## Commands

```sh
cargo test --workspace                          # engine tests
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all
flutter analyze
flutter run -d macos                            # run the app
cargo run -p durecmix-engine --release --example render_demo <in.wav> <out.wav>
cargo run -p durecmix-engine --release --example play_demo <in.wav> [start_s]
```

Rust toolchain: rustup at `~/.cargo` (needs `source ~/.cargo/env` in fresh shells). Flutter SDK: `/Volumes/MacStore/Programming/Flutter/SDK/flutter`. `gh` CLI is NOT installed — CI status must be checked in the GitHub Actions tab.

## Real test files (user's recordings, 34 ch, 24-bit, 44.1 kHz, ~920 MB)

- `/Volumes/MacStore/Durec_Export/2025_10_23/UFX33_00_DuesPaid.WAV`
- `/Volumes/MacStore/Durec_Export/2025_10_23/UFX32_00_WTF.WAV`

Note: a unity mix of all 34 tracks peaks ~+16 dBFS because DUREC also recorded monitor/aux buses (In Ear, Phones, Line Out, *_Out). Real mixes exclude those via `in_mix`.

## Milestone status (2026-07-12)

- **M0 done** — repo bootstrap, FRB template, CI (`ci.yml`: rust checks, flutter analyze, 4-platform build matrix).
- **M1 done** — engine core: streaming WAV/RF64/BW64 reader, iXML parsing (UTF-8-safe), constant-power pan (−3 dB centre), mix bus (solo/mute/polarity/in-mix), two-pass peak-normalised WAV render, session persistence. 31 tests. Validated against both real DUREC files (~5 s per 920 MB render).
- **M2 done, GUI-verified 2026-07-12** — cpal live playback (decode thread → rtrb ring → audio callback; live param updates via epoch counter; ~0.2 s latency), meters (peak L/R, momentary LUFS via ebur128, correlation), streaming waveform analysis, full mixer UI (track strips with fader/pan/ø/M/S/mix + waveforms, transport bar with seek + meters, export with progress + report, session autosave debounce). End-to-end GUI run against UFX33 (real sandboxed file picker → mix toggles/fader gestures → seek + live playback with correct meters → export via save panel): output verified stereo/44.1k/24-bit, full duration, peak exactly −1.00 dBFS. Required linking CoreAudio/AudioToolbox in the cargokit podspecs (cpal symbols). **Known bug found: session autosave (`.durecmix.json` next to the WAV) fails silently under the macOS app sandbox** — fix is the first step of M3a (app-container sessions, see `docs/PLAN-M3a.md`).
- **CI + releases done (2026-07-12)** — all four build-matrix jobs green (fixes: `libasound2-dev` for cpal on ubuntu; CoreAudio podspec link for macOS/iOS; Android minSdk 26 for AAudio). Tag-driven `release.yml` builds macOS zip, Windows zip, Android APK into a GitHub Release; tags `vX.Y.Z`, version is milestone-aligned in pubspec.yaml. CI status can be checked via the GitHub API using the stored git credential (`git credential fill` → token → `/actions/runs`).
- **Integration testing done (2026-07-12)** — `flutter test integration_test -d macos` drives the real app + real engine headlessly (WidgetTester events, no OS input): open → mix toggles → EQ → export at custom LUFS → session round-trip, against a Dart-generated fixture in the sandbox temp dir. Runs in CI on the macOS build job. Keep the suite in ONE file — consecutive app launches per run are flaky on macOS. `engine/examples/gen_fixture.rs` generates a bigger 8-ch fixture for manual testing. Never use the multi-GB real recordings in automated tests.
- **M3a done (2026-07-12)** — session persistence fix (app container), RBJ biquad HPF/EQ per track via shared `MixChain` (identical in render + playback, click-free live tweaks via state adoption), true-peak lookahead limiter (8× oversampled detection, −1 dBTP, sample-aligned/length-preserving), LUFS targets (−14/−16/−23/custom; loudness gain is export-only, preview shows live LUFS-I/TP instead), TPDF dither on 16-bit, extended loudness report (LUFS-I/TP/LRA/gain), EQ panels + loudness dropdown + meters in the UI. 50 engine tests + integration test. Plan: `docs/PLAN-M3a.md`.
- **M3b done (2026-07-12, PRs #1 #2, v0.4.0)** — FLAC 16/24 (flacenc, streaming frame-by-frame) + MP3 320 (LAME; reserve the output buffer or LAME segfaults), trim in/out + 80 ms fades (position-aware, measured pre-normalisation), BPM detection (onset autocorrelation; validated exactly against the old tool: UFX33→161, UFX32→103), filename templating `{take}_{target}_{bpm}BPM_{timestamp}.{ext}`.
- **M4 Android done, device-verified 2026-07-12 (v0.5.1 on the user's phone: WAV open + MP3 export OK)** — SAF end-to-end: Kotlin MethodChannel `durecmix/saf` (pick/create/openFd/displayName, persistable read permission), engine `InputHandle`/`OutputHandle` (path or raw fd; one fresh fd per engine call, ownership moves to Rust), bridge fd params on load/analyze/play/render. Fixed the v0.3.0 on-device crash (file_selector copied the multi-GB file).
- **M4 iOS + phone (code complete, PRs #9 #11 #12, NEEDS DEVICE TEST)** — iOS Files picker in `ios/Runner/AppDelegate.swift` (`durecmix/files` channel: pick in place with `asCopy:false` + session-long security scope, export via tmp + move picker; iOS deployment target raised to 14.0); phone layout (<640 px: overflow-menu app bar, two-row transport, batch is desktop-only); background export (Android `ExportService` dataSync foreground service with progress notification, iOS `beginBackgroundTask`). Verified locally with `flutter build ios --no-codesign`.
- **M5 done except signed releases (PRs #4 #6 #7 #8)** — stereo-pair linking (default on, app-bar toggle; gain/mute/solo/EQ mirror, pans inverted) with per-pair unlink (link chip on paired strips; relink copies the tapped side), monitor-feed auto-exclusion on fresh sessions (In Ear/Phones/IEM/Talkback/Line Out/Monitor; `*_Out` stems stay in), A/B mix snapshots (app-bar A/B, tap = store/recall, long-press/right-click = overwrite), batch export queue (desktop: jobs = loudness+format, sequential renders into one folder). **Remaining:** signed releases (needs Apple Developer account — user decision); batch export on phones (SAF tree grant exists since the WAV browser — plumbing still open).
- **WAV browser done (v0.7.0)** — in-app folder browser: `wav::probe` (header-only metadata incl. iXML track count), SAF `pickDirectory`/`listDirectory` (ACTION_OPEN_DOCUMENT_TREE, persistable READ|WRITE grant, name-based .wav filter — MIME is octet-stream on sticks), `WavBrowser` state (sequential lazy probe queue, cache, sort name/date persisted in `settings.json`), `WavBrowserPage`, app-bar filename tap = switch takes. Session keys hash the SAF documentId (not the full URI) with a one-time rename migration so mixes survive picker↔browser. iOS keeps the system picker (folder scopes deferred until a device exists).
- **Multi-file export done (v0.8.0)** — browser checkboxes (multichannel pre-ticked on probe), `MultiExportRunner` (`lib/state/batch_export.dart`): sequential renders of all ticked takes with the CURRENT mix mapped by track NAME onto each file (index fallback; trim/fades deliberately not applied — take-specific; sessions of other files never written), output into a `Mixdown/` subfolder (SAF: `ensureDirectory`/`createFileInDirectory` — use the returned URI, providers may rename), per-row progress/✓/error, result bar with system share sheet (`shareFiles`, ACTION_SEND_MULTIPLE + READ grant); single-export snackbar also offers Share on Android. This closes the former "batch export on phones" remainder.

## Release signing (Android)

Release APKs are signed with a **stable keystore** so downloaded APKs update an existing installation (before v0.7.2 every CI run used a fresh debug key → signature mismatch, uninstall required). The keystore lives on the user's machine at `~/durecmix-keys/` (keystore + PASSWORDS.txt — **must be backed up; losing it permanently breaks updates**) and in the repo secrets `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD`. `android/key.properties` (gitignored) activates it locally; without it builds fall back to debug signing (PR CI, `flutter run --release`). The release workflow hard-fails if the secrets are missing. `applicationId`/`namespace` is `de.macbuchi.durecmix` (renamed from com.example in v0.7.2 — same forced reinstall); iOS/macOS bundle ids deliberately stay `com.example.durecmix` (a macOS change would orphan the sandbox container with the user's sessions).

## Workflow

Conventional Commits (`feat:`/`fix:`/`feat!:`/`chore:`/`ci:`/`docs:`/`test:`/`refactor:`). **Feature branches + PRs** (since M3b): branch `feat/<topic>` or `fix/<topic>` off `main`, push, open a PR, merge only when the full CI matrix is green (squash-merge, PR title in conventional-commit form). Stacked PRs are fine: base each on its predecessor; GitHub retargets to `main` as they merge in order. PRs are opened via the GitHub API with the stored git credential (`gh` CLI is not installed); **merging is done by the user** (agent self-merge is blocked by policy since 2026-07-12). Releases: bump `pubspec.yaml` on `main`, tag `vX.Y.Z` → `release.yml` publishes artifacts. Remote: https://github.com/MacBuchi/durec-multichannel-mixdown (private).
