#!/usr/bin/env bash
# Builds the Rust engine as a threaded wasm bundle into web/pkg
# (docs/PLAN-PWA.md, S1). Replaces `flutter_rust_bridge_codegen build-web`:
# FRB 2.12 passes only the target features, but current nightlies no longer
# derive `--shared-memory` from `+atomics` at link time — without the
# explicit link args the module gets a non-shared memory and FRB's worker
# pool dies at startup with "DataCloneError: #<Memory> could not be cloned".
#
# Prerequisites (one-time):
#   rustup toolchain install nightly
#   rustup component add rust-src --toolchain nightly
#   rustup target add wasm32-unknown-unknown --toolchain nightly
#   cargo install wasm-pack
#
# After building: `flutter build web` does NOT copy web/pkg (wasm-pack drops
# a catch-all .gitignore there) — copy build/web/pkg yourself when deploying.
set -euo pipefail
cd "$(dirname "$0")/../rust"

# Release by default: a --dev bundle is ~7× larger (4.8 MB vs 674 KB) and
# analysing a 376 MB take takes noticeably longer, so shipping one would be
# a silent regression. Pass --dev only to debug the Rust side.
PROFILE_FLAG="--release"
if [[ "${1:-}" == "--dev" ]]; then
  PROFILE_FLAG="--dev"
fi

export RUSTUP_TOOLCHAIN=nightly
# --import-memory: wasm-bindgen's thread transform asserts the memory is
# imported (the JS glue creates the shared WebAssembly.Memory and hands it
# to main thread and workers). --export=__heap_base: wasm-bindgen injects
# its thread-id bootstrap there and current lld no longer exports the
# symbol on its own.
export RUSTFLAGS="-C target-feature=+atomics,+bulk-memory,+mutable-globals \
-C link-arg=--shared-memory -C link-arg=--max-memory=1073741824 \
-C link-arg=--import-memory -C link-arg=--export=__heap_base \
-C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size \
-C link-arg=--export=__tls_align -C link-arg=--export=__tls_base"

wasm-pack build -t no-modules -d ../web/pkg --no-typescript \
  --out-name rust_lib_durecmix "$PROFILE_FLAG" . \
  -- -Z build-std=std,panic_abort

echo "web/pkg ready:"
ls -la ../web/pkg/
