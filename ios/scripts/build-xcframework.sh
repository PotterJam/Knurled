#!/usr/bin/env bash
#
# Builds ios/Engine/KnurledCore.xcframework from the knurled-ios-ffi Rust crate.
# Produces device (arm64) and simulator (arm64 + x86_64 fat) slices.
#
# Usage: ios/scripts/build-xcframework.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FFI_DIR="$IOS_DIR/Engine/knurled-ios-ffi"
HEADERS_DIR="$FFI_DIR/include"
OUT="$IOS_DIR/Engine/KnurledCore.xcframework"
LIB="libknurled_ios_ffi.a"

DEVICE_TARGET="aarch64-apple-ios"
SIM_ARM_TARGET="aarch64-apple-ios-sim"
SIM_X86_TARGET="x86_64-apple-ios"
TARGETS=("$DEVICE_TARGET" "$SIM_ARM_TARGET" "$SIM_X86_TARGET")

echo "==> Ensuring Rust iOS targets are installed"
rustup target add "${TARGETS[@]}"

cd "$FFI_DIR"
for target in "${TARGETS[@]}"; do
  echo "==> Building $target (release)"
  cargo build --release --target "$target"
done

BUILD_DIR="$FFI_DIR/target"
SIM_FAT_DIR="$BUILD_DIR/sim-universal/release"
mkdir -p "$SIM_FAT_DIR"

echo "==> Creating universal simulator library (arm64 + x86_64)"
lipo -create \
  "$BUILD_DIR/$SIM_ARM_TARGET/release/$LIB" \
  "$BUILD_DIR/$SIM_X86_TARGET/release/$LIB" \
  -output "$SIM_FAT_DIR/$LIB"

echo "==> Assembling $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$BUILD_DIR/$DEVICE_TARGET/release/$LIB" -headers "$HEADERS_DIR" \
  -library "$SIM_FAT_DIR/$LIB" -headers "$HEADERS_DIR" \
  -output "$OUT"

echo "==> Done: $OUT"
