const fs = require('fs');
const crypto = require('crypto');
const path = require('path');

const root = path.resolve(__dirname, '..');
const bundlePath = path.join(root, 'QuantumSwapWallet', 'Resources', 'quantumswap-bundle.js');
const outPath = path.join(root, 'QuantumSwapWallet', 'Generated', 'BundleHash_Generated.swift');

const hex = crypto.createHash('sha256').update(fs.readFileSync(bundlePath)).digest('hex');
const bytes = [...Buffer.from(hex, 'hex')];
const rows = [];
for (let i = 0; i < 32; i += 8) {
  const chunk = bytes
    .slice(i, i + 8)
    .map((b) => '0x' + b.toString(16).padStart(2, '0'))
    .join(', ');
  rows.push('        ' + chunk + (i + 8 < 32 ? ',' : ''));
}

const out = `//
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
${rows.join('\n')}
    ]

    /// Same digest as a 64-character lowercase hex string. Used by
    /// review-friendly logging in DEBUG builds.
    public static let sha256Hex: String = "${hex}"
}
`;

fs.writeFileSync(outPath, out);
console.log('regenerated', outPath, hex);
