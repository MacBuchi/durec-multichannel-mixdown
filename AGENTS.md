# Agent Instructions — Mixstack

Cross-platform (macOS/Windows/Android/iOS/web), fully offline mixdown of multichannel WAV recordings. Successor of [MultiChannelWavMixer](https://github.com/MacBuchi/MultiChannelWavMixer) (Python, stays untouched). The approved rework plan with the full audio-engineering gap analysis lives in `docs/PLAN.md` — read it before large changes.

**Renamed from DurecMix in v0.20.0** (`docs/PLAN-PLAYSTORE.md` §1 carries the reasoning). The engine reads any interleaved RIFF/RF64/BW64 at any channel count, so the name no longer claims one vendor's recorder. RME and DUREC may still be **named descriptively** — "for recordings from the RME DUREC" is referential use under § 23 Abs. 1 Nr. 3 MarkenG / Art. 14 Abs. 1 lit. c UMV — but never as part of the product name, an identifier or a store title. What deliberately kept the old name: the Dart package `durecmix` (invisible, in every import), the Rust crates `durecmix-engine`/`rust_lib_durecmix`, the `.durecmix.json` session suffix and the web IndexedDB name (both would orphan saved mixes), the `durecmix/saf` and `durecmix/files` method channels, `DURECMIX_FEEDBACK_TOKEN` (a GitHub secret name), the macOS bundle id, and the repository itself.

Cross-project guidelines (architecture, state, testing, CI, signing, in-app update/feedback) live in the DocuHub at `/Volumes/MacStore/Programming/ProgrammingGuidelineDocuHub/`. This file covers what Mixstack does differently or additionally.

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
5. **There IS a web target** (since v0.13.0 — it was ruled out before, see "The PWA" below). Nothing platform-specific may be reached directly from shared code: `dart:io`, cpal playback, SAF and the native pickers all go through the platform shim, and any capability the web lacks is a `const` flag there, never an exception at the call site.
6. **The preview must sound like the export.** Both run the same chain (`PreviewStage` / render pass 2) in the same order, and the normalisation gain has exactly one implementation — `render::normalisation_gain`, fed by a measurement of the mix (`analyze_mix_level`, or `MixLevelScan` in the browser). It reaches the players inside `ApiMaster.preview_norm_gain`, which is pushed on every parameter change. A second gain formula anywhere is how "what you hear" and "what you get" drift apart; the guard is `preview_gain_equals_the_gain_the_render_applies`.
7. Session files (`<take>_<pathhash>.durecmix.json`) live in the app container (`Application Support/sessions/`, path built by `lib/state/session_paths.dart`) — sandboxed platforms forbid writing next to the source WAV. A legacy sibling `<take>.durecmix.json` is read once as migration fallback.

## Commands

```sh
cargo test --workspace                          # engine tests
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all
flutter analyze
flutter run -d macos                            # run the app
cargo run -p durecmix-engine --release --example render_demo <in.wav> <out.wav>
cargo run -p durecmix-engine --release --example play_demo <in.wav> [start_s]
./tool/build_web_engine.sh && flutter build web  # the PWA (see "The PWA")
```

Rust toolchain: rustup at `~/.cargo` (needs `source ~/.cargo/env` in fresh shells). Flutter SDK: `/Volumes/MacStore/Programming/Flutter/SDK/flutter`. `gh` CLI is installed and authenticated — use it for CI status (`gh run list`, `gh run view`), issues and PRs.

**cpal's AAudio backend (≥0.17) needs the ndk_context handshake — do not remove it.** `MainActivity.onCreate` hands JavaVM + application context through a JNI export (`rust/src/android.rs`) to `ndk_context::initialize_android_context`, because cpal queries `AudioManager` over JNI when building an output stream and `ndk_context::android_context()` *panics* when unset — nothing else initializes it in a Flutter app (the `.so` is `dlopen`ed by Dart, `JNI_OnLoad` never fires). v0.12.10–v0.12.12 shipped with every Android play tap dead for exactly this (issue #88): desktop is unaffected, so cargo test, clippy and a macOS `play_demo` listen all stayed green. The regression guard is the Android-only playback section in `integration_test/app_test.dart` — it asserts the position outruns the ~0.2 s ring buffer (proves the AAudio callback drains frames) and that meters see signal. **Run it on a device/emulator for every audio-stack change** (`flutter test integration_test -d <device-id>`); CI only builds the APK and can not catch any of this.

## Real test files (user's recordings, 34 ch, 24-bit, 44.1 kHz, ~920 MB)

- `/Volumes/MacStore/Durec_Export/2025_10_23/UFX33_00_DuesPaid.WAV`
- `/Volumes/MacStore/Durec_Export/2025_10_23/UFX32_00_WTF.WAV`

**The 34 channels are these recordings, not the DUREC format.** Track count and track names come from the attached RME interface and its configuration — UCX II records up to 40, UFX II/III considerably more, and a multisample recording reaches a few **hundred**. Only the channels selected in the interface land in the file. Never hard-code a channel count, a channel limit or a track *name* (the one exception the user sanctioned is the trailing `L`/`R` of a stereo pair, as in `Keys L`/`Keys R`, which the iXML naming convention guarantees: `default_pan_for_name`, `stereo_pair_base`).

**Nothing may scale worse than linearly with the channel count** — at 34 a quadratic term is invisible, at 200 it is the whole cost. Measure it instead of assuming: `cargo run -p durecmix-engine --release --example channel_scaling 200 0.0`. Measured 2026-08-04 on the user's Mac (native, release): 34 ch → 114× realtime, 200 ch → 53×, 500 ch → 23×, and a parameter change stays under 0.02 ms. Two traps already found and removed this way, both in `MixChain`: building the "no strip here" list with `any()` per channel, and `adopt_state_from` searching the old strips linearly per strip — 40 000 comparisons per fader move at 200 tracks. Metering silent channels also has to be **one pass over the block**, not one pass per channel: a frame is contiguous, a strided walk per channel is a cache miss per sample.

Note: a unity mix of all tracks of these takes peaks ~+16 dBFS because DUREC also recorded monitor/aux buses (In Ear, Phones, Line Out, *_Out) alongside the sources. Excluding them is the user's call per take via `in_mix` — the app does not guess it from names.

## Milestone status (2026-07-12)

- **M0 done** — repo bootstrap, FRB template, CI (`ci.yml`: rust checks, flutter analyze, 4-platform build matrix).
- **M1 done** — engine core: streaming WAV/RF64/BW64 reader, iXML parsing (UTF-8-safe), constant-power pan (−3 dB centre), mix bus (solo/mute/polarity/in-mix), two-pass peak-normalised WAV render, session persistence. 31 tests. Validated against both real DUREC files (~5 s per 920 MB render).
- **M2 done, GUI-verified 2026-07-12** — cpal live playback (decode thread → rtrb ring → audio callback; live param updates via epoch counter; ~0.2 s latency), meters (peak L/R, momentary LUFS via ebur128, correlation), streaming waveform analysis, full mixer UI (track strips with fader/pan/ø/M/S/mix + waveforms, transport bar with seek + meters, export with progress + report, session autosave debounce). End-to-end GUI run against UFX33 (real sandboxed file picker → mix toggles/fader gestures → seek + live playback with correct meters → export via save panel): output verified stereo/44.1k/24-bit, full duration, peak exactly −1.00 dBFS. Required linking CoreAudio/AudioToolbox in the cargokit podspecs (cpal symbols). **Known bug found: session autosave (`.durecmix.json` next to the WAV) fails silently under the macOS app sandbox** — fix is the first step of M3a (app-container sessions, see `docs/PLAN-M3a.md`).
- **CI + releases done (2026-07-12)** — all four build-matrix jobs green (fixes: `libasound2-dev` for cpal on ubuntu; CoreAudio podspec link for macOS/iOS; Android minSdk 26 for AAudio). Tag-driven `release.yml` builds macOS zip, Windows zip, Android APK into a GitHub Release; tags `vX.Y.Z`, version is milestone-aligned in pubspec.yaml. CI status can be checked via the GitHub API using the stored git credential (`git credential fill` → token → `/actions/runs`).
- **Integration testing done (2026-07-12)** — `flutter test integration_test -d macos` drives the real app + real engine headlessly (WidgetTester events, no OS input): open → mix toggles → EQ → export at custom LUFS → session round-trip, against a Dart-generated fixture in the sandbox temp dir. Runs in CI on the macOS build job. Keep the suite in ONE file — consecutive app launches per run are flaky on macOS. `engine/examples/gen_fixture.rs` generates a bigger 8-ch fixture for manual testing. Never use the multi-GB real recordings in automated tests.
- **M3a done (2026-07-12)** — session persistence fix (app container), RBJ biquad HPF/EQ per track via shared `MixChain` (identical in render + playback, click-free live tweaks via state adoption), true-peak lookahead limiter (8× oversampled detection, −1 dBTP, sample-aligned/length-preserving), LUFS targets (−14/−16/−23/custom; loudness gain is export-only, preview shows live LUFS-I/TP instead), TPDF dither on 16-bit, extended loudness report (LUFS-I/TP/LRA/gain), EQ panels + loudness dropdown + meters in the UI. 50 engine tests + integration test. Plan: `docs/PLAN-M3a.md`.
- **M3b done (2026-07-12, PRs #1 #2, v0.4.0)** — FLAC 16/24 (flacenc, streaming frame-by-frame) + MP3 320 (LAME; reserve the output buffer or LAME segfaults), trim in/out + 80 ms fades (position-aware, measured pre-normalisation), BPM detection (onset autocorrelation; validated exactly against the old tool: UFX33→161, UFX32→103), filename templating `{take}_{target}_{bpm}BPM_{timestamp}.{ext}`.
- **M4 Android done, device-verified 2026-07-12 (v0.5.1 on the user's phone: WAV open + MP3 export OK)** — SAF end-to-end: Kotlin MethodChannel `durecmix/saf` (pick/create/openFd/displayName, persistable read permission), engine `InputHandle`/`OutputHandle` (path or raw fd; one fresh fd per engine call, ownership moves to Rust), bridge fd params on load/analyze/play/render. Fixed the v0.3.0 on-device crash (file_selector copied the multi-GB file).
- **M4 iOS + phone (PRs #9 #11 #12, device-verified 2026-07-26)** — iOS Files picker in `ios/Runner/AppDelegate.swift` (`durecmix/files` channel: pick in place with `asCopy:false` + session-long security scope, export via tmp + move picker; iOS deployment target raised to 14.0); phone layout (<640 px: overflow-menu app bar, two-row transport, batch is desktop-only); background export (Android `ExportService` dataSync foreground service with progress notification, iOS `beginBackgroundTask`). **Verified on the user's iPad Air 4 (iOS 26.5.2):** a 1.2 GB take opened through the Files picker, iXML track names and count correct, and playback is audible — cpal's CoreAudio backend needs no AVAudioSession setup of its own on iOS, unlike the Android handshake above. The PWA runs on the same device. Still untested on iOS: export via the move picker, background export, and the folder-scope work the system picker replaces (`canPickFolders` is false there).
- **M5 done except signed releases (PRs #4 #6 #7 #8)** — stereo-pair linking (default on, app-bar toggle; gain/mute/solo/EQ mirror, pans inverted) with per-pair unlink (link chip on paired strips; relink copies the tapped side), monitor-feed auto-exclusion on fresh sessions (**removed again in v0.12.16** — track names are free text from the interface configuration, so no name may decide anything; see `Session::from_track_info`), A/B mix snapshots (app-bar A/B, tap = store/recall, long-press/right-click = overwrite), batch export queue (desktop: jobs = loudness+format, sequential renders into one folder). **Remaining:** signed releases (needs Apple Developer account — user decision); batch export on phones (SAF tree grant exists since the WAV browser — plumbing still open).
- **WAV browser done (v0.7.0)** — in-app folder browser: `wav::probe` (header-only metadata incl. iXML track count), SAF `pickDirectory`/`listDirectory` (ACTION_OPEN_DOCUMENT_TREE, persistable READ|WRITE grant, name-based .wav filter — MIME is octet-stream on sticks), `WavBrowser` state (sequential lazy probe queue, cache, sort name/date persisted in `settings.json`), `WavBrowserPage`, app-bar filename tap = switch takes. Session keys hash the SAF documentId (not the full URI) with a one-time rename migration so mixes survive picker↔browser. iOS keeps the system picker (folder scopes deferred until a device exists).
- **Reference mastering (PRs #28–#33, 2026-07-18, stacked chain — NEEDS MERGE + LISTENING TEST)** — Matchering-style mastering as a clean-room Rust reimplementation (no GPL code; Matchering is GPL-3.0): the export is matched to a user-chosen reference track (any WAV/FLAC/MP3/OGG via Symphonia) in loudness, tonality (mid/side matching EQ: loudest-15s-pieces average spectra → ±18 dB clamped, log-frequency-smoothed curve → 4095-tap linear-phase FIRs via `dsp/fir.rs` overlap-add) and stereo width; level match is analytic (Parseval) so mastering adds ZERO extra passes (analysis rides render pass 1, FIRs ride pass 2 before the limiter; `LoudnessMode` is bypassed while active). Reference profiles (`mastering::ReferenceProfile`, versioned) are cached as JSON per file on the Dart side. UI: wand icon → mastering dialog; loudness controls grey out while active; report shows "matched to <ref> (±x dB)". `SESSION_VERSION` 3. Also fixed a real FLAC-export spec violation (STREAMINFO min_blocksize counted the short final frame — strict decoders like Symphonia refused our FLACs). Remaining: user merge #28→#33 in order, macOS listening test with a real DUREC take + commercial reference, one Android on-device check (SAF-picked MP3 reference).
- **Multi-file export done (v0.8.0)** — browser checkboxes (multichannel pre-ticked on probe), `MultiExportRunner` (`lib/state/batch_export.dart`): sequential renders of all ticked takes with the CURRENT mix mapped by track NAME onto each file (index fallback; trim/fades deliberately not applied — take-specific; sessions of other files never written), output into a `Mixdown/` subfolder (SAF: `ensureDirectory`/`createFileInDirectory` — use the returned URI, providers may rename), per-row progress/✓/error, result bar with system share sheet (`shareFiles`, ACTION_SEND_MULTIPLE + READ grant); single-export snackbar also offers Share on Android. This closes the former "batch export on phones" remainder.
- **PWA (v0.13.0, PRs #95–#112, plan `docs/PLAN-PWA.md`)** — the app runs in a browser with the same engine: open, analyse, mix, preview and export a multi-GB take, offline-capable, deployed to GitHub Pages. Device-verified on the user's iPad Air with a 1.35 GB, 34-channel take. Details below; **issue #111 is closed as of v0.16.0** — persistence (v0.14.0), reference mastering (v0.15.0) and multi-file export (v0.16.0) all work in the browser, and #114 (fader clicks on the iPad) was fixed in two rounds (v0.13.1 measures the device, v0.13.3 removes a splice and learns from actual dropouts).

## Per-track meters (#115, v0.17.0)

One measurement serves both modes. `MixChain` reports each **source channel's** peak post-EQ and pre-fader; the post-fader reading is exactly that times the track's gain, so Dart derives it and the pre/post switch costs no engine call and no second measurement. Three things follow from that, and all three are load-bearing:

- **Metering is off by default in `MixChain` and only `PreviewStage` enables it.** The render has no meters and must not pay for them.
- **Muted, soloed-away and out-of-mix tracks are metered too**, because the decision was that their bar greys out rather than disappears — seeing that a muted track carries signal is the point. `resolve_channels` drops exactly those tracks, so they have no strip and are read straight from the input: their meter therefore ignores their EQ. That asymmetry is deliberate and documented at the field.
- **The ballistics live in the engine** (`TRACK_METER_RELEASE_DB_PER_S`), not the UI: only the engine knows how much time a block covers, while the UI polls on a timer that says nothing about how far playback advanced. Without a release a peak between two 30 Hz polls would be invisible.

Natively the values travel as a `Vec<AtomicU32>` so the decode thread still never blocks; `PlayerSnapshot` stays `Copy` and the peaks come through their own accessor. The cost is one abs+max per sample on channels that are being processed anyway — the instrument for checking it on a real device is the mix rate in **Settings → Playback diagnostics**.

## The PWA (web target)

`web/` holds the shell (`index.html`, `manifest.json`, `coi-sw.js`, `audio-pump.js`); the engine is the *same* Rust crate compiled to threaded wasm. Read `docs/PLAN-PWA.md` before touching any of it — it records the measurements and the dead ends.

- **Build the engine with `tool/build_web_engine.sh`, not `flutter_rust_bridge_codegen build-web`.** Threaded wasm needs nightly + `rust-src` + `-Z build-std`, and current nightlies no longer derive `--shared-memory` from `+atomics`: without the explicit link args the module gets a non-shared memory and FRB's worker pool dies at startup with `DataCloneError: #<Memory> could not be cloned`. Release by default — a `--dev` bundle is ~7× larger (4.8 MB vs 674 KB) and measurably slower.
- **`flutter build web` does not copy `web/pkg`** (wasm-pack leaves a catch-all `.gitignore` there). Deploys stage it by hand — see `pages.yml`; forget it and the page loads, then dies on a missing wasm.
- **Threads need COOP/COEP** (`same-origin` / `require-corp`), which GitHub Pages does not send: `web/coi-sw.js` installs them from a service worker (it also serves the offline start, network-first). Locally: `flutter run -d web-server --web-header=…`.
- ⭐ **Before touching a byte-range path, run it against a real take:** `cargo run -p durecmix-engine --release --example browser_parity <take.wav>` renders the file both ways and compares the bytes, plus the level scan and the mastering analysis. The equality tests in `engine/tests` use synthetic two-channel fixtures; a DUREC recording is 32–34 channels, ~1 GB, with iXML *behind* the payload. Verified on UFX33/UFX31/UFX05/UFX24 (2026-08-04) — all four byte-identical, WAV24 and FLAC24, with a bent mix and a trim.
- **No file paths in a browser.** Every engine entry point has a byte-range twin fed by a per-file `read` callback: `probe_from_chunks`, `loadRecordingFromChunks`, `renderByRanges`. Fetch the Blob **once** and slice it — re-fetching per block cost 107 s on a 376 MB take, versus 3.7 s.
- **Playback shares `PreviewStage` with the native player** (`WebPlayer` + an AudioWorklet ring buffer, pumped ~200 ms of audio per 40 ms tick). That sharing is load-bearing: the byte-equality tests in `engine/tests` assert the browser preview is **sample-identical** to the rendered file — with EQ, trim and (since #112) the normalisation gain. **Including a mastering plan since v0.15.0** — `byte_driven_render_matches_the_file_render_with_a_mastering_plan` and `pushed_mastering_scan_matches_the_file_scan`; nothing about the browser's audio path is unproven any more.
- **A capability the web lacks is a `const` flag in the shim, never an exception at the call site** — `canPickFolders`, `canPlayAudio`, `canExportAudio`, `canEncodeMp3`, `canMasterToReference`, `hasNetwork` in `lib/io/platform_shim_web.dart` / `_io.dart`. An unported stage either hides its entry point or answers the tap with one sentence. This rule exists because it was broken repeatedly (#99, #110): buttons that threw a raw `AnyhowException` into the app bar, a batch dialog that did nothing because `getDirectoryPath()` is null, a picker that silently re-read the *previous* recording, "You're up to date." from an update check that never ran. **When you port a capability, find every caller** — the title tap in the app bar was missed once and stayed dead (iPad test, 2026-07-26).
- **The app container persists through `FileStore` (v0.14.0)**, a map in memory mirrored into IndexedDB — the map stays the source of truth because `fileExistsSync`/`renameFileSync`/`deleteFileSync` are synchronous and every web store is not. Two rules there: hydration must finish before the first read (`initPlatformStorage()` in `main`, ahead of `AppSettings.load()`), and **only paths under the app-support prefix are mirrored** — a rendered export is hundreds of megabytes and must never reach a quota-limited store. A browser that refuses storage (private window) degrades to the old in-memory behaviour and the Settings dialog says so rather than promising persistence.
- **The recording itself cannot be persisted.** Safari has no File System Access API, so there is no handle to store: after a reload the file is picked again. It re-attaches by itself because `_lazyRecording` keys a source on the file *name* and the session path hashes that — do not "improve" that key into something per-pick, or every reload would orphan the mix.
- **A reference track travels whole, a recording never does.** Reference mastering works in the browser because a reference song is a few megabytes: `analyze_reference_from_bytes` takes the file in one bridge call (Symphonia over a `Cursor`), and the mix analysis reuses the same pushed pass as the level scan (`MixScan`, `want_stats`). Do not generalise the whole-file shortcut to recordings — that is exactly the mistake the byte-range twins exist to prevent.
- **A browser cannot write into a folder**, so the multi-file export downloads each finished mixdown instead — `MultiExportRunner.run` takes a *nullable* folder, and null is the browser's mode rather than a missing argument. Per file as it finishes, not one archive at the end: a cancelled run keeps what it produced, and nothing has to be held in memory while the rest renders.
- **MP3 exists on web, from a different encoder.** LAME is C and `wasm32-unknown-unknown` has no libc, so the browser encodes with Shine (`shine-rs`, Cargo feature `mp3-shine`); `engine/src/mp3.rs` holds both behind one `Mp3Writer` and prefers LAME wherever it builds, so a native build can never ship the lesser encoder. Shine has no psychoacoustic model — the difference is named in the UI (`mp3EncoderNote`), never papered over, and the MP3 test tolerances are per-encoder rather than loosened. Still absent on web: anything needing a target folder.

## Errors, logging and what a bug report carries

`lib/state/debug_log.dart` is the app's **one** logger plus a 200-entry ring buffer; `main.dart` installs `FlutterError.onError` and `PlatformDispatcher.instance.onError` before anything else can fail. Until v0.18.0 there was none of this, and it cost a real diagnosis: when the app vanished on the iPad after eight minutes, nothing distinguished a system kill from a crash.

- **There is no crash service and there should not be one.** Mixstack has no backend at all, which is a documented strength — so the sink is the bug report the user files anyway: `submitFeedback` attaches `DebugLog.recent()` to a **bug** report (never a feature request). That is the DocuHub's route A in its backend-free form.
- **Everything that travels goes through `redactPaths`.** The repo is public and the PII rule is explicit: stack traces and log lines may be sent, paths carrying a user name may not. The name segment deliberately runs to the next separator *including spaces* — a Windows home is the display name (`C:\Users\Jane Doe\…`), and stopping at the space published half of it. A test pins that.
- **Log where an error already reaches the UI**, not everywhere: the sites that set `error =` are exactly the diagnosable ones. `DebugLog.info` is for milestones, not per-frame — the ring is 200 deep and a report wants the span around the failure.
- **`recent()` truncates from the front.** The entries next to the failure are the ones worth keeping; a report that drops them to make room for start-up is useless.
- ⚠️ **The pre-filled browser form is a GET.** Its log is capped far shorter than the API path's (`urlLogChars`), because browsers drop long query strings well before GitHub's own limit — and a field id that the issue form does not declare is dropped **without a word**. Both the `log` field and the `Web` platform option had to be added to `.github/ISSUE_TEMPLATE/bug_report.yml`; every report filed from the browser since v0.13.0 had silently lost its platform for exactly that reason.

## The Android emulator (screenshots, on-device tests)

The SDK is **not** at `~/Library/Android/sdk` — Homebrew put it at
`/opt/homebrew/share/android-commandlinetools`. `adb` and `emulator` are not on
PATH; export `ANDROID_HOME` and prepend `$ANDROID_HOME/emulator` and
`$ANDROID_HOME/platform-tools` first, or nothing below works. The AVD
`Pixel_7_Pro_API36` exists (arm64-v8a, android-36.1, google_apis) and is the
right profile; start your own instance on a non-default port
(`-port 5560`) so the user's is never commandeered.

- ⚠️ **Never `-no-window`.** The app installs, `MainActivity` launches, and the
  activity exits immediately — logcat says only `Activity top resumed state
  loss timeout … isExiting`, with no crash and no Dart output, and the test
  hangs until the script's 20-minute poll gives up. With a window it launches
  and stays. Measured 2026-08-17.
- **A run must not be attached to a tool call that can be reaped.** The device
  branch of `make_screenshots.sh` backgrounds `flutter test` and polls its log;
  when the enclosing shell dies the script is cut off mid-poll and reports
  neither success nor failure. Detach with `nohup … & disown` and poll the log
  file instead.
- **Still unresolved as of 2026-08-17:** even with a window and detached, the
  Android screenshot run never reaches `SCREENSHOT_DIR` — the harness hangs
  after `Installing …`, and the first attempt failed outright with `Failed to
  start Dart Development Service`. `--no-dds` did not help. The macOS run is
  unaffected. Whoever picks this up next: check whether a plain
  `flutter run -d emulator-5560` attaches at all before touching the script.
  **The emulator is no longer needed for screenshots** — see below — so this
  only blocks the on-device playback test.
- The AVD carries other projects' apps (PilzBuddy was installed on it), so it
  is shared state — do not assume a clean device.

## Documentation & screenshots

**Phone screenshots come from the browser, not a device** — `tool/screenshots_web.sh`
builds the PWA, serves it with COOP/COEP and drives it with Playwright, the way
MitFahrBar does it. The phone layout is the same (the breakpoint is 640 logical
px, the viewport is 432), and it needs no emulator. Three things are
load-bearing there:

- **432×768 at `deviceScaleFactor: 2.5` lands on exactly 1080×1920** — Play's
  recommended resolution and exactly 9:16, so nothing has to be padded
  afterwards. The device shots were 840×1720, which is 1:2.048 and over Play's
  2:1 ceiling.
- **The `filechooser` handler must be registered before the click.** Playwright
  only intercepts the dialog when something is listening; without it the dialog
  is discarded, the app never receives a file, and the run dies in a timeout
  that names the wrong thing.
- **`colorScheme: 'dark'` and `reducedMotion: 'reduce'`** — the first so the
  phone shots match the dark tablet ones, the second so two runs produce the
  same image instead of catching the logo ripple at a different phase.

⚠️ **It writes `phone_web.png` / `phone_menu_web.png`, deliberately not the
`*_android.png` the docs use.** Those have annotated twins whose marker rects
only fall out of the live widget tree during the integration test; the browser
path cannot produce them, and overwriting only the plain half would leave image
and legend showing two different renderings. The `_web` pair is the store
source, and `tool/store_assets.py` prefers it.

User docs live in `docs/GUIDE.md` (annotated walkthrough) and README. Screenshots are generated, never hand-made: `tool/make_screenshots.sh` (desktop) and `tool/make_screenshots.sh -d <emulator-id>` (Android phone shots; boots nothing itself — start an emulator first, never commandeer one the user is working on). The integration test's SCREENSHOTS mode renders every screen from the doc fixture and dumps per-control marker rects from the live widget tree; `tool/annotate_screenshots.py` (pillow) draws the numbered callouts, and its stdout legends feed the numbered lists in GUIDE.md — regenerate both together after UI changes. Local Android debug builds skip the x86 ABIs via `CARGOKIT_NO_EMULATOR_ABIS` (cargokit patch; LAME's configure breaks cross-compiling i686 on Apple Silicon). Housekeeping treats `docs/`, `*.md`, `.github/`, `engine/examples`, `engine/tests`, `integration_test/`, `tool/` as non-shipping.

## In-app feedback & update check

`lib/state/feedback.dart` files GitHub issues; `lib/state/update_check.dart` polls the latest release; `lib/ui/app_banners.dart` renders the two dismissible banners above the mixer (session-only dismissal, PilzBuddy-style — no Supabase). The repo is public, so the update check is tokenless. Feedback uses a fine-grained PAT (this repo only, Issues: read+write) injected at build time via `--dart-define=DURECMIX_FEEDBACK_TOKEN` (release.yml, from the same-named repo secret); **without the secret the app builds fine and falls back to opening the pre-filled issue-form URL in the browser** — so PR/debug builds never carry a token. Issue bodies mirror the `.github/ISSUE_TEMPLATE/*.yml` form sections (Description / App version / Platform) so API- and browser-filed issues look identical. To set up direct filing: create the PAT, add it as secret `DURECMIX_FEEDBACK_TOKEN`; rotate by replacing the secret (no app change). Integration/CI never hits the network — `UpdateCheck.enabled=false` in the test setup. Deps added: `package_info_plus`, `url_launcher`, `ota_update`.

**Android in-app install requires FOUR manifest/Gradle pieces that must stay together — see issue #56, currently incomplete:** `INTERNET` and `REQUEST_INSTALL_PACKAGES` permissions; a `<provider>` for `androidx.core.content.FileProvider` with authority **exactly** `${applicationId}.ota_update_provider`; `android/app/src/main/res/xml/filepaths.xml` containing `<files-path name="ota_update" path="ota_update/"/>` (the plugin writes the APK to internal `files/ota_update/`); and a `<queries>` entry for `VIEW`/`https` so the browser fallback survives Android 11+ package visibility. Core library desugaring is already enabled in `build.gradle.kts` — it is required by the plugin. **Without the FileProvider the app dies with a native `IllegalArgumentException` right after the download completes** — the failure never appears in a debug run, only on a user's first real update (PilzBuddy hit exactly this: MacBuchi/pilzbuddy#21). Guard these with a manifest regression test (see Testing) and verify on a real device before shipping an update-related change.

## The Play Store build (`docs/PLAN-PLAYSTORE.md`)

Android ships through **two** channels now, and they differ in exactly one
thing: whether the app may install its own updates. `--dart-define=PLAY_STORE=true`
is the single switch for both halves — Gradle swaps `src/main/AndroidManifest.xml`
for `AndroidManifest-play.xml`, and Dart gets `isPlayStoreBuild`, `canSelfUpdate`
and `canCheckForUpdates` in the shim.

- **One flag, not two.** Two separate switches is precisely how you get a build
  that strips the permission and still offers "Update now" — or the reverse,
  which is a rejected upload. Gradle prints which manifest it picked, because
  the failure is otherwise silent until a review weeks later.
- **Removing our own `REQUEST_INSTALL_PACKAGES` does nothing.** The ota_update
  plugin declares it — plus `INSTALL_PACKAGES` (signature-level!),
  `WRITE_EXTERNAL_STORAGE`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` — in
  *its* manifest, so the merger adds them to any build with the plugin on the
  classpath. They must be removed with `tools:node="remove"`, and
  `READ_EXTERNAL_STORAGE` comes along implicitly (no source in the blame
  report) and has to go too.
- **Prove it on the build output, not the sources.** `aapt2 dump xmltree` cannot
  read an AAB (protobuf manifest, "could not identify format of APK"); read
  `build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml`
  instead. `test/android_manifest_test.dart` holds the two manifests against
  each other so a permission added to one but not the other fails a test rather
  than a release.
- **`versionCode` is derived from the semver** (0.19.0 → 19000), not from
  pubspec's `+N` — that has been `+1` since M0 and nothing bumps it. Android
  tolerates reinstalling the same version code, so the GitHub APK never
  noticed; Play rejects a reused one, so the **second** release would be the
  one that fails.
- **No feedback token in a Play build.** `_token` is a compile-time constant
  and sits extractable in the shipped bundle, so `submitFeedback` takes the
  browser-form route there regardless of what the workflow injects.
- **XML comments may not contain `--`.** Writing the dart-define into a comment
  makes the merger fail with a bare "Error parsing" and no line number; a test
  pins it.

## Release signing (Android)

Release APKs are signed with a **stable keystore** so downloaded APKs update an existing installation (before v0.7.2 every CI run used a fresh debug key → signature mismatch, uninstall required). The keystore lives on the user's machine at `~/durecmix-keys/` (keystore + PASSWORDS.txt — **must be backed up; losing it permanently breaks updates**) and in the repo secrets `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD`. `android/key.properties` (gitignored) activates it locally; without it builds fall back to debug signing (PR CI, `flutter run --release`). The release workflow hard-fails if the secrets are missing. `applicationId`/`namespace` is `de.macbuchi.durecmix` (renamed from com.example in v0.7.2 — same forced reinstall); the **macOS** bundle id deliberately stays `com.example.durecmix` (a change would orphan the sandbox container with the user's sessions). iOS moved to `de.macbuchi.durecmix` in 2026-07 because Apple App IDs are globally unique and `com.example.*` is long taken — see below.

## iOS on a device (free provisioning, no paid account)

The user's iPad Air 4 runs the app on a **free Apple ID** ("Personal Team" `34QV558B8U`, set as `DEVELOPMENT_TEAM` in `ios/Runner.xcodeproj/project.pbxproj`, automatic signing). What that setup needs, in order — each step failed loudly when skipped:

1. **Developer Mode on the device** (Settings → Privacy & Security), then a restart. `xcrun devicectl device info details --device <udid>` reports `developerModeStatus`.
2. **An Apple ID in Xcode** (Settings → Accounts) *and* a team selected on the Runner target — Xcode creates the "Apple Development" certificate only then, and `security find-identity -v -p codesigning` stays empty until it does.
3. **A globally unique bundle id.** `com.example.durecmix` cannot be registered.
4. **Trusting the profile on the device** (Settings → General → VPN & Device Management). Until then the launch dies with `FBSOpenApplicationServiceErrorDomain error 1` / "profile has not been explicitly trusted".

Build, install, run — the console form catches a crash that a home-screen tap would hide:

```bash
flutter build ios --release                       # ~5-6 min from cold (Rust for aarch64-apple-ios)
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <udid> --console de.macbuchi.durecmix
```

**The signature expires after 7 days** — the app then refuses to start and has to be reinstalled (free-provisioning limit, alongside 3 sideloaded apps per device). A paid account would also unlock TestFlight/ad-hoc distribution; that is still the user's open decision.

`devicectl` can install, launch, read the console, copy files into the app container (`copy to --domain-type appDataContainer`), rotate and reboot — it can **not** tap or screenshot. There is no XCUITest target, so the only way to drive the iOS UI from a script is the integration-test suite (`flutter test integration_test -d <udid>`), which drives widgets, not system UI: the Files picker stays manual.

## Testing

Rust carries the correctness load (107 engine tests: pan law, limiter ceiling, LUFS targets, session migration). On the Dart side:

- `flutter analyze` + `flutter test` after every change; the macOS integration test (`flutter test integration_test -d macos`) is the flow guard and runs in CI.
- **Keep the integration test in ONE file** — several app launches per run are flaky on macOS. Build synthetic fixtures inline (the doc fixture WAV with iXML), never the user's multi-GB recordings. Network stays off.
- Dart unit coverage is thin (issue #49): pure-ish logic (`_syncPair`, `suggestedExportName`, batch queue) deserves unit tests rather than being exercised only through the E2E run.
- **Widget tests are GUI tests** — assert layout relationships (`tester.getSize`/`getTopLeft`), responsive breakpoints (set `tester.view.physicalSize`, reset via `addTearDown`) and states without screenshots; a RenderFlex overflow fails the test by itself.
- **Browser-only APIs need a browser test.** `flutter test` runs on the VM, where IndexedDB, `AudioContext` and `Blob` do not exist, so a VM test can only ever cover the pure logic around them. Mark the rest `@TestOn('browser')` and run it with `flutter test --platform chrome <file>` (CI does, in the Web matrix entry) — `test/web_storage_browser_test.dart` is the pattern: pure rules against a fake in `test/file_store_test.dart`, the real adapter proven in Chrome.
- **Release-only traps get a configuration regression test.** Manifest permissions, the FileProvider authority, `filepaths.xml` and the desugaring flags are exactly the kind of thing that compiles fine and fails at a user's device — assert their presence by reading the files in a plain Dart test (see the Fahrgemeinschaft project's `test/android_manifest_test.dart` for the pattern, one `reason:` per test describing the real-world failure).

## Workflow

Conventional Commits (`feat:`/`fix:`/`feat!:`/`chore:`/`ci:`/`docs:`/`test:`/`refactor:`). **Feature branches + PRs** (since M3b): branch `feat/<topic>` or `fix/<topic>` off `main`, push, open a PR, merge only when the full CI matrix is green (squash-merge, PR title in conventional-commit form). Stacked PRs are fine: base each on its predecessor; GitHub retargets to `main` as they merge in order. PRs are opened with `gh pr create`. **Who merges is decided by the version bump**, because with auto-release the merge *is* the publication: a PR that does not bump publishes nothing, so the agent may squash-merge it once the full matrix is green; the bumping PR of a chain is the release and belongs to the user. (Since 2026-07-20, replacing the blanket self-merge ban of 2026-07-12 — that rule stalled entire stacked chains on the user, although every PR but the last publishes nothing. Same rule as Fahrgemeinschaft.) Releases: the LAST PR of a shipping chain must bump `pubspec.yaml` — a merge to `main` with an untagged version auto-tags and releases (`release.yml`); without a bump there is NO release, and the CI `Housekeeping (version bump)` job warns on the PR and fails the `main` run. **Every bump adds a matching section at the top of `CHANGELOG.md`** (house format, link list at the file end) — the app bundles the file as the About → "What's new" view, and `test/changelog_test.dart` fails when changelog and pubspec drift. Remote: https://github.com/MacBuchi/mixstack (public).
