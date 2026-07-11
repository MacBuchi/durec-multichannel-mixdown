# DurecMix

Cross-platform, fully offline downmixer for multichannel WAV recordings from the **RME DUREC** recorder — the successor of [MultiChannelWavMixer](https://github.com/MacBuchi/MultiChannelWavMixer), rebuilt with a Flutter UI and a Rust DSP engine.

**Targets:** macOS · Windows · Android · iOS

---

## Why a rewrite?

The original Python/customtkinter tool ran on desktop only, loaded entire recordings into RAM, and took a few audio-engineering shortcuts. DurecMix keeps its workflow (load DUREC WAV → adjust per-track faders → export a stereo mix) and fixes the foundations:

| | MultiChannelWavMixer (Python) | DurecMix |
|---|---|---|
| Platforms | macOS, Windows | macOS, Windows, Android, iOS |
| Pan law | linear (−6 dB centre error) | **constant-power (−3 dB centre)** |
| Peak handling | sample peak | **true peak (planned M3)** |
| Phase | destructive auto-"fix" | **per-track polarity switch** |
| Memory | whole file in RAM | **streamed blocks — multi-GB files on phones** |
| >4 GB recordings | unsupported | **RF64/BW64 support** |
| Solo / mute | – | ✔ |
| USB-stick import on Android | – | planned (SAF, M4) |

## Architecture

```
engine/          Pure Rust DSP + file I/O (no FFI, no GUI) — fully unit-tested
rust/            flutter_rust_bridge API layer (thin DTO conversion only)
lib/             Flutter app (UI, state, platform file access)
rust_builder/    cargokit glue that builds the Rust crate inside flutter build
```

- `engine/` must stay free of FFI and UI concerns; all audio logic and tests live here.
- `rust/` must stay logic-free; it only converts bridge DTOs ↔ engine types.
- Audio is never fully loaded: the engine streams 64 Ki-frame blocks and renders in two passes (analysis → render).

### Engine status (M1)

- Streaming WAV/RF64/BW64 reader (16/24/32-bit PCM, 32/64-bit float), iXML track metadata (DUREC), seek + block reads
- Mix bus: per-track gain (−60…+6 dB), constant-power pan, polarity invert, solo/mute/in-mix
- Two-pass render to stereo WAV (16/24/32-float) with peak normalisation or clip protection
- Session persistence next to the source file (`<take>.durecmix.json`), track-name-based merge across re-scans
- 29 engine tests: `cargo test -p durecmix-engine`

### Roadmap

- **M2** — live preview playback (cpal), waveforms, per-track + master meters (LUFS/true-peak/correlation)
- **M3** — per-track HPF/EQ, true-peak limiter, LUFS targets, TPDF dither, FLAC/MP3, trim/fades, BPM
- **M4** — Android SAF/USB-OTG import, iOS Files/USB import, phone layout, background export
- **M5** — stereo-pair linking, A/B snapshots, presets, batch queue, store releases

## Development

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) (stable) and [Rust](https://rustup.rs) (stable).

```sh
flutter pub get
cargo test --workspace          # engine + bridge tests
cargo clippy --workspace --all-targets
flutter analyze
flutter run -d macos            # or: windows, an Android device, an iOS device
```

Rust bindings are generated — after changing `rust/src/api/`, run:

```sh
flutter_rust_bridge_codegen generate
```

## Commit convention

[Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `feat!:`, `chore:`, `ci:`, `docs:`, `test:`, `refactor:`), same rules as the predecessor project.
