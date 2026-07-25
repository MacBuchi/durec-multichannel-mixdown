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
- **S2b — Öffnen & Analysieren (erledigt 2026-07-25).** Der Take lässt sich
  im Browser öffnen (`load_recording_from_chunks`) und wird analysiert:
  Dart schiebt den `data`-Chunk in 4-MB-Blöcken durch
  `stream_analysis_push`, der `analysis::StreamAnalyzer` trägt dabei
  angebrochene Frames über Blockgrenzen. Gegen `UFX34_00.WAV` (376 MB,
  34 ch) in Chrome: Mixer nach 6 s offen mit **allen 34 Spurnamen aus dem
  iXML**, Wellenformen nach **31 s**, **115 BPM — identisch zur nativen
  Engine**. JS-Heap-Spitze ~80 MB (Blockgröße + GC-Verzug), nicht
  dateigroß. Nativ läuft dieselbe Analyse in ~8 s; der Browser ist also
  grob 3× langsamer.
  - **Sessions ohne Dateisystem:** `session_to_json` / `Session::from_json`;
    der Web-Build hält sie im Speicher der Registerkarte (dauerhafte
    Ablage in OPFS/localStorage bleibt offen).
  - **Das wasm-Bündel muss `--release` sein.** Debug ist 4,8 MB statt
    674 KB und spürbar langsamer — `tool/build_web_engine.sh` baut deshalb
    seit S2b standardmäßig optimiert.
  - Offen für „S2b vollständig": Meter (brauchen Playback, S4) und der
    iOS-Safari-Nachweis.

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
- **S3 — Export (erledigt 2026-07-25).** Der Browser rendert und lädt
  herunter. *Exit erfüllt:* der gestreamte Render ist **byte-identisch**
  zum nativen (Test `streamed_render_matches_the_file_render_byte_for_byte`
  und `byte_driven_render_matches_the_file_render`, WAV16/24 und FLAC16/24
  samt Reports). OPFS brauchte es nicht.
  - **Ein DSP, zwei Antriebe.** `render_io` ist zweipassig und zieht die
    Blöcke über `Read + Seek`; im Browser gibt es kein synchrones Seek auf
    einem Blob, dort schiebt Dart und liest denselben Bereich schlicht
    zweimal (Lesen ist seit dem Blob-Fix billig). Die Pro-Block-Arbeit
    liegt deshalb in `RenderPass1`/`RenderPass2`, `render_io` und
    `analyze_mix_mastering` sind nur noch Schleifen darüber,
    `render::StreamRender` ist der Byte-Antrieb für den Browser.
  - **Der Header entsteht zuletzt, gehört aber nach vorn.** hound patcht
    die RIFF-Größen, der FLAC-Writer die STREAMINFO — beide springen dafür
    zurück, aber nur in ihren Kopf. `sink::ChunkSink` hält genau dieses
    64-KB-Fenster und gibt den Rumpf blockweise heraus; Dart setzt
    `head ++ Rümpfe ++ tail` als `Blob` zusammen. Blob-Teile liegen
    **außerhalb** des JS-Heaps (der Browser lagert auf Platte aus), sonst
    bräuchte ein 90-Minuten-WAV ~1,5 GB Speicher.
  - **MP3 fehlt im Web** (LAME ist C, baut nicht für wasm32). Die
    Format-Auswahl kommt deshalb aus `availableFormats`, nie aus
    `ApiFormat.values` — sonst bietet der Picker ein Ziel an, das beim
    Export mit einem Encoder-Fehler endet.
  - **Noch eine dart2js-Falle:** `x.clamp(1, 1 << 62)` wirft im Browser
    „Invalid argument: 1", weil `1 << 62` dort zu 0 wird. 64-Bit-Konstanten
    und -Shifts gibt es in dart2js nicht — vgl. den FNV-Hash in S1.
  - Offen: Fortschrittsanzeige während des Renders ist da, aber ein
    Abbrechen-Knopf fehlt; sehr große WAV-Ausgaben sind auf dem iPad
    ungetestet (FLAC ist die sichere Wahl).
- **S4 — Playback.** AudioWorklet-Pfad (cpal-wasm nur falls es überzeugt).
  *Exit: Live-Preview mit Metern, Latenz akzeptabel.*
