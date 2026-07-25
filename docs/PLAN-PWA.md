# PLAN-PWA — DurecMix im Browser (Issue #93)

Ziel: DurecMix ohne App Store zu den Nutzern bringen — vor allem iOS. Eine
PWA auf GitHub Pages erreicht alle Plattformen, kostet nichts und braucht
weder Apple-Account noch Review. Integration läuft über den Branch
`dev/pwa`; `main` bleibt davon unberührt, bis eine Stufe echten Nutzwert
beweist.

## Spike-Ergebnis (2026-07-25, S0)

**Die Engine kompiliert für `wasm32-unknown-unknown`.** Zwei neue
Cargo-Features in `engine/`:

| Feature    | Inhalt                  | Warum gegated                                        |
| ---------- | ----------------------- | ---------------------------------------------------- |
| `playback` | cpal + rtrb (`playback.rs`) | cpal braucht pro Plattform ein Audio-Backend      |
| `mp3`      | mp3lame-encoder (LAME)  | C-Quellen bauen nicht für wasm32-unknown-unknown     |

`default = ["playback", "mp3"]` — native Builds sind byte-identisch zu
vorher (79 Tests, clippy, fmt grün). Alles andere ist pures Rust und baut
durch: symphonia, flacenc, ebur128, realfft, hound, quick-xml. Der
CI-Rust-Job prüft den wasm32-Build seit S0 mit.

`std::fs`/Threads in `wav.rs`, `sink.rs`, `reference.rs`, `session.rs`
kompilieren auf wasm, schlagen aber zur Laufzeit fehl — das I/O-Redesign
ist S2-Arbeit, kein Kompilier-Blocker.

## Bekannte Blocker und gewählter Ansatz

- **Kein Dateisystem:** Eingabe als Blob vom `<input type="file">`/Picker;
  `blob.slice()` streamt blockweise — deckungsgleich mit dem
  `BLOCK_FRAMES`-Modell der Engine. Die Engine bekommt dafür eine
  `Read + Seek`-Abstraktion statt `std::fs::File` (synchron lesbar via
  `FileReaderSync` im Worker; Fallback: async Prefetch-Ring).
- **Export:** kein Schreibpfad in Safari → OPFS schreiben, dann Download
  anbieten. WAV-Ausgaben sind groß (~1,5 GB bei 90 min) — Web-Export
  startet mit FLAC, WAV mit Warnung.
- **MP3:** auf Web vorerst deaktiviert (Feature `mp3` aus). Später
  optional: LAME-emscripten-Build oder Pure-Rust-Encoder.
- **Playback:** Web Audio + AudioWorklet. cpal hat ein
  wasm-bindgen-Backend — in S4 evaluieren, aber nicht darauf bauen
  (ScriptProcessor-basiert, Latenz/Deprecation unklar).
- **Threads:** brauchen `SharedArrayBuffer` und damit COOP/COEP-Header,
  die GitHub Pages nicht setzen kann → `coi-serviceworker` (Safari ≥ 16.4)
  oder S2–S3 bewusst single-threaded.

## Stufen

Jede Stufe ist ein PR (oder eine kurze Kette) gegen `dev/pwa`, ohne
Version-Bump. Exit-Kriterien entscheiden, ob die nächste Stufe startet.

- **S0 — Machbarkeit (dieser Commit).** Engine feature-gated, wasm32-Check
  in CI. *Exit: erfüllt.*
- **S1 — Bridge & Shell.** `rust/`-Crate für wasm bauen
  (Playback-/fd-APIs gaten, `flutter_rust_bridge_codegen build-web`),
  `web/` wiederherstellen, `dart:io`-Stellen (12 Dateien) hinter
  Conditional Imports. *Exit: App bootet in Chrome, ein Engine-Call
  (Version/Probe eines Mini-Fixtures) geht durch die Bridge.*
- **S2 — Lesen & Analysieren.** Blob-Reader in der Engine, Picker → Probe
  → Wellenformen/Meter ohne Playback/Export. *Exit: echtes DUREC-WAV
  (>900 MB) lädt im Browser mit korrekten Track-Namen und Wellenformen —
  auch in iOS Safari.*
- **S3 — Export.** Render nach OPFS + Download (FLAC zuerst). *Exit:
  Downmix eines echten Takes im Browser, Ausgabe bit-identisch zum
  nativen Render.*
- **S4 — Playback.** AudioWorklet-Pfad (cpal-wasm nur falls es überzeugt).
  *Exit: Live-Preview mit Metern, Latenz akzeptabel.*
- **S5 — PWA & Deploy.** Manifest, Service Worker (+ ggf.
  coi-serviceworker), Pages-Workflow, Update-Hinweis. *Exit: installierbar
  von GitHub Pages, Offline-Start.*

**Merge `dev/pwa` → main** ist eine Nutzer-Entscheidung, frühestens nach
S2 (ab da hat die Web-Version eigenständigen Nutzwert als Viewer/Checker).
Beim Merge fällt Architektur-Regel 4 in AGENTS.md („bewusst kein
Web-Target") — sie gilt bis dahin für `main` weiter.

## Nicht-Ziele

- MP3-Export im Browser (bis ein tragfähiger Encoder-Weg feststeht).
- Referenz-Mastering-Profile über Netz (bleibt lokal wie überall sonst).
- Feedback-Token im Web-Build (öffentliches Artefakt, Browser-Fallback
  reicht).
