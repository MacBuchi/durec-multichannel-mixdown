# Rework Plan: Cross-Platform MultiChannelWavMixer (Flutter + Rust)

## Context

The current app is a Python/customtkinter desktop tool that downmixes RME DUREC multichannel WAVs to stereo. It works on macOS/Windows but cannot run on Android/iOS, loads whole files into RAM, and has several audio-engineering shortcuts (linear pan law, sample-peak normalisation, heuristic phase "correction").

Goal: rework it as a fully **offline** app for **macOS, Windows, Android, iOS** with pro-grade downmix quality, USB-stick import (incl. Android), sound + waveform preview, and a modern responsive UI.

**Decisions made with the user:**
- Stack: **Flutter UI + Rust DSP core** (bridged with `flutter_rust_bridge` v2)
- **New repository** (fork-style successor; the Python app stays released and untouched)
- Feature depth: **Pro downmix suite** (EQ/HPF, meters, true-peak limiter, dither, FLAC)
- **Windows stays** a target

Suggested new repo name: `DurecMix` (working title — user may rename).

---

## Audio-engineer review of the current app (gaps to fix)

These are correctness issues from a mixing/mastering standpoint, independent of the platform rework:

| # | Current behaviour | Problem | Fix in new app |
|---|---|---|---|
| 1 | Linear pan: `L = v·(1−p)`, `R = v·p` | Centred tracks lose 6 dB; loudness changes while panning | **Constant-power pan law (−3 dB centre)** |
| 2 | Sample-peak normalisation (−1 dBFS) | Inter-sample peaks can clip DACs/lossy encoders | **True-peak (4× oversampled) limiting/normalisation, −1 dBTP ceiling** |
| 3 | Automatic phase "fix" via mono-sum dBFS heuristic (thresh 3.25 dB) | Can silently invert a correct channel; destructive & invisible | **Per-track polarity (ø) switch** + **correlation meter** so the engineer decides |
| 4 | No solo | Can't audition tracks in mix context | **Solo (in-place, post-fader) + PFL option**, mute per track |
| 5 | Per-track audition is peak-normalised | Misleading gain-staging impression | Solo auditions **post-fader at mix level**; PFL mode for raw signal |
| 6 | No filters | Stage recordings carry rumble/bleed | **Per-track HPF (12/24 dB/oct) + 3-band parametric EQ** |
| 7 | Only −12 LUFS / −1 dBFS / none | −12 LUFS is not a standard target | **Selectable targets: −14 LUFS (streaming), −16, −23 (EBU R128), custom + TP ceiling** |
| 8 | Auto silence-strip + auto 80 ms fades, not previewable | Destructive, no control | **Editable trim in/out handles on the waveform + adjustable fade lengths**, defaults match old behaviour |
| 9 | Fixed 16-bit export, no dither | Truncation distortion | **TPDF dither on 16-bit export; 24-bit/float WAV options** |
| 10 | MP3 or 16-bit WAV only | No lossless-compressed option | **Add FLAC**; keep MP3 (LAME); WAV 16/24/32f |
| 11 | Whole file loaded into RAM | Impossible on mobile; DUREC files are GBs | **Streaming two-pass engine** (analysis pass → render pass) |
| 12 | No RF64 / split-file support | DUREC splits recordings at 4 GB | **RF64 read + auto-detect & join split DUREC takes** |
| 13 | L/R names only set initial pan | Pairs drift apart when adjusted | **Stereo-pair linking** (auto from iXML ` L`/` R` suffix, unlinkable) |
| 14 | No metering at all | Mixing blind | **Live meters: per-track peak, master LUFS-M/S/I + true peak + correlation** |
| 15 | No headroom indication on the sum | Hidden clipping before normalise stage | 64-bit float mix bus (keep), **master fader + clip indicator** |

Kept from the current app (parity): iXML track-name parsing, batch export, per-recording config persistence, BPM detection in filename (optional toggle), loudness normalise, output-folder handling, dark theme.

**Additional value-adds** (cheap once the engine exists): A/B mix snapshots, post-export loudness report (LUFS-I, TP, LRA), filename templating (`{name}_{bpm}_{lufs}`), channel-name-based global presets (e.g. "Kick" always gets HPF off, centre).

---

## Architecture

```
durecmix/
├── core/                       # Rust workspace
│   ├── engine/                 # pure DSP + file I/O crate (no FFI)
│   │   ├── wav/                # WAV+RF64+BWF reader (streaming), iXML parser (quick-xml)
│   │   ├── dsp/                # gain, const-power pan, polarity, biquad EQ/HPF,
│   │   │                       #   true-peak limiter, TPDF dither, resample (rubato)
│   │   ├── meter/              # ebur128 (LUFS M/S/I, LRA, true peak), correlation
│   │   ├── mix/                # graph: N tracks → strip chain → stereo bus → master chain
│   │   ├── render/             # offline two-pass export (WAV/FLAC/MP3), batch queue
│   │   ├── analysis/           # waveform peak pyramids, BPM (aubio or autocorrelation)
│   │   └── playback/           # realtime preview via cpal (CoreAudio/WASAPI/AAudio),
│   │                           #   lock-free parameter updates from UI
│   └── bridge/                 # flutter_rust_bridge API crate (thin, async, streams meters)
├── app/                        # Flutter app (one codebase)
│   ├── lib/
│   │   ├── state/              # Riverpod: session, tracks, transport, meters
│   │   ├── ui/mixer/           # channel strips, fader, pan, EQ sheet
│   │   ├── ui/master/          # meters, loudness target, limiter, export
│   │   ├── ui/waveform/        # GPU-drawn waveform (CustomPainter from peak pyramids)
│   │   └── io/                 # platform import: SAF (Android), UIDocumentPicker (iOS),
│   │                           #   file_selector (desktop); passes fd/path to Rust
│   ├── android/  ios/  macos/  windows/
├── .github/workflows/          # ci.yml (rust test + clippy, flutter analyze/test,
│                               #   build matrix), release.yml (tag-driven, same model as today)
└── docs/
```