- **S5 — Deploy auf GitHub Pages (Grundlage erledigt 2026-07-25,
  vorgezogen für den iPad-Test).** `web/coi-sw.js` stellt die
  Cross-Origin-Isolation selbst her, weil Pages keine Header setzen kann;
  `.github/workflows/pages.yml` baut wasm + Flutter-Web und deployt aus
  `dev/pwa`. Manifest trägt jetzt DurecMix-Branding. Lokal gegen einen
  Server **ohne** COOP/COEP verifiziert (die Pages-Situation): Isolation
  nach genau einem Reload, danach voller Ablauf mit `UFX34_00.WAV` —
  Mixer nach 6,1 s, Wellenformen nach 31,5 s, identisch zum Lauf mit
  Server-Headern.

  Zwei Fallen, die dabei aufgeflogen sind:
  - **Nur ein Service Worker pro Scope.** Flutters Bootstrap registriert
    `flutter_service_worker.js` auf „/" und verdrängt damit `coi-sw.js`,
    das daraufhin Flutters wieder verdrängt: ein Reload-Ping-Pong, bei dem
    die Seite nur bei jedem zweiten Laden isoliert ist und die Engine
    entsprechend nur die Hälfte der Zeit startet. `web/flutter_bootstrap.js`
    lädt Flutter deshalb ohne `serviceWorkerSettings`. **Offline-Caching
    muss später IN `coi-sw.js` wandern, nicht als zweiter Worker.**
  - **Der Reload darf nicht an `serviceWorker.controller` hängen.**
    `clients.claim()` setzt den Controller, ohne das Dokument neu zu
    holen — die Isolation entsteht aber allein aus den Headern der
    *Navigations*-Antwort. Die Bedingung ist `!crossOriginIsolated`,
    einmalig abgesichert über `sessionStorage`.

  Offen: Offline-Start (Caching in `coi-sw.js`), Update-Hinweis,
  **iOS-Safari-Nachweis auf dem Gerät**.

## Der Web-Reader darf nicht über `XFile.openRead` gehen

Die Analyse war im Browser ~30× langsamer als nativ, und **die Ursache war
weder wasm noch die Blob-API.** Gemessen an `UFX05_00_Breeze.WAV`
(782 MB, 32 ch, Page-Cache warm):

| Weg | Zeit |
| --- | --- |
| Native Engine (`analyze_demo`) | 0,87 s |
| Browser, `blob.slice().arrayBuffer()` roh | 0,5 s |
| Browser, `FileReader` roh | 0,53 s |
| **App über `XFile.openRead`** | **107 s** |

Aufgeteilt: 196 Blöcke, **96,6 s Lesen** gegen **2,6 s wasm-Analyse**.

`file_selector_web` baut sein `XFile` aus `URL.createObjectURL(file)` allein
und gibt das `File` nie weiter, also hat `cross_file` keinen Blob zum
Schneiden: **jeder** `openRead()`-Aufruf holt die *ganze* Datei per XHR
zurück und behält 4 MB davon. 196 × 782 MB = 149,6 GB Kopieren — bei
gemessenen 1568 MB/s sind das vorhergesagte 97,7 s gegen 96,6 s gemessene.
Der Aufwand ist also **quadratisch in der Dateigröße**; bei einem 2-GB-Take
wäre es nicht dreißigmal, sondern über hundertmal zu langsam.

`platform_shim_web._lazyRecording` holt den Blob deshalb **einmal** und
schneidet selbst. Lesen: 96,6 s → **0,7 s**. Ende zu Ende: 107 s → **3,7 s**
(917-MB-Take: 4,4 s; nativ 1,02 s). Der Blob bleibt dateigestützt — ein
Handle, keine Bytes auf dem JS-Heap —, das Halten kostet also auch bei
mehreren GB nichts.

**`+simd128` bringt nichts** (2631 ms → 2559 ms, 3 %, im Rauschen): die
Decode- und Akkumulierschleifen vektorisieren nicht von selbst. Bewusst
nicht aktiviert, um die Browser-Anforderungen nicht ohne Gegenwert zu
erhöhen. Der verbleibende Abstand zu nativ (2,6 s gegen 0,87 s) ist
wasm-Grundkosten plus 782 MB Kopieren über die Bridge; erst wenn das stört,
lohnen größere Blöcke oder ein Zero-Copy-Pfad.

## Fehlende Stufen müssen sich melden

Solange S3/S4 fehlen, stehen ihre Bedienelemente trotzdem in der UI — und
taten bis 2026-07-25 im Web genau zwei Dinge, die beide falsch sind: **Play**
schrieb `AnyhowException(live playback is not available…)` als rohen
Entwicklerstring an den Rand der Kopfzeile, **Export** lief in
`getSaveLocation()`, das im Browser wirft — die Exception ging unbehandelt
verloren und der Nutzer sah **gar nichts**. Der Batch-Export öffnete seinen
Dialog und tat danach still nichts, weil `getDirectoryPath()` im Web `null`
liefert.

Deshalb: **jede noch nicht portierte Fähigkeit bekommt ein `const`-Flag im
Platform-Shim** (`canPlayAudio`, `canExportAudio` neben `canPickFolders`),
und die UI beantwortet den Tap mit einem Satz statt mit Schweigen oder einem
Stacktrace. Wo der Weg ohne die Stufe gar keinen Sinn ergibt (Batch-Export),
verschwindet der Einstieg. Das ist dieselbe Lehre wie bei „Choose folder"
weiter oben — sie gilt für jede folgende Stufe mit.

**Merge `dev/pwa` → main** ist eine Nutzer-Entscheidung, frühestens nach
S2 (ab da hat die Web-Version eigenständigen Nutzwert als Viewer/Checker).
Beim Merge fällt Architektur-Regel 4 in AGENTS.md („bewusst kein
Web-Target") — sie gilt bis dahin für `main` weiter.

## Nicht-Ziele

- MP3-Export im Browser (bis ein tragfähiger Encoder-Weg feststeht).
- Referenz-Mastering-Profile über Netz (bleibt lokal wie überall sonst).
- Feedback-Token im Web-Build (öffentliches Artefakt, Browser-Fallback
  reicht).
