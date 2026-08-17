#!/usr/bin/env bash
# screenshots_web.sh — die Telefon-Screenshots aus dem Web-Build erzeugen.
#
# Der Android-Weg (`make_screenshots.sh -d <id>`) hängt derzeit nach dem
# Installieren und erreicht nie SCREENSHOT_DIR; siehe AGENTS.md, „The Android
# emulator". Die PWA zeigt dasselbe Telefon-Layout — der Umbruch liegt bei 640
# logischen Pixeln — und ist ohne Gerät reproduzierbar. Vorbild ist MitFahrBars
# tool/screenshots.sh.
#
#   ./tool/screenshots_web.sh          # Port 8732
#   ./tool/screenshots_web.sh 9000     # anderer Port
#
# Die Desktop-Bilder kommen weiterhin aus `tool/make_screenshots.sh` (macOS).
set -euo pipefail

port="${1:-8732}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

command -v node >/dev/null || { echo "node fehlt — Playwright braucht Node.js." >&2; exit 1; }

work="$(mktemp -d)"
cleanup() {
  [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "→ wasm-Engine …"
./tool/build_web_engine.sh

echo "→ Web-Build …"
flutter build web

# `flutter build web` kopiert web/pkg nicht (wasm-pack legt dort ein
# Catch-all-.gitignore ab) — ohne das lädt die Seite und stirbt dann an der
# fehlenden wasm. Dieselbe Handreichung wie in pages.yml.
mkdir -p build/web/pkg
cp web/pkg/rust_lib_durecmix.js \
   web/pkg/rust_lib_durecmix_bg.wasm \
   web/pkg/package.json build/web/pkg/
test -s build/web/pkg/rust_lib_durecmix_bg.wasm

echo "→ Testaufnahme …"
fixture="$work/UFX33_01_Demo.wav"
cargo run -q -p durecmix-engine --release --example gen_fixture "$fixture"
test -s "$fixture"

# Threaded wasm braucht COOP/COEP. Im Netz installiert web/coi-sw.js sie aus
# einem Service Worker; lokal ist ein Server, der sie direkt setzt, schneller
# und eine Fehlerquelle weniger.
echo "→ ausliefern auf Port $port (mit COOP/COEP) …"
cat > "$work/serve.py" <<'PY'
import http.server, os, sys
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def log_message(self, *a): pass
os.chdir(sys.argv[2])
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$work/serve.py" "$port" "$root/build/web" &
server_pid=$!
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$port/" >/dev/null && break
  python3 -c 'import time; time.sleep(1)'
done

echo "→ Playwright bereitstellen …"
(cd "$work" && npm init -y >/dev/null && npm install --silent playwright >/dev/null)
(cd "$work" && npx --yes playwright install chromium >/dev/null 2>&1)

echo "→ Screenshots …"
mkdir -p docs/screenshots
# Die Skripte laufen neben node_modules: ESM-Importe ignorieren NODE_PATH,
# „playwright" wäre sonst nicht auflösbar.
cp tool/screenshots_web.mjs "$work/"
(cd "$work" && SCREENSHOT_URL="http://127.0.0.1:$port/" \
  SCREENSHOT_OUT="$root/docs/screenshots" \
  SCREENSHOT_FIXTURE="$fixture" \
  node screenshots_web.mjs)

# Eigene Namen, bewusst NICHT die *_android.png der Doku: die trägt
# annotierte Fassungen mit nummerierten Legenden, deren Marker-Rechtecke nur
# im Integrationstest aus dem Live-Widget-Baum fallen. Der Browser-Weg kann
# sie nicht erzeugen — würde er die einfachen Bilder überschreiben, zeigten
# Bild und Legende zwei verschiedene Darstellungen. Diese hier sind die
# Store-Quelle, `tool/store_assets.py` bevorzugt sie.
for f in phone phone_menu; do
  [ -f "docs/screenshots/$f.png" ] && mv "docs/screenshots/$f.png" "docs/screenshots/${f}_web.png"
done

echo "✓ fertig — docs/screenshots/phone_web.png, phone_menu_web.png"
echo "  Store-Grafiken daraus:  tool/store_assets.py"
