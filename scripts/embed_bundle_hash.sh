#!/bin/bash
# embed_bundle_hash.sh
#
# Pre-Build script (wired in project.yml preBuildScripts): recompute the
# SHA-256 of the shipping JS bundle bytes
# (QuantumSwapWallet/Resources/quantumswap-bundle.js) and regenerate the
# Swift constant the wallet checks at runtime via BundleIntegrity. The
# constant is compiled into the app binary where it inherits the code
# signature, so a re-signer who swaps the bundle has to ALSO patch the
# binary -- which invalidates the signature unless the re-signer holds
# the original signing identity.
#
# Mirrors the Android embedBundleHash Gradle task in app/build.gradle.
# Same byte format (32 raw bytes + 64-char lowercase hex) so a single
# hex string can be compared between the two builds to confirm
# bit-for-bit bundle parity.
#
# The generated file is committed to git for reproducible builds and so
# the constant can be diffed alongside the bundle bytes in the same PR.
set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUNDLE_FILE="$SRCROOT/QuantumSwapWallet/Resources/quantumswap-bundle.js"
OUTPUT_DIR="$SRCROOT/QuantumSwapWallet/Generated"
OUTPUT_FILE="$OUTPUT_DIR/BundleHash_Generated.swift"

if [ ! -f "$BUNDLE_FILE" ]; then
    echo "embed_bundle_hash.sh: shipping bundle not found at $BUNDLE_FILE." >&2
    echo "Refusing to regenerate the runtime hash check." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

if command -v shasum >/dev/null 2>&1; then
    HEX="$(shasum -a 256 "$BUNDLE_FILE" | awk '{print $1}')"
else
    HEX="$(sha256sum "$BUNDLE_FILE" | awk '{print $1}')"
fi

# 32 bytes -> four rows of eight 0x.. literals.
BYTES_BLOCK="$(echo "$HEX" | sed 's/../0x&, /g; s/, $//' | fold -w 48 | sed 's/^/        /; s/[[:space:]]*$//')"
# fold leaves a trailing comma on all but the last row already; ensure
# rows except the last end with a comma.
BYTES_BLOCK="$(echo "$BYTES_BLOCK" | sed '$!s/$/,/' | sed 's/,,$/,/')"

cat > "$OUTPUT_FILE" <<EOF
//
// BundleHash_Generated.swift
//
// AUTO-GENERATED at build time by
// scripts/embed_bundle_hash.sh.
//
// DO NOT EDIT. Any local changes will be overwritten on the next
// build. To intentionally change the embedded hash, replace the
// shipping \`Resources/quantumswap-bundle.js\` with the new bundle
// and let the Pre-Build script regenerate this file.
//
// The bytes below are the SHA-256 digest of the EXACT bytes shipping
// inside the app bundle at build time. \`BundleIntegrity\` re-hashes
// the loaded bundle at runtime and refuses to initialize the JS
// bridge if the hashes differ.
//
// swiftlint:disable all
//

import Foundation

public enum GeneratedBundleHash {
    /// SHA-256 digest of \`quantumswap-bundle.js\`, computed at build
    /// time. 32 bytes.
    public static let sha256: [UInt8] = [
$BYTES_BLOCK
    ]

    /// Same digest as a 64-character lowercase hex string. Used by
    /// review-friendly logging in DEBUG builds.
    public static let sha256Hex: String = "$HEX"
}
EOF

echo "embed_bundle_hash.sh: regenerated BundleHash_Generated.swift (sha256=${HEX:0:16}...)"
