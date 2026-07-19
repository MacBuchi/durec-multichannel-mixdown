#!/usr/bin/env bash
# Regenerate the documentation screenshots (docs/screenshots/).
#
#   tool/make_screenshots.sh            # desktop shots via macOS
#   tool/make_screenshots.sh -d <id>    # e.g. an Android emulator device id
#
# Runs the integration test in SCREENSHOTS mode (deterministic synthetic
# fixture, real engine), annotates every shot that carries a marker JSON via
# tool/annotate_screenshots.py, and copies the results into docs/screenshots/.
# On Android devices the PNGs are pulled off the device app cache first.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="macos"
if [ "${1:-}" = "-d" ]; then DEVICE="$2"; fi

LOG=$(mktemp)
if [ "$DEVICE" = "macos" ]; then
  flutter test integration_test -d "$DEVICE" --dart-define=SCREENSHOTS=true | tee "$LOG"
  SHOTS=$(grep -o 'SCREENSHOT_DIR=.*' "$LOG" | tail -1 | cut -d= -f2)
  [ -n "$SHOTS" ] || { echo "no SCREENSHOT_DIR in test output"; exit 1; }
else
  # Skip the x86 emulator ABIs cargokit forces into debug builds — LAME's
  # configure trips over '-mtune=native' resolving to apple-m1 when
  # cross-compiling i686 on Apple Silicon (see cargokit/gradle/plugin.gradle).
  export CARGOKIT_NO_EMULATOR_ABIS=1
  # Device run: the shots land in the app's code_cache, which the harness
  # deletes when it uninstalls the app after the test. The test keeps the
  # app alive for ~30 s after printing SCREENSHOT_DIR — pull within that
  # window via run-as, while the test is still running.
  flutter test integration_test -d "$DEVICE" --dart-define=SCREENSHOTS=true > "$LOG" 2>&1 &
  TESTPID=$!
  DEVDIR=""
  for _ in $(seq 1 600); do
    DEVDIR=$(grep -o 'SCREENSHOT_DIR=.*' "$LOG" | tail -1 | cut -d= -f2 | tr -d '\r' || true)
    [ -n "$DEVDIR" ] && break
    kill -0 "$TESTPID" 2>/dev/null || break
    python3 -c 'import time; time.sleep(2)' # plain sleep is unavailable in some sandboxes
  done
  [ -n "$DEVDIR" ] || { echo "no SCREENSHOT_DIR in test output"; tail -20 "$LOG"; exit 1; }
  PULLED=$(mktemp -d)
  adb -s "$DEVICE" shell "run-as de.macbuchi.durecmix sh -c 'cd $DEVDIR && tar cf - .'" | tar xf - -C "$PULLED"
  wait "$TESTPID" || { echo "test failed"; tail -20 "$LOG"; exit 1; }
  SHOTS="$PULLED"
fi

# Annotation needs pillow; keep a tiny venv beside the build outputs.
VENV=build/screenshot-venv
[ -x "$VENV/bin/python" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" -q install pillow; }
"$VENV/bin/python" tool/annotate_screenshots.py "$SHOTS"

DEST=docs/screenshots
mkdir -p "$DEST"
if [ "$DEVICE" = "macos" ]; then
  cp "$SHOTS"/mixer.png "$SHOTS"/eq.png "$SHOTS"/batch.png "$SHOTS"/mastering.png \
     "$SHOTS"/browser.png "$SHOTS"/*_annotated.png "$DEST"/
else
  for f in phone phone_menu; do
    [ -f "$SHOTS/$f.png" ] && cp "$SHOTS/$f.png" "$DEST/${f}_android.png"
    [ -f "$SHOTS/${f}_annotated.png" ] && cp "$SHOTS/${f}_annotated.png" "$DEST/${f}_android_annotated.png"
  done
fi
echo "→ $DEST updated from $SHOTS"
