#!/bin/bash
# build-touchbridge.sh – builds TouchBridge (Rust, TouchBridge/) as a static library for the iPhone into
# TouchBridge/build/ ("Touch in the car"). Then add this line to Config/Local.xcconfig:
#   #include? "TouchBridge.xcconfig"
#
# Needs rustup with the aarch64-apple-ios target. On a Mac with Homebrew:
#   brew install rustup        (keg-only: leaves a Homebrew rust in your PATH alone)
#   /opt/homebrew/opt/rustup/bin/rustup toolchain install stable --profile minimal --target aarch64-apple-ios
# Without Homebrew: https://rustup.rs, then `rustup target add aarch64-apple-ios`.
set -euo pipefail
cd "$(dirname "$0")/../TouchBridge"

# Put Homebrew's keg-only rustup in front of a Homebrew rustc – for this script only.
if [ -x /opt/homebrew/opt/rustup/bin/rustup ]; then
    export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi
command -v rustup >/dev/null || { echo "rustup missing (see the top of this script)." >&2; exit 1; }
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
# Same minimum iOS as the app.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.2}"

cargo build --release --target aarch64-apple-ios
mkdir -p build
cp target/aarch64-apple-ios/release/libtouchbridge.a build/libtouchbridge.a
echo "Built: $(pwd)/build/libtouchbridge.a ($(du -h build/libtouchbridge.a | cut -f1))"
