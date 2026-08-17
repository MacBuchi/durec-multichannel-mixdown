# Finanzierung und Skalierung von Mixstack

**Status:** recherchiert am 2026-08-17 · **Plattformseite:**
`MitFahrBar/doc/finanzierung-plattformvergleich.md` (einmal geschrieben, gilt
für alle drei Apps des Betreibers) · **Ergänzt:** `docs/PLAN-PLAYSTORE.md`

Dies ist **keine Steuer- oder Rechtsberatung.**

## Die Frage

Was kostet Mixstack im Betrieb, was passiert bei steigenden Nutzerzahlen, und
welches Finanzierungsmodell passt?

## Die Antwort in einem Satz

**Mixstack hat strukturell keine laufenden Kosten — und ist damit von den drei
Apps der beste Monetarisierungskandidat.** Es gibt kein Backend, das skalieren
müsste; die Rechenlast liegt vollständig beim Nutzer. Was zu klären wäre,
sind zwei Punkte, die `docs/PLAN-PLAYSTORE.md` bereits kennt — und die durch
eine Verkaufsabsicht **wichtiger** werden, nicht unwichtiger.

## Kostenbild: strukturell null

Das ist keine glückliche Fügung, sondern die Folge des Entwurfs. Mixstack ist
vollständig offline: Rust-DSP-Engine, Streaming in 64-Ki-Frame-Blöcken, nichts
verlässt das Gerät. Es gibt genau **zwei** ausgehende Netzaufrufe, beide gegen
GitHub:

- `lib/state/update_check.dart` — Update-Prüfung gegen `releases/latest`
- `lib/state/feedback.dart` — In-App-Rückmeldung als GitHub-Issue

Beide sind im Play-Build ohnehin abgeschaltet.

| Posten | Dienst | Tarif |
| --- | --- | --- |
| Auslieferung macOS/Windows/Android | GitHub Releases | frei, **keine Bandbreitengrenze** |
| PWA | GitHub Pages | frei (öffentliches Repo) |
| CI (4-Plattform-Matrix, Rust + Flutter) | GitHub Actions | frei (öffentliches Repo) |
| Datenbank, Auth, Push | — | **existiert nicht** |

**Skalierung ist hier ausschließlich eine GitHub-Bandbreitenfrage.** Zehntausend
Nutzer kosten genauso viel wie zehn, nämlich nichts. Der einzige denkbare
Engpass wäre GitHubs Missbrauchserkennung bei sehr hohem Download-Volumen; für
Release-Assets ist das nicht der übliche Auslösefall, und der Ausweichweg
stünde mit Cloudflare R2 (kein Egress-Entgelt) bereit — siehe Plattformvergleich.

Der einzige reale Kostenposten in Sicht ist **nicht** Infrastruktur, sondern
das Apple Developer Program (99 $/Jahr), falls je ein iOS- oder
Mac-App-Store-Weg dazukommt.

## Warum das den Monetarisierungsfall verändert

Bei PilzBuddy und MitFahrBar wäre Geld ein Mittel, laufende Kosten zu decken.
Hier gibt es keine. Was bleibt, ist der Gegenwert der Arbeit — und der ist bei
Mixstack am ehesten in Geld ausdrückbar:

- **Werkzeugcharakter statt Freizeit-App.** Wer eine 90-Minuten-Mehrspuraufnahme
  auf EBU-R128-Ziel herunterrechnet, arbeitet.
- **Zielgruppe mit Zahlungsbereitschaft.** Live-Ton, Bandmitschnitte,
  Gottesdienst-Aufzeichnungen — dort werden Werkzeuge gekauft.
- **Klar abgrenzbarer Mehrwert.** Referenz-Mastering, Formatvielfalt,
  Stapelverarbeitung sind Funktionen, die man beschreiben und bepreisen kann.

**Deshalb Einmalkauf, nicht Abo.** Ein Abo verspricht laufende Leistung —
Serverbetrieb, Datenpflege, Aktualisierungen. Zwei davon gibt es hier nicht,
und ein Abo für ein reines Offline-Werkzeug wäre schwer zu begründen und leicht
zu kündigen. Ein einmaliger Betrag bildet ab, was tatsächlich getauscht wird.

Denkbare Ausgestaltung, ohne Vorfestlegung: kostenlose Fassung mit
Standard-Mixdown, Einmalkauf für Referenz-Mastering und Stapelverarbeitung.
Die PWA bliebe die kostenlose Auslage — sie kostet nichts und ist der beste
Weg, das Werkzeug auszuprobieren.

## Die Lizenzlage

Kommerzieller Vertrieb ist zulässig. Aber anders als bei den beiden anderen
Apps ist das Thema hier nicht „nicht-kommerziell", sondern **Copyleft**.

| Komponente | Lizenz | Bedeutung beim Verkauf |
| --- | --- | --- |
| `mp3lame-encoder`, `mp3lame-sys` (LAME 3.100) | LGPL-3.0 | Verkauf erlaubt; **Relink-Auflage** |
| `shine-rs` (nur wasm) | LGPL-2.0 | dito |
| Symphonia-Familie | MPL-2.0 | dateiweises Copyleft, unverändert genutzt — unkritisch |
| App selbst | MIT | frei |

**Die LGPL erlaubt kommerziellen Vertrieb ausdrücklich.** Ihre Auflage ist,
dass der Nutzer die Bibliothek gegen eine eigene Fassung austauschen können
muss. `docs/PLAN-PLAYSTORE.md` hält fest, dass das praktisch erfüllt ist,
*„weil das gesamte Projekt quelloffen auf GitHub liegt und der About-Dialog
dorthin verlinkt"*.

