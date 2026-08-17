# PLAN-PLAYSTORE — die App in den Google Play Store bringen

Ziel: dieselbe App, die es als GitHub-APK und als PWA schon gibt, zusätzlich
über den Play Store verteilen. Der Direktweg über GitHub bleibt bestehen —
alles hier ist additiv, nichts ersetzt den bisherigen Kanal.

Stand: 2026-08-14. Was in diesem Branch schon erledigt ist, steht in §2;
alles ab §3 sind Handgriffe außerhalb des Repos.

## 1. Rechtslage

### Markenrecherche (2026-08-14)

| Frage | Befund | Quelle |
| --- | --- | --- |
| Ist „RME" geschützt? | **Ja, ausdrücklich beansprucht.** RMEs Legal Notices nennen wörtlich „RME, DIGI96, DIGICheck, SyncCheck, Hammerfall, ZLM, SyncAlign, and Zero Latency Monitoring" als eingetragene Marken. | [archiv.rme-audio.de](https://archiv.rme-audio.de/old/english/info/legal.htm) |
| Ist „DUREC" geschützt? | **Nicht bestätigt.** Steht nicht in obiger Liste, und RME schreibt es auf der Produktseite ohne ® oder ™. | [rme-audio.de/durec.html](https://rme-audio.de/durec.html) |
| Damit unbedenklich? | **Nein.** DPMA/EUIPO/TMview blockieren automatisierte Abfragen, die Register wurden nicht eingesehen. Und auch ohne Eintragung entstehen in DE Rechte über § 5 MarkenG (geschäftliche Bezeichnung) und § 4 Nr. 2 MarkenG (Verkehrsgeltung). | — |

**Offen, vor dem Launch manuell zu erledigen:** „DUREC" und den gewählten
App-Namen in [DPMAregister](https://register.dpma.de/DPMAregister/marke/einsteiger)
und [TMview](https://www.tmdn.org/tmview/) nachschlagen, Klasse 9 und 42.
Kostenlos, wenige Minuten, und es ist der einzige Punkt dieser Datei, den ein
Werkzeug nicht abnehmen kann.

### Die Unterscheidung, auf die es ankommt

* **Beschreibende Nennung** — „für Aufnahmen des RME DUREC", „kompatibel mit …"
  in der Store-Beschreibung. Zulässig nach § 23 Abs. 1 Nr. 3 MarkenG und
  Art. 14 Abs. 1 lit. c UMV, solange sie nötig ist, um den Bestimmungszweck
  anzugeben, ehrlich ist und keine Geschäftsbeziehung suggeriert.
* **Der App-Name selbst** — das ist markenmäßige Benutzung und damit der Teil
  mit Risiko.

Dazu kommt die Store-Mechanik: **die Package-ID ist nach der ersten
Veröffentlichung unveränderlich.** Eine IP-Beschwerde bei Google führt in der
Regel erst zum Takedown und danach zur Klärung; ein Rename bedeutet dann einen
neuen Store-Eintrag, und Bewertungen wie Installationszahlen sind weg.

**Entscheidung: generischer Name, RME/DUREC nur noch beschreibend.** Umgesetzt
in v0.20.0 — die App heißt **Mixstack**, die Package-ID ist
`de.macbuchi.mixstack`. Websuche nach dem Namen: kein Audio-Produkt, keine
Firma. Verworfen wurden dabei „Wavesum" (Wavesum Oy, finnische
Audio-Softwarefirma), „Mixbus" (Harrison-DAW), „Summit" (Summit Audio) und
„MultiMix" (Alesis-Mischpultserie).

⚠️ **„Downmix" wäre der falsche Begriff gewesen.** Er bezeichnet im Audio-Umfeld
das Zusammenfalten eines fertigen Surround-Mixes auf Stereo (5.1 → 2.0). Diese
App *mischt* einzelne aufgenommene Spuren mit Fader, Pan und EQ zu einem Master
— das heißt **Mixdown**. README, pubspec und Store-Text sagen das jetzt richtig.

Das ist auch die technisch ehrlichere Beschreibung. [engine/src/wav.rs](../engine/src/wav.rs)
liest RIFF/RF64/BW64 mit PCM-Int, IEEE-Float und `WAVE_FORMAT_EXTENSIBLE` bei
beliebiger Kanalzahl; DUREC-spezifisch ist einzig die iXML-Auswertung für die
Spurnamen in [engine/src/ixml.rs](../engine/src/ixml.rs), und die liefert bei
fehlendem Chunk sauber eine leere Liste. Die App arbeitet damit genauso mit
Aufnahmen von Zoom, Sound Devices, Tascam oder einem DAW-Export.

Fußzeile für Store-Beschreibung und About-Dialog:

> RME and DUREC are trademarks of their respective owners. This app is not
> affiliated with, endorsed by or sponsored by Audio AG / RME.

### Lizenzen der Abhängigkeiten

Geprüft, kein Handlungsbedarf — die Infrastruktur stand schon:

| Crate | Lizenz | Abdeckung |
| --- | --- | --- |
| `mp3lame-encoder` 0.2.4, `mp3lame-sys` (vendored LAME 3.100) | LGPL-3.0 | Volltext im Bundle |
| `shine-rs` 0.1.3 (nur wasm) | LGPL-2.0 | Volltext im Bundle |
| Symphonia-Familie | MPL-2.0 | über den Fallback-Mechanismus |
| App selbst | MIT | `LICENSE` im Repo-Root |

[tool/gen_rust_licenses.py](../tool/gen_rust_licenses.py) erzeugt
`assets/licenses/rust-third-party.txt` aus dem Link-Zeit-Abhängigkeitsgraphen,
`main.dart` meldet es an `LicenseRegistry` an, der About-Dialog öffnet
`showLicensePage`, und CI hält es über `--check` frisch. Die Relink-Auflage der
LGPL ist praktisch erfüllt, weil das gesamte Projekt quelloffen auf GitHub
liegt und der About-Dialog dorthin verlinkt.

MP3-Patente sind seit 2017 abgelaufen — kein Thema.

⚠️ **Das Asset nie auf einer Maschine ohne alle Ziel-Targets neu erzeugen.**
`cargo tree --target all` sieht nur installierte Targets; auf einem Rechner
ohne Windows-Target fallen Crates stillschweigend aus den Hinweisen. Der
Header der Datei nennt die Bedingung.

## 2. Der Play-Build (in diesem Branch erledigt)

### Warum der bisherige Build abgelehnt worden wäre

`REQUEST_INSTALL_PACKAGES` plus `ota_update`: Googles
[Policy](https://support.google.com/googleplay/android-developer/answer/12085295)
sagt ausdrücklich, die Permission dürfe nicht für Selbst-Updates verwendet
werden, und sie ist Apps vorbehalten, deren *Kernfunktion* das Installieren von
Paketen ist — Browser, Dateimanager, MDM, Backup/Restore. Seit 29.09.2022
verlangt schon die Einreichung eine sensitive-permission-Declaration mit
Demo-Video.

**Das App-Manifest zu ändern reicht dabei nicht.** Das ota_update-Plugin
deklariert in seinem *eigenen* Manifest `REQUEST_INSTALL_PACKAGES`,
`INSTALL_PACKAGES`, `WRITE_EXTERNAL_STORAGE`, `ACCESS_NETWORK_STATE` und
`ACCESS_WIFI_STATE`. Der Manifest-Merger zieht sie in jeden Build, der das
Plugin im Klassenpfad hat — sie müssen aktiv entfernt werden.
`INSTALL_PACKAGES` ist dabei signature-level, eine normale App kann sie nie
halten, und ihr bloßes Vorhandensein ist ein Review-Flag.

### Wie es jetzt gelöst ist

Ein einziges Flag, `--dart-define=PLAY_STORE=true`, steuert beide Seiten:

* **Gradle** ([android/app/build.gradle.kts](../android/app/build.gradle.kts))
  dekodiert die dart-defines und tauscht das Manifest gegen
  `src/main/AndroidManifest-play.xml`, das die sechs Permissions per
  `tools:node="remove"` entfernt und den ota_update-FileProvider weglässt.
  Der gewählte Pfad wird ins Build-Log gedruckt — die Alternative wäre ein
  stiller Fehlgriff, der erst Wochen später als Review-Ablehnung auftaucht.
* **Dart** ([lib/io/platform_shim_io.dart](../lib/io/platform_shim_io.dart))
  bekommt `isPlayStoreBuild`, `canSelfUpdate` und `canCheckForUpdates` als
  Shim-Flags — nach der Hausregel, dass eine fehlende Fähigkeit ein `const`
  ist und keine Exception an der Aufrufstelle. Der Update-Banner läuft im
  Play-Build gar nicht erst an: Play ist dort der Update-Kanal, und ein
  Hinweis auf einen Download außerhalb des Stores wäre falsch und
  policy-nah.

**Ein Flag, nicht zwei** — zwei getrennte Schalter sind genau der Weg zu
einem Build, der die Permission entfernt und trotzdem „Update now" anbietet.

### Außerdem geändert

* **Feedback-Token** ([lib/state/feedback.dart](../lib/state/feedback.dart)):
  `_token` ist eine Compile-Zeit-Konstante und liegt damit extrahierbar im
  ausgelieferten Bundle. Ein GitHub-APK laden Leute, die auch das Repo lesen
  können; ein Store-Eintrag geht an Fremde. Der Play-Build nimmt darum immer
  den token-losen Weg über das vorausgefüllte Issue-Formular — auch dann,
  wenn der Workflow ein Secret injiziert.
* **`versionCode`** ([android/app/build.gradle.kts](../android/app/build.gradle.kts)):
  wird jetzt aus der Semver abgeleitet (0.19.0 → 19000) statt aus pubspecs
  `+N`, das seit M0 auf `+1` steht und von nichts erhöht wird. Android
  duldet die Neuinstallation desselben versionCode, darum ist es dem
  GitHub-APK nie aufgefallen — Play nicht: dort wäre das **zweite** Release
  das gescheiterte.

### Bauen und prüfen

```sh
flutter build appbundle --release --dart-define=PLAY_STORE=true
flutter build apk --release                    # unverändert: der GitHub-Weg
flutter test test/android_manifest_test.dart   # Drift zwischen den Manifesten
```

Der Test hält beide Manifeste gegeneinander: jede Permission, die im
Direkt-Manifest steht und nicht zum Installer gehört, muss auch im
Play-Manifest stehen. Das ist der Drift, der sonst einen Play-Build ohne
Foreground-Service oder ohne Netzzugriff hinterlässt.

Der abschließende Beweis führt aber über das Build-Ergebnis, nicht über die
Quelldateien. **Nicht** über `aapt2 dump xmltree` auf der AAB — deren Manifest
ist Protobuf, aapt2 antwortet mit „could not identify format of APK". Das
gemergte Manifest, das Gradle erzeugt, ist Klartext und ist genau das
Merger-Ergebnis, um das es geht:

```sh
grep -o 'uses-permission android:name="[^"]*"' \
  build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml \
  | sort -u
grep -o 'android:versionCode="[0-9]*"' \
  build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml
```

Gemessen am 2026-08-14 nach `flutter build appbundle --dart-define=PLAY_STORE=true`:

```text
android.permission.FOREGROUND_SERVICE
android.permission.FOREGROUND_SERVICE_DATA_SYNC
android.permission.INTERNET
android.permission.POST_NOTIFICATIONS
de.macbuchi.durecmix.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION   (AndroidX, selbst deklariert)
android:versionCode="19000"
```

Kein `REQUEST_INSTALL_PACKAGES`, kein `INSTALL_PACKAGES`, kein
`ota_update_provider`.

Die Gegenprobe zählt genauso: `flutter build apk --release` **ohne** das Flag
liefert weiterhin `REQUEST_INSTALL_PACKAGES`, `INSTALL_PACKAGES`,
`WRITE_EXTERNAL_STORAGE`, `READ_EXTERNAL_STORAGE` und
`de.macbuchi.durecmix.ota_update_provider` — der GitHub-Weg ist unangetastet.
(`ACCESS_NETWORK_STATE` und `ACCESS_WIFI_STATE` aus dem Plugin-Manifest tauchen
in keinem der beiden Builds auf; die `remove`-Direktiven dafür bleiben trotzdem
stehen, falls ein Plugin-Update sie wieder einzieht.)

Zwei Nebenbefunde aus derselben Messung:

* **`READ_EXTERNAL_STORAGE` wurde implizit eingezogen** — im Blame-Report
  ohne Quellenangabe, als Folge von ota_updates `WRITE_EXTERNAL_STORAGE`. Sie
  wird jetzt mit entfernt: die App liest jede Aufnahme über SAF (per-URI-Grants
  aus `ACTION_OPEN_DOCUMENT_TREE`), was sie nie gebraucht hat, und bei
  targetSdk 36 hat sie ohnehin keine Laufzeitwirkung. Sie hätte lediglich
  „Fotos und Medien" auf den Store-Eintrag eines Audio-Mixers gesetzt.
  ⚠️ Auf Android 8–12 nicht auf einem Gerät geprüft — beide Testgeräte sind
  neuer. SAF braucht sie dort nach Doku nicht, aber falls ein altes Gerät
  greifbar ist, ist das Öffnen einer Aufnahme der Test.
* **`android.permission.DUMP`** taucht im Manifest auf, ist aber kein
  `uses-permission`: `androidx.profileinstaller.ProfileInstallReceiver` nutzt
  sie als *Schutz* eines exportierten Receivers, also als Zugriffsschranke.
  Kein Handlungsbedarf.

## 3. Konto & Compliance — in dieser Reihenfolge

Der erste Punkt hat den längsten Vorlauf und gehört deshalb zuerst angefasst.

1. **Closed Testing: 12 Tester, 14 zusammenhängende Tage.** Pflicht für
   Personal-Accounts, die nach dem 13.11.2023 angelegt wurden; Production und
   Pre-Registration bleiben bis dahin gesperrt.
   ([Play Console Help](https://support.google.com/googleplay/android-developer/answer/14151465))
2. **Identitätsverifizierung** — Ausweis, Adressnachweis, Telefon. Name und
   Adresse müssen exakt mit dem Google-Payments-Profil übereinstimmen.
   ⚠️ **Diese Angaben fließen in die öffentlichen Entwicklerangaben.** Bei
   einer Privatperson ist das die Privatadresse — der Grund, warum viele
   Solo-Entwickler ein Kleingewerbe mit Büro- oder c/o-Adresse anmelden. Vor
   dem Eintragen im Console-Flow konkret ansehen, was angezeigt wird.
3. **DSA-Händlerstatus** deklarieren (EU-Pflicht).
4. **Datenschutzerklärung** — URL ist Pflichtfeld im Store-Eintrag. Muss die
   zwei Netzwerkzugriffe abdecken: den Update-Check gegen
   `api.github.com/repos/…/releases/latest` (im Play-Build abgeschaltet) und
   das Feedback-Posting. Ansonsten ist die App vollständig offline und
   verarbeitet Aufnahmen ausschließlich lokal — das ist ein Verkaufsargument
   und gehört so in den Text.
5. **Data-Safety-Formular** — der Feedback-Text ist vom Nutzer eingegebener
   Inhalt und geht an GitHub. Der angehängte Log durchläuft `redactPaths`,
   Benutzernamen werden also entfernt; das lässt sich wörtlich so angeben.
6. **Content Rating** über den IARC-Fragebogen.
7. **Play App Signing** — der Keystore unter `secrets/` wird zum *Upload*-Key,
   den Signaturschlüssel verwaltet Play. `secrets/` ist gitignored und muss
   gesichert bleiben; ein Verlust bricht die Update-Kette des GitHub-APKs.

Kein Handlungsbedarf: **Target API 36** ist bereits erfüllt (Flutter 3.44.8
setzt `targetSdk = 36`); die Frist am 31.08.2026 ist damit erledigt.

## 4. Was bewusst nicht geändert wurde

* **Die macOS-Bundle-ID bleibt `com.example.durecmix`.** Eine Änderung würde
  den Sandbox-Container mit den gespeicherten Sessions verwaisen lassen —
  dieselbe Begründung wie in AGENTS.md.
* **Der Dart-Paketname bleibt `durecmix`.** Er steht in jedem Import, ist
  nirgends nach außen sichtbar und markenrechtlich ohne Bedeutung; ihn
  umzubenennen wäre Bewegung ohne Nutzen.
* **Die iOS-Bundle-ID bleibt vorerst.** Sie ist an das Free Provisioning
  gebunden und für den Play Store irrelevant. Bei einem späteren App-Store-Weg
  neu zu entscheiden — und dort ist auch die LGPL des LAME-Encoders deutlich
  unangenehmer als hier.

## 5. Offen

* [x] App-Name festlegen — **Mixstack**, `de.macbuchi.mixstack` (v0.20.0)
* [x] `applicationId`/`namespace`, `android:label`, `web/manifest.json`,
  pubspec-`description`, README, Docs und UI-Strings gezogen
* [ ] **Registerprüfung „Mixstack" und „DUREC"** bei DPMA und TMview (§1) —
  der einzige Schritt, den kein Werkzeug hier abnehmen kann
* [ ] Store-Assets: Icon 512×512, Feature-Graphic 1024×500, Screenshots
  (die generierten aus `tool/make_screenshots.sh` sind verwendbar)
* [ ] Datenschutzerklärung schreiben und hosten (GitHub Pages liegt schon vor)
* [ ] Closed Testing starten
* [ ] Nach dem Release: die alte APK-Installation auf dem Pixel deinstallieren,
  bevor die neue kommt — andere `applicationId`, also kein Update-Pfad

### Was bewusst den alten Namen behält

Umbenannt wurde, was öffentlich sichtbar oder im Store dauerhaft ist. Nicht
angefasst, jeweils mit Grund:

| Bleibt | Warum |
| --- | --- |
| Dart-Paket `durecmix` | steht in jedem Import, nach außen unsichtbar, markenrechtlich ohne Bedeutung |
| Rust-Crates `durecmix-engine`, `rust_lib_durecmix` | interne Namen; `System.loadLibrary` und `--out-name` hängen daran |
| `.durecmix.json` als Session-Suffix | eine Änderung verwaist jeden gespeicherten Mix |
| IndexedDB-Name `durecmix` (Web) | dieselbe Falle für die PWA-Nutzer |
| MethodChannels `durecmix/saf`, `durecmix/files` | müssen mit Kotlin/Swift übereinstimmen; reine Churn-Gefahr |
| `DURECMIX_FEEDBACK_TOKEN` | Name eines GitHub-Secrets, Änderung bräuchte einen Handgriff im Repo |
| macOS-Bundle-ID `com.example.durecmix` | verwaist sonst den Sandbox-Container mit den Sessions |
| iOS-Bundle-ID `de.macbuchi.durecmix` | hängt am Free Provisioning, für Play irrelevant |
| Repo `durec-multichannel-mixdown` | eigene Entscheidung; alle Release- und Issue-Links hängen daran |
