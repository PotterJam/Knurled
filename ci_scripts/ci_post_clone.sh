#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "==> Preparing Knurled iOS build artifacts"

if ! command -v rustup >/dev/null 2>&1; then
  echo "==> Installing Rust toolchain"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  export PATH="$HOME/.cargo/bin:$PATH"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "==> Installing XcodeGen"
    brew install xcodegen
  else
    echo "error: xcodegen is not installed and Homebrew is unavailable" >&2
    exit 1
  fi
fi

"$IOS_DIR/scripts/build-xcframework.sh"

echo "==> Generating Knurled.xcodeproj"
cd "$IOS_DIR"
xcodegen generate

echo "==> Xcode Cloud post-clone setup complete"
