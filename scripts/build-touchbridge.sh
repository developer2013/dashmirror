#!/bin/bash
# Baut TouchBridge (Rust, TouchBridge/) als statische Bibliothek fuers iPhone nach TouchBridge/build/.
# Danach in Config/Local.xcconfig:  #include? "TouchBridge.xcconfig"
#
# Braucht rustup mit dem Ziel aarch64-apple-ios. Auf einem Mac mit Homebrew-Rust:
#   brew install rustup        (keg-only, aendert den PATH nicht)
#   /opt/homebrew/opt/rustup/bin/rustup toolchain install stable --profile minimal --target aarch64-apple-ios
set -euo pipefail
cd "$(dirname "$0")/../TouchBridge"

# rustup vor ein evtl. vorhandenes Homebrew-rustc stellen – nur fuer dieses Skript.
if [ -x /opt/homebrew/opt/rustup/bin/rustup ]; then
    export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi
command -v rustup >/dev/null || { echo "rustup fehlt (siehe Kopf dieses Skripts)." >&2; exit 1; }
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
# Gleiches Mindest-iOS wie die App (Config/Signing.xcconfig bzw. Projekt).
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.2}"

cargo build --release --target aarch64-apple-ios
mkdir -p build
cp target/aarch64-apple-ios/release/libtouchbridge.a build/libtouchbridge.a
echo "Gebaut: $(pwd)/build/libtouchbridge.a ($(du -h build/libtouchbridge.a | cut -f1))"
