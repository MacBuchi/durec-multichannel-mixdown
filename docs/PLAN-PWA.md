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
  - **Abbrechen (nachgereicht 2026-07-26, Issue #105).** `renderByRanges`
    fragt einmal pro Block ein `cancelled`-Callback und wirft
    `RenderCancelled` — eigener Typ, damit „abgebrochen" nicht als Fehler
    im Banner landet. Der Block ist die Granularität, die es gibt: der
    Engine-Aufruf für einen Block lässt sich von außen nicht unterbrechen,
    bei 4 MB kehrt er schnell genug zurück. Der bestehende `catch`-Zweig
    gibt die Rust-Seite über `renderStreamCancel` frei; `complete()` läuft
    nie, also wird auch kein halber Download angeboten.
    **Nur der Range-Renderer kann das** — der native Pfad hängt an einem
    FRB-Stream ohne Abbruchweg. `ExportController.canCancel` bildet genau
    das ab, damit die UI keinen toten Knopf zeigt (dieselbe Lehre wie bei
    „Choose folder"). Verifiziert im Browser gegen `UFX34_00.WAV`: Klick
    bei 24 % → „Export cancelled", **kein Download**; derselbe Ablauf ohne
    Klick liefert die Datei.
  - Offen: sehr große WAV-Ausgaben sind auf dem iPad ungetestet (FLAC ist
    die sichere Wahl).
- **S4 — Playback (erledigt 2026-07-25).** AudioWorklet statt cpal-wasm.
  *Exit erfüllt:* Live-Vorhör mit Metern, Seek und Live-Parametern; im
  Browser gegen das 8-Kanal-Fixture verifiziert (Playhead läuft, −7,1
  LUFS-M, TP −1,1 dBTP, corr 0,55, sauberer Stopp am Dateiende).
  - **Eine Kette, zwei Player.** `preview::PreviewStage` (Mix →
    Mastering-FIR → True-Peak-Limiter → f32 → Meter) bedient den nativen
    Decode-Thread *und* den Browser. Ein Test hält fest, dass die Vorhör
    **sample-genau der Export** ist: Render mit `LoudnessMode::None` nach
    32-Bit-Float gegen `WebPlayer`, maximale Abweichung exakt 0.0. Der
    Render ist um genau den Limiter-Lookahead länger, weil Pass 2 die
    Delay-Line ausspült und eine Live-Vorhör kein Ende hat.
  - **Der AudioContext braucht die Samplerate der Datei.** Ein
    44,1-kHz-Take durch einen 48-kHz-Context klingt zu hoch —
    `AudioContext({sampleRate})` statt der Browser-Vorgabe.
  - **Das Ende erkennt man am Ring, nicht an Zählern.** Web Audio holt nur
    ganze 128-Frame-Blöcke ab; ein kürzerer Rest (gemessen: 96 Frames)
    bleibt für immer liegen, während das Worklet unterläuft. „Jeder
    geschriebene Frame gespielt" wird deshalb nie wahr, „Ring zu 90 % leer"
    schneidet umgekehrt das Ende ab. Richtig ist: alles gefüttert **und**
    weniger als ein Block im Ring.
  - **Underruns gab es keine.** Die Messung zeigt den Ring durchgehend voll
    (88198 von 88200 Samples) und Pumpe und Wiedergabe exakt im Takt —
    1792 Frames je 40-ms-Tick. Die Pumpe muss nur *vorauslaufen*, nicht
    echtzeitfähig sein; Mischen ist um ein Vielfaches schneller als
    Wiedergabe.
  - Offen: Latenz von Parameteränderungen ist die Ringtiefe (~1 s), weil
    fertig gemischtes Audio erst abfließen muss. Kürzerer Ring oder
    Neumischen ab Playhead wären die Hebel.
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

  Der **iOS-Safari-Nachweis ist erbracht**: auf einem iPad Air laufen Laden,
  Import (auch >1 GB), Wiedergabe und Export (Nutzertests 2026-07-25 und
  2026-07-26). Damit ist Issue #93 geschlossen.

  **Offline-Start (nachgereicht 2026-07-26, Issue #105).** Der Cache liegt
  *in* `coi-sw.js`, aus genau dem Grund, der oben steht: ein zweiter Worker
  würde diesen verdrängen. Strategie ist **Netz zuerst, Cache als
  Rückfall** — die deployte App darf nie an einem alten Stand hängen bleiben,
  nur weil jemand schon einmal da war. Verifiziert: online laden, Netz
  komplett kappen, neu laden → isoliert, Engine bootet, und ein 394-MB-Take
  lässt sich offline öffnen und analysieren (115 BPM, 34 Spuren). Auch in
  einem frisch geöffneten Tab ohne Netz.

  Dabei fiel eine Sache auf, die nichts mit dem Worker zu tun hat und
  trotzdem in ihn gehört: der **HTTP-Cache** liefert nach einem Deploy noch
  eine Weile die alte Datei (Pages sendet `max-age=600`). Gemessen, mit und
  ohne Worker gleich — aber der Worker würde diese veralteten Bytes
  *einlagern* und einen Offline-Nutzer daran festnageln. Deshalb geht der
  Netzabruf über `cache: 'no-cache'`, also eine Revalidierung: nach dem
  Deploy kommt sofort die neue Datei, und die Antwort ist im Normalfall ein
  304 ohne Nutzdaten. `Range`-Anfragen bleiben unangetastet, sonst würde aus
  einer 206 eine vollständige 200.

  **Fader-Latenz (nachgereicht 2026-07-26, Issue #105).** Sie war die
  Ringtiefe: neue Parameter galten nur für Audio, das *danach* gemischt
  wurde, und der Ring läuft rund eine Sekunde voraus. Statt den Ring zu
  kürzen — er muss einen blockierten Main-Thread überleben — wird der
  veraltete Teil **neu gemischt**: `PreviewSink.trimTo` behält 120 ms,
  `WebPlayer::rewind_to` setzt die Quelle zurück, **ohne die Kette zu
  resetten** (`seek` täte das, und genau dieser Reset ist der Klick, den
  Live-Parameter vermeiden sollen).

  Drei Dinge, die dabei nötig waren und nicht offensichtlich sind:

  - **Der Wiederaufsetzpunkt wird als Summe gelesen**,
    `playedFrames + bufferedSamples/2`. Beide Werte ändern sich beim
    Abspielen gegenläufig, die Summe nicht — sonst läge der Punkt um ein
    Render-Quantum daneben und es gäbe eine Naht.
  - **Rate-Limit 300 ms.** Ein Fader-Zug schickt bei *jeder* Zeigerbewegung
    neue Parameter; ohne Bremse würde der Ring dauernd neu gemischt und der
    Pump auf einem Telefon zurückfallen. Die Parameter selbst gehen sofort
    raus, nur das Nachmischen wartet.
  - **Deckel pro Pump-Takt (200 ms Audio).** Ohne ihn füllt der erste Takt
    nach dem Nachmischen den ganzen Ring in *einem* langen Mix auf dem
    Main-Thread. Gemessen macht der Deckel den Start sogar besser:
    Anlauf-Underruns 42 ohne gegen 18–24 mit.

  Gemessen im Browser an `UFX34_00.WAV` (34 ch), Puffertiefe pro Pump-Takt
  protokolliert: ruhige Wiedergabe 913–965 ms und **keine** Underruns; unter
  Dauer-Fader-Bewegung fällt der Puffer auf 216 ms und erholt sich —
  ebenfalls **keine** Underruns. Die Latenz ist damit der behaltene Rest
  statt der Ringtiefe. Alle Underruns fallen vor dem ersten Pump-Takt an
  (der Ring startet leer); das ist Anlaufverhalten und war vorher auch so.

  **Ungeprüft bleibt der Klang.** Headless hat kein Audiogerät — dass es
  nicht knackt und sich richtig anfühlt, muss auf dem iPad beurteilt werden.

## Der Web-Reader muss das echte `File` behalten

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

Der erste Fix holte den Blob deshalb **einmal** per `fetch` auf die
Objekt-URL und schnitt selbst. Lesen: 96,6 s → **0,7 s**. Ende zu Ende:
107 s → **3,7 s** (917-MB-Take: 4,4 s; nativ 1,02 s).

**Er hatte aber eine zweite Grenze, die erst der iPad-Test zeigte: Dateien
über ~1 GB ließen sich gar nicht mehr importieren.** `response.blob()`
*materialisiert eine vollständige zweite Kopie* der Datei, bevor der erste
Range-Read läuft. Chrome lagert die auf die Platte aus, deshalb fiel es am
Desktop nicht auf; WebKit hält sie im RAM, und damit reißt ein >1-GB-Take
das Speicherbudget des Tabs.

Die Wurzel beider Fehler ist dieselbe: `file_selector` gibt das `File` nicht
heraus. `pickRecordings` baut sein `<input type="file">` deshalb **selbst**
(`platform_shim_web.dart`) und behält das echte `web.File`. Ein `File` *ist*
ein `Blob` und ist von der Datei auf der Platte gedeckt — `slice()` liefert
wieder nur eine Sicht, nichts wird kopiert. Damit fällt die
Größenbeschränkung weg und die Hydrierung gleich mit.

**Nie wieder über `XFile` gehen** — weder `openRead` noch `fetch` auf
`file.path`. Beide fangen bei derselben verlustbehafteten Hülle an.

Die Kopie ist gemessen, nicht erschlossen. Beide Builds mit
`UFX36_00.WAV` (1.348.476.898 Bytes, 34 ch, 4:59) in derselben
WebKit-Engine (Playwright WebKit 26.5), Speicher der WebKit-Prozesse:

| | Grundlast | Spitze | Zuwachs | +200 MB nach |
| --- | --- | --- | --- | --- |
| `fetch` auf die Objekt-URL | 869 MB | 2583 MB | **+1714 MB** | **303 ms** |
| `File.slice()` (heute) | 750 MB | 1025 MB | **+275 MB** | 28.116 ms |

Die letzte Spalte ist der eigentliche Beleg: der alte Weg lässt den Speicher
**eine Drittelsekunde nach der Dateiübergabe** um Hunderte MB steigen — da
ist noch keine Audioprobe gelesen, das ist reines Kopieren. Der heutige Weg
rührt ihn bis Sekunde 28 nicht an, und dann nur um den Arbeitssatz der
laufenden Analyse.

**Zum Nachstellen braucht es WebKit.** In Chrome lief dieselbe Datei auch
mit dem alten Code durch (1231 ms), weil Chrome die Blob-Kopie auf die
Platte auslagert — der Fehler ist am Desktop grundsätzlich unsichtbar.
Playwright-WebKit (`npx playwright install webkit`) zeigt ihn, iPad-Safari
stirbt daran.

Gegen die deployte Seite mit derselben Datei (Chrome 150, frisches Profil):
Import **0,72 s** (34 ch, **34 iXML-Spuren**), Mixer offen nach 0,81 s,
Wellenformen nach 27,6 s, **JS-Heap-Spitze 139 MB**. Kanalzahl identisch zur
nativen Engine (`analyze_demo`: 34 Kanäle, 1,42 s). **Auf dem iPad Air
bestätigt** (2026-07-26).

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

**Ein Audit fand 2026-07-26 vier weitere Verstöße** — alle nach demselben
Muster, alle behoben:

| Einstieg | Was im Web passierte | jetzt |
| --- | --- | --- |
| „Export multiple takes…" im Browser | Takes ankreuzen, Namen tippen, Export drücken — **nichts**. `_exportSelected` steigt bei `folder == null` wortlos aus, und `folder` ist im Web immer null | Einstieg weg (`canPickFolders`); der Runner ist durchgehend pfadbasiert und bräuchte einen eigenen Range-Umbau |
| „Use system picker…" im Browser-Menü | öffnete eine Datei, für die es **keinen** Reader gibt: `sourceReader` wird nur von `pickRecordings` gesetzt und nie geleert, also las der Mixer still die **vorige** Aufnahme unter dem neuen Namen | Einstieg weg — im Web *ist* die Liste schon das Ergebnis des System-Pickers |
| Referenz-Mastering | Dialog offen wie überall, Referenzanalyse ist aber pfadbasiert → roher Ausnahmetext | `canMasterToReference`, Tap antwortet mit einem Satz |
| „You're up to date." im Über-Dialog | im Web nie geprüft: `httpGetText` wirft, der Fehler wird geschluckt, und das sah aus wie „kein Update" | `hasNetwork`, die Zeile erscheint gar nicht erst. Dasselbe Flag schickt Feedback über das vorbefüllte Formular statt über die API, die vorher „Sending failed. Are you online?" meldete — eine Diagnose, die nichts mit dem Netz zu tun hatte |

**Und sie gilt für *jeden* Einstieg, nicht nur den offensichtlichen.** Der
Web-Zweig kam zunächst nur in `_changeFolder` an (Startbildschirm und
Ordner-Symbol); der Tap auf den Dateinamen in der Kopfzeile — in der APK der
schnelle Weg zwischen Takes — lief weiter über `_openBrowser` in
`pickFolder()` → `getDirectoryPath()` → `null` und tat sichtbar nichts
(iPad-Test 2026-07-26). Wer eine Fähigkeit portiert, muss **alle** Aufrufer
suchen, nicht den erstbesten.

**Merge `dev/pwa` → main** ist eine Nutzer-Entscheidung, frühestens nach
S2 (ab da hat die Web-Version eigenständigen Nutzwert als Viewer/Checker).
**Vorbereitet am 2026-07-27 als v0.13.0**: der Merge bringt S0 bis S5 samt
Wiedergabe, Export, Abbruch und Offline-Start; die verbleibenden
Paritätslücken (#111) und das Knacken auf dem iPad (#114) blockieren nichts
davon.

Dabei fällt die Architektur-Regel „bewusst kein Web-Target" und wird durch ihr
Gegenteil ersetzt: es *gibt* ein Web-Target, und nichts Plattformspezifisches
darf am Shim vorbei erreichbar sein. Drei Dinge, die zum Merge gehören und
sich leicht übersehen lassen:

- **`pages.yml` triggerte nur auf `dev/pwa`** — so wäre die deployte PWA nach
  dem Merge eingefroren. Jetzt stehen `main` und `dev/pwa` beide drin;
  `dev/pwa` fällt raus, sobald der Branch weg ist.
- **`flutter build web` lief nirgends in der CI.** `flutter analyze` merkt
  einen `dart:io`-Import in web-erreichbarem Code nicht, und `pages.yml` baut
  erst *nach* dem Merge — ein Web-Job in der Build-Matrix schließt das.
- **AGENTS.md wusste nichts von der PWA.** Die Web-Geschichte stand nur in
  diesem Plan, obwohl AGENTS.md zuerst gelesen wird; sie hat dort jetzt einen
  eigenen Abschnitt.

## Nicht-Ziele

- MP3-Export im Browser (bis ein tragfähiger Encoder-Weg feststeht).
- Referenz-Mastering-Profile über Netz (bleibt lokal wie überall sonst).
- Feedback-Token im Web-Build (öffentliches Artefakt, Browser-Fallback
  reicht).
