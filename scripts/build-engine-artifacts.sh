#!/usr/bin/env bash
# Rebuild every generated artifact that embeds knurled-core.
#
# Run this after changes to engine/, workbench/engine-wasm/, or
# ios/Engine/knurled-ios-ffi/ when you need all clients to use the same engine
# snapshot.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building workbench WASM engine"
bash "$ROOT_DIR/workbench/scripts/build-wasm.sh"

echo
echo "==> Building iOS FFI xcframework"
bash "$ROOT_DIR/ios/scripts/build-xcframework.sh"

echo
echo "==> Done. Engine artifacts are up to date:"
echo "    - workbench/engine/pkg/"
echo "    - ios/Engine/KnurledCore.xcframework"
