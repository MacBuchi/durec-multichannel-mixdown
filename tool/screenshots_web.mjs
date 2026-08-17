// screenshots_web.mjs — die Telefon-Screenshots aus dem laufenden Web-Build.
//
// Nicht direkt aufrufen, sondern über `tool/screenshots_web.sh` — das baut
// Engine und App, liefert sie mit den nötigen Kopfzeilen aus und räumt auf.
//
// Warum der Browser und nicht der Emulator: der Android-Weg über
// `make_screenshots.sh -d <id>` hängt nach dem Installieren und erreicht nie
// SCREENSHOT_DIR (AGENTS.md, „The Android emulator"). Die PWA ist ohnehin ein
// vollwertiges Ziel und zeigt dasselbe Telefon-Layout — der Umbruch liegt bei
// 640 logischen Pixeln, und 432 liegt darunter.
//
// Flutter-Web zeichnet auf Canvas. Der Semantics-Baum trägt hier nur die
// Spurzeilen und das Feedback-Banner; jede Schaltfläche ist Canvas und wird
// über Koordinaten getroffen. Die Spurzeilen reichen als Beweis, dass die
// Aufnahme wirklich geladen ist — ohne den würde ein leeres Bild als Erfolg
// durchgehen.
import { chromium } from 'playwright';

const BASE = process.env.SCREENSHOT_URL ?? 'http://127.0.0.1:8732/';
const OUT = process.env.SCREENSHOT_OUT ?? 'docs/screenshots';
const FIXTURE = process.env.SCREENSHOT_FIXTURE;

// 432×768 bei Faktor 2.5 ergibt exakt 1080×1920 — Plays empfohlene Auflösung
// und exakt 9:16. Damit muss nachher nichts aufgefüllt werden: die Bilder vom
// Gerät kamen mit 840×1720, also 1:2,048, und lagen über Plays 2:1-Grenze.
const VIEWPORT = { width: 432, height: 768 };
const SCALE = 2.5;

// Koordinaten im Viewport, aus Screenshots abgelesen. Verschiebt sich das
// Layout, sehen die Bilder sofort falsch aus und es fällt im PR auf.
const DISMISS_BANNER = [337, 80];   // ✕ des Feedback-Banners
const CHOOSE_FILES = [216, 514];    // Knopf auf dem Startschirm — OHNE Banner
const FIRST_ROW = [216, 88];        // erste Zeile der Dateiliste
const OVERFLOW = [412, 28];         // ⋯ in der App-Leiste des Mixers

const browser = await chromium.launch();

async function open() {
  const page = await browser.newPage({
    viewport: VIEWPORT,
    deviceScaleFactor: SCALE,
    // Ohne das erwischt jeder Lauf eine andere Phase des Logo-Ripples, und
    // jeder Durchlauf erzeugte ein neues Bild.
    reducedMotion: 'reduce',
    // Die App folgt ab Werk dem System. Die Tablet-Bilder sind dunkel, und
    // dunkel ist die Bildsprache der App — sonst stünde im Store ein helles
    // Telefon neben einem dunklen Tablet.
    colorScheme: 'dark',
  });
  page.on('pageerror', (e) => console.error('JS-Fehler in der App:', e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') console.error('!!', m.text());
  });
  // Vorab registrieren: Playwright fängt den Datei-Dialog nur ab, wenn jemand
  // horcht. Ohne den Handler verschwindet der Dialog ungenutzt und die App
  // bekommt nie eine Datei — das kostete beim Bauen zwei Anläufe.
  page.on('filechooser', async (fc) => { await fc.setFiles(FIXTURE); });

  await page.goto(BASE, { waitUntil: 'networkidle' });
  // coi-sw.js installiert COOP/COEP aus einem Service Worker und übernimmt
  // erst danach; ohne den zweiten Aufruf hat die Seite keine
  // SharedArrayBuffer und der Worker-Pool der Engine stirbt beim Start.
  await page.waitForTimeout(2500);
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForTimeout(5000);
  // Flutter baut den a11y-Baum erst auf Anforderung — nur dispatchEvent löst
  // das aus, .click() und ein selbstgebautes MouseEvent nicht.
  await page.locator('flt-semantics-placeholder').dispatchEvent('click').catch(() => {});
  await page.waitForTimeout(1500);
  // Das Banner würde jeden Screenshot um seine Höhe verschieben und gehört
  // nicht in einen Store-Eintrag. Danach sitzt der Öffnen-Knopf höher —
  // deshalb ist CHOOSE_FILES am bannerlosen Schirm gemessen.
  await page.mouse.click(...DISMISS_BANNER);
  await page.waitForTimeout(800);
  return page;
}

async function labels(page) {
  const out = [];
  for (const n of await page.locator('flt-semantics[aria-label]').all()) {
    out.push((await n.getAttribute('aria-label')) ?? '');
  }
  return out;
}

/** Bis zu 30 s darauf warten, dass ein Label passt — die Assertionsseite. */
async function expectLabel(page, re, hint) {
  for (let i = 0; i < 60; i++) {
    if ((await labels(page)).some((l) => re.test(l))) return;
    await page.waitForTimeout(500);
  }
  throw new Error(`${hint}: nichts passt auf ${re}. Vorhanden: ${(await labels(page)).join(' | ')}`);
}

async function shot(page, name) {
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log(`${OUT}/${name}.png`);
}

/** Startschirm → Dateiliste → Mixer. Im Browser gibt es keine Pfade, die
 *  Aufnahme muss durch den Datei-Dialog, und die Liste steht dazwischen. */
async function toMixer(page) {
  await page.mouse.click(...CHOOSE_FILES);
  await page.waitForTimeout(9000);   // Kopfdaten lesen, iXML auswerten
  await page.mouse.click(...FIRST_ROW);
  await expectLabel(page, /Vocals/, 'Mixer nach dem Öffnen der Aufnahme');
  await page.waitForTimeout(2500);   // Wellenformen fertig zeichnen lassen
}

try {
  // 1 · Der Mixer mit geladener Aufnahme — das Bild, das die meisten allein sehen.
  {
    const page = await open();
    await toMixer(page);
    await shot(page, 'phone');
    await page.close();
  }

  // 2 · Das Überlaufmenü: alles, was auf dem Telefon nicht in die Leiste passt.
  {
    const page = await open();
    await toMixer(page);
    await page.mouse.click(...OVERFLOW);
    await page.waitForTimeout(1500);
    await shot(page, 'phone_menu');
    await page.close();
  }
} catch (e) {
  console.error('Fehlgeschlagen:', e.message);
  process.exitCode = 1;
} finally {
  await browser.close();
}
