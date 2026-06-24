#!/usr/bin/env bash
# Compiles knurled-core (via the knurled-engine-wasm bridge) to WebAssembly and
# generates the JS glue the static workbench loads. Mirrors the contract of
# ios/scripts/build-xcframework.sh: re-run after any change to engine/ or
# workbench/engine-wasm/. The generated workbench/engine/pkg/ is COMMITTED so the
# site stays a zero-server static deploy.
#
# Requires: rustup target add wasm32-unknown-unknown
#           cargo install wasm-bindgen-cli  (version must match Cargo.toml)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
crate_dir="$here/../engine-wasm"
out_dir="$here/../engine/pkg"

echo "Building knurled-engine-wasm (release, wasm32-unknown-unknown)…"
cargo build --release --target wasm32-unknown-unknown --manifest-path "$crate_dir/Cargo.toml"

wasm_in="$crate_dir/target/wasm32-unknown-unknown/release/knurled_engine.wasm"

echo "Generating JS bindings → $out_dir"
rm -rf "$out_dir"
mkdir -p "$out_dir"
wasm-bindgen "$wasm_in" --target web --out-dir "$out_dir" --out-name knurled_engine

echo "Done. Committed artifacts in workbench/engine/pkg/:"
ls -1 "$out_dir"