Key crates: `hound`/custom RF64 reader, `quick-xml`, `biquad`, `ebur128`, `rubato`, `cpal`, `mp3lame-encoder`, `flac-bound`. All pure-native, no network — **fully offline by construction**.

### Streaming engine (mobile-critical)
- Never load full files. **Pass 1 (analysis)**: single streamed read computes waveform peak pyramid per channel, per-channel peak, and optionally BPM. **Pass 2 (render)**: streamed read → strip chains → bus → master chain (loudness gain from pass-1 LUFS measurement → true-peak limiter → dither) → encoder.
- Preview playback streams from disk with a small decode ring-buffer; fader/pan/EQ changes are applied via lock-free atomics in the audio callback (immediate audible response, like the current app's Listen Mix but truly live).

### USB / file import per platform
- **Android**: Storage Access Framework — `ACTION_OPEN_DOCUMENT` / `OPEN_DOCUMENT_TREE` natively lists **USB-OTG mass-storage sticks**; obtain a content URI, dup the file descriptor and hand the raw fd to Rust for streamed reads (no copy of multi-GB files). No `MANAGE_EXTERNAL_STORAGE` permission needed.
- **iOS**: `UIDocumentPicker` — the Files app exposes USB drives (iOS 13+); use security-scoped bookmark, resolve to path/fd for Rust.
- **macOS/Windows**: standard open dialog (`file_selector`); USB sticks are just volumes.
- Exports mirror the same mechanism (SAF `CREATE_DOCUMENT`/tree write on Android, security-scoped folder on iOS).

---

## UI design (responsive, one Flutter codebase)

**Desktop / tablet-landscape — "console view":** vertical channel strips side by side (fader, pan knob, ø, HPF, solo/mute, name, mini-meter), master section pinned right (LUFS M/S/I + TP meters, correlation, loudness target, limiter, export button), full-width waveform timeline with trim/fade handles at bottom, transport bar. This is the layout every engineer knows from a mixing desk.

**Phone — "strip list view":** vertically scrolling track cards (name, compact horizontal fader with dB readout, pan slider, mute/solo/ø icons, inline mini-waveform); tap a card → expandable sheet with EQ/HPF and per-track meter. Persistent bottom bar: transport (play/stop, position), master mini-meter, master menu (target, limiter, export). Breakpoint switching via `LayoutBuilder` (~700 dp).

Shared interactions: double-tap fader → 0 dB, double-tap pan → centre (parity with today), long-press solo = exclusive solo, drag on waveform = seek, pinch = zoom. Dark theme default, light optional. Touch targets ≥ 48 dp.

---

## Milestones

**M0 — Bootstrap (new repo).** Rust workspace + Flutter app + flutter_rust_bridge round-trip; CI skeleton (rust test/clippy/fmt, flutter analyze/test, build matrix macOS/Windows/Android/iOS); conventional-commits + release-please or commitizen-equivalent, mirroring the current repo's bump/release model.

**M1 — Engine core (desktop-first).** Streaming WAV/RF64 reader, iXML parsing (port `parse_tracks_from_ixml` semantics incl. L/R pan heuristic), split-file join, mix graph with gain/const-power pan/polarity, two-pass WAV export, session persistence (`.durecmix.json` per recording ≈ MixConf.json). Rust unit tests port the intent of the existing 71 Python tests + golden-render tests (fixed input → bit-exact output).

**M2 — Preview & visualisation.** cpal playback with live parameter updates, solo/PFL/mute, waveform peak pyramids + timeline widget, per-track meters, master LUFS/TP/correlation meters (streamed to Flutter ~30 fps).

**M3 — Pro processing.** HPF + 3-band EQ per strip, true-peak limiter, loudness targets (−14/−16/−23/custom LUFS with −1 dBTP), TPDF dither, trim/fade handles, FLAC + MP3 encoders, BPM detection + filename templating, loudness report.

**M4 — Mobile.** Android SAF/USB-OTG import (fd handoff), iOS document picker + security scopes, phone layout, background-safe export (foreground service on Android, background task on iOS), on-device performance pass (thermals, memory ceiling).

**M5 — Polish & release.** Stereo-pair linking, A/B snapshots, channel-name presets, batch queue UI, app icons, signed releases: notarised macOS DMG, Windows zip/MSIX, Android APK + Play listing, iOS via TestFlight/App Store (**requires Apple Developer account, $99/yr — also unlocks macOS notarisation**).

The old repo gets a final README note pointing to the successor.

---

## Verification

- **Rust engine**: `cargo test` — DSP unit tests (pan law: −3 dB at centre; dither statistics; limiter ceiling ≤ −1 dBTP verified by 4× oversampled peak scan; LUFS against ebur128 reference vectors) + golden-file renders compared sample-exact.
- **Cross-check against the Python app**: render the same DUREC test file with matching settings in both apps; expect equal loudness (±0.1 LU) where feature semantics match.
- **Flutter**: `flutter analyze`, widget tests for strip/master state; manual run on macOS (`flutter run -d macos`) loading a real DUREC WAV → adjust faders during playback → export → verify report.
- **Mobile**: Android device with USB-OTG stick → import via SAF without copying; iOS device with Lightning/USB-C stick via Files. Export ends up back on the stick.
- **CI**: all four platform builds green + smoke test (app launches, engine self-test command).