**Genau diese Begründung ist der Punkt, an dem eine Verkaufsabsicht ansetzt.**
Sie trägt, solange das Projekt quelloffen bleibt. Wer eine bezahlte Fassung
schließt, muss die Relink-Auflage anders erfüllen — üblicherweise durch
dynamisches Linken plus Bereitstellung der Objektdateien, was für einen
statisch gelinkten Flutter-Build unangenehm ist. **Empfehlung: quelloffen
bleiben und den Kauf über den Store-Komfort begründen, nicht über
Geheimhaltung.** Das ist ein etabliertes Modell und hier das mit Abstand
billigste.

Die Lizenz-Infrastruktur steht bereits: `tool/gen_rust_licenses.py` erzeugt
`assets/licenses/rust-third-party.txt` aus dem Link-Zeit-Abhängigkeitsgraphen
(176 Crates, 90 Lizenztexte), `main.dart` meldet es an `LicenseRegistry` an,
CI hält es über `--check` frisch. MP3-Patente sind seit 2017 abgelaufen.

## Die zwei offenen Punkte, die durch einen Verkauf wichtiger werden

Beide stehen bereits in `docs/PLAN-PLAYSTORE.md`; sie werden hier nicht neu
erfunden, sondern neu gewichtet.

### 1. Markenrecherche „Mixstack" und „DUREC"

In `PLAN-PLAYSTORE.md` §5 als *„der einzige Schritt, den kein Werkzeug hier
abnehmen kann"* offen. Bei kostenloser Abgabe ist eine Kollision ärgerlich —
man benennt um. **Bei bezahlter Abgabe ist sie teuer:** Ein
Unterlassungsanspruch trifft dann einen Namen, unter dem verkauft wurde, und
Google bindet die App ab dem ersten AAB-Upload unwiderruflich an ihre
Paket-ID. Die Prüfung bei DPMA und TMview gehört **vor** die erste
Einreichung, erst recht vor die erste Rechnung.

### 2. LGPL und der iOS-App-Store

`PLAN-PLAYSTORE.md` merkt selbst an, dass die LAME-LGPL *„bei einem späteren
App-Store-Weg deutlich unangenehmer"* ist als bei Play. Der Konflikt ist
bekannt: Apples Vertriebsbedingungen und die Relink-Auflage vertragen sich
schlecht. Für Play, GitHub und die PWA ist das **kein** Problem — nur der
iOS-Weg wäre betroffen. Wer dorthin will, muss den MP3-Encoder ersetzen oder
weglassen; das ist eine Entwurfsentscheidung, keine Formalie.

### 3. Der Clean-Room-Anspruch gegenüber Matchering

`engine/src/mastering.rs` ist eine Neuimplementierung der Matchering-2.0-Idee;
Matchering steht unter GPL-3.0. Die Position ist ungewöhnlich gut dokumentiert
— ausdrücklicher Vermerk, dass kein Quelltext eingesehen oder portiert wurde,
eine Aufzählung der algorithmischen Unterschiede (logarithmisch-frequente
Glättung statt LOWESS, analytische Parseval-Pegelkorrektur statt iterativem
RMS, eigener True-Peak-Limiter statt Hyrax, linearphasige FIR-Angleichung) und
ein Null-Test bei −23,5 dB.

**Einordnung, keine Bewertung:** Das ist ein Argument, keine Lizenzgewährung.
Bei kostenloser Abgabe ist das Risiko theoretisch — es gibt keinen
wirtschaftlichen Schaden, den jemand geltend machen könnte. Bei bezahlter
Abgabe wird daraus ein wirtschaftliches Risiko, weil ein Anspruch dann an
Umsatz anknüpfen kann. Die Dokumentation ist die richtige Vorsorge und sollte
so bleiben, wie sie ist; wer verkauft, sollte sie kennen.

## Empfehlung

1. **Markenrecherche zuerst.** Sie blockiert alles andere und wird durch jeden
   weiteren Schritt teurer.
2. **Play-Einreichung wie geplant zu Ende bringen** (Datenschutzerklärung,
   Store-Assets, Closed Testing) — zunächst kostenlos.
3. **Spenden als Zwischenschritt**: GitHub Sponsors, verlinkt aus dem
   About-Dialog und dem README. Keine Gewerbeanmeldung nötig, solange keine
   Gegenleistung versprochen wird.
4. **Einmalkauf erst, wenn die App im Store steht und benutzt wird** — dann
   mit Gewerbeanmeldung und Kleinunternehmerregelung (siehe
   Plattformvergleich). Von den drei Apps ist dies die, bei der sich das am
   ehesten trägt.
5. **Quelloffen bleiben.** Es kostet nichts, erfüllt die LGPL-Auflage und ist
   billiger als jede Alternative.

## Offene Punkte

- Wie viele Downloads gibt es heute? Die GitHub-Release-Statistik weiß es;
  im Repo steht es nicht.
- Für welche Funktionen bestünde tatsächlich Zahlungsbereitschaft? Der
  In-App-Rückmeldeweg (`lib/state/feedback.dart`) wäre der naheliegende Ort,
  danach zu fragen.

## Quellen

Abgerufen am 2026-08-17.

- [GitHub: Storage und Bandbreite (Releases ohne Bandbreitengrenze)](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-storage-and-bandwidth-usage)
- [Google Play: Zahlungsrichtlinie](https://support.google.com/googleplay/android-developer/answer/10281818?hl=en)
- Repo-intern: `docs/PLAN-PLAYSTORE.md`, `docs/PLAN-PWA.md`, `LICENSE`
  (Matchering-Anhang), `engine/src/mastering.rs`, `engine/Cargo.toml`,
  `tool/gen_rust_licenses.py`
- Plattformpreise und rechtlicher Rahmen:
  `MitFahrBar/doc/finanzierung-plattformvergleich.md`
