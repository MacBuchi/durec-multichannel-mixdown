# PLAN-PWA — DurecMix im Browser (Issue #93)

Ziel: DurecMix ohne App Store zu den Nutzern bringen — vor allem iOS. Eine
PWA auf GitHub Pages erreicht alle Plattformen, kostet nichts und braucht
weder Apple-Account noch Review. Integration läuft über den Branch
`dev/pwa`; `main` bleibt davon unberührt, bis eine Stufe echten Nutzwert
beweist.

## Spike-Ergebnis (2026-07-25, S0)

**Die Engine kompiliert für `wasm32-unknown-unknown`.** Zwei neue
Cargo-Features in `engine/`:

| Feature    | Inhalt                      | Warum gegated                                    |
| ---------- | --------------------------- | ------------------------------------------------ |
| `playback` | cpal + rtrb (`playback.rs`) | cpal braucht pro Plattform ein Audio-Backend     |
| `mp3`      | mp3lame-encoder (LAME)      | C-Quellen bauen nicht für wasm32-unknown-unknown |

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

- **S0 — Machbarkeit.** Engine feature-gated, wasm32-Check in CI.
  *Exit: erfüllt.*
- **S1 — Bridge & Shell.** *Exit: erfüllt (2026-07-25)* — App bootet in
  Chrome (headless verifiziert), der Boot-Beacon in `main.dart` meldet
  `DURECMIX_WEB_BOOT Hello, wasm engine!` durch die Bridge aus dem
  wasm-Worker-Pool. Werkzeug-Erkenntnisse:
  - **`tool/build_web_engine.sh` statt `flutter_rust_bridge_codegen
    build-web`.** FRB 2.12 setzt nur die Target-Features; aktuelle
    Nightlies leiten `--shared-memory` daraus nicht mehr ab → non-shared
    Memory → WorkerPool stirbt mit `DataCloneError: #<Memory> could not
    be cloned`. Nötige Link-Args: `--shared-memory --max-memory
    --import-memory` (wasm-bindgens Thread-Transform verlangt importierte
    Memory) `--export=__heap_base` + TLS-Exports. Voraussetzungen:
    nightly-Toolchain, `rust-src`, wasm32-Target, wasm-pack.
  - **`flutter build web` kopiert `web/pkg` nicht** (wasm-packs
    Catch-all-`.gitignore` dort) — beim Deploy `build/web/pkg` selbst
    kopieren; `web/pkg` bleibt unversioniert und wird per Skript gebaut.
  - **Serve braucht COOP/COEP** (`same-origin` / `require-corp`), sonst
    kein SharedArrayBuffer: lokal `flutter run -d web-server
    --web-header=…` oder der Python-Server aus der PR-Beschreibung;
    auf Pages später `coi-serviceworker` (S5).
  - Der `dart:io`-Zugriff läuft jetzt komplett über
    `lib/io/platform_shim.dart` (Conditional Import; Web-Impl =
    In-Memory-Container, Netz aus). Der FNV-1a-Hash in
    `session_paths.dart` rechnet auf 32-Bit-Limbs (dart2js hat keine
    64-Bit-Ints) — bit-identisch zum alten Ergebnis, Vektoren in
    `test/session_paths_test.dart`.
- **S2a — Öffnen & Probe (erledigt 2026-07-25).** Web-Dateipicker plus
  Range-Probe: Rust lokalisiert die Chunks (`wav::scan_chunks`) und parst
  sie (`wav::probe_from_parts`), Dart holt per `blob.slice()` nur die
  angeforderten Bereiche (`lib/state/range_probe.dart`). Gegen das echte
  `UFX34_00.WAV` (376 MB, 34 ch) in Chrome verifiziert: Ergebnis
  identisch zur nativen Probe (34 ch · 44,1 kHz · 24 Bit · 1:27 ·
  **34 Spuren aus dem iXML am Dateiende**), **0,42 s, 0 MB
  Heap-Zuwachs** — die Datei wird nachweislich nicht geladen.
- **S2b — Analysieren.** Wellenformen/Meter über denselben Range-Pfad
  (streamt die Audiodaten, anders als die Probe). *Exit: echtes DUREC-WAV
  lädt im Browser mit Wellenformen — auch in iOS Safari.*

  Aus dem Gerätetest (Pixel 7 Pro, Chrome 150, 2026-07-25) bereits bekannt:
  - **„Choose folder" ist im Web tot und schweigt dabei.**
    `file_selector_web.getDirectoryPath()` gibt bedingungslos `null`
    zurück (kein Fehler, kein Dialog) — der Tap tut sichtbar nichts.
    S2 braucht also einen eigenen Web-Pfad (`showDirectoryPicker`, wo
    vorhanden, sonst `<input type="file" multiple>`), **und** bis dahin
    einen ehrlichen Hinweis in der UI statt der stillen Sackgasse.
  - Der Reader muss ohne `File System Access` auskommen: iOS Safari kennt
    nur `<input type="file">` → Blob → `slice()`.
  - **Ein Prefix-Read reicht nicht — der Web-Reader muss springen können.**
    In echten DUREC-Takes steht der `iXML`-Chunk (die Spurnamen!) **hinter**
    den Audiodaten: `UFX34_00.WAV` (394 MB, 34 ch, 44,1 kHz, 24 Bit) hat
    `fmt` @12, `data` @36 und `iXML` erst @394.225.760. Ein „erste N MB
    lesen"-Ansatz liefert also nie Spurnamen. `blob.slice()` ist dafür
    genau richtig (O(1), liest nur den angeforderten Bereich) — die
    Engine-Seite braucht folglich eine echte `Read + Seek`-Abstraktion
    über den Blob, keinen Byte-Puffer.
- **S3 — Export.** Render nach OPFS + Download (FLAC zuerst). *Exit:
  Downmix eines echten Takes im Browser, Ausgabe bit-identisch zum
  nativen Render.*
- **S4 — Playback.** AudioWorklet-Pfad (cpal-wasm nur falls es überzeugt).
  *Exit: Live-Preview mit Metern, Latenz akzeptabel.*
- **S5 — PWA & Deploy.** Manifest, Service Worker (+ ggf.
  coi-serviceworker), Pages-Workflow, Update-Hinweis. *Exit: installierbar
  von GitHub Pages, Offline-Start.*

  Aus dem Gerätetest bereits bekannt: **es läuft noch kein Service
  Worker** (`getRegistrations()` → 0). Flutters Bootstrap-Registrierung
  ist deprecated und meldet das auch in der Konsole — S5 registriert den
  Worker selbst in `web/index.html`. Ohne ihn kein Offline-Start und
  keine echte Installierbarkeit. Das generierte `manifest.json` trägt
  außerdem noch die `flutter create`-Vorgaben (`name: durecmix`,
  `background_color: #0175C2`) statt DurecMix-Branding.

**Merge `dev/pwa` → main** ist eine Nutzer-Entscheidung, frühestens nach
S2 (ab da hat die Web-Version eigenständigen Nutzwert als Viewer/Checker).
Beim Merge fällt Architektur-Regel 4 in AGENTS.md („bewusst kein
Web-Target") — sie gilt bis dahin für `main` weiter.

## Nicht-Ziele

- MP3-Export im Browser (bis ein tragfähiger Encoder-Weg feststeht).
- Referenz-Mastering-Profile über Netz (bleibt lokal wie überall sonst).
- Feedback-Token im Web-Build (öffentliches Artefakt, Browser-Fallback
  reicht).
