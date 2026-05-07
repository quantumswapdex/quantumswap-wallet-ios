# Quantum Coin Wallet — iOS

[![Platform: iOS 15+](https://img.shields.io/badge/platform-iOS%2015%2B-blue)](https://developer.apple.com/ios/)
[![Swift: 5.9](https://img.shields.io/badge/swift-5.9-orange)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Native iOS client for the [Quantum Coin](https://quantumcoin.org)
post-quantum blockchain. Quantum Coin is a Layer-1 quantum-resistant
blockchain that combines NIST-standardized post-quantum signature
schemes — **ML-DSA (FIPS 204)** and **SLH-DSA (FIPS 205)** — with
**ML-KEM (FIPS 203)** for node-to-node key establishment, all under
a deposit-weighted BFT consensus with immediate deterministic
finality. See the
[quantum-resistance whitepaper](https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Quantum-Resistance-Whitepaper.html)
and [consensus whitepaper](https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Consensus-Whitepaper.html)
for the protocol-level rationale.

This repository hosts the **iOS** wallet. It is a feature-parity port
of the [Quantum Coin Android wallet](https://github.com/quantumcoinproject/quantum-coin-wallet-android)
and shares the same JavaScript SDK bundle byte-for-byte, so every
signed transaction is reproducible across both clients.

> **Status:** beta. The mainnet RPC is configured at
> `https://public.rpc.quantumcoinapi.com` (chain id `123123`). See
> [`Resources/blockchain_networks.json`](QuantumCoinWallet/Resources/blockchain_networks.json).

> **This software is not an investment opportunity, an investment
> contract, or a security of any type.** See the
> [Quantum Coin homepage](https://quantumcoin.org) for the project's
> charter and decentralization-first stance.

---

## Table of contents

- [Audience](#audience)
- [Feature list](#feature-list)
- [Security & durability features](#security--durability-features)
- [SDKs and dependencies](#sdks-and-dependencies)
- [Architecture overview](#architecture-overview)
- [Repository layout](#repository-layout)
- [Build and run](#build-and-run)
- [Testing](#testing)
- [Threat model & non-goals](#threat-model--non-goals)
- [License](#license)
- [Further reading](#further-reading)

---

## Audience

This README is written for three concurrent readers:

1. **End users / developers** evaluating the wallet — start with
   [Feature list](#feature-list) and [Build and run](#build-and-run).
2. **Security auditors and cryptography reviewers** — start with
   [Security & durability features](#security--durability-features),
   then [Architecture overview](#architecture-overview). Every Swift
   file in the codebase carries a `(notes for reviewers)` comment
   explaining design rationale and tradeoffs in plain prose.
3. **AI code reviewers** (Claude / GPT / Gemini / Grok / Composer
   class agents) — the file-level docstrings, the layered storage /
   crypto / bridge separation, and the explicit cross-references in
   each comment are designed so an agent can reconstruct the trust
   boundary without grep'ing the whole tree. Look for
   `Cross-references` blocks inside the longer doc comments.

---

## Feature list

### Wallet management

- **Multiple wallets per install.** Stored in a single
  layered-encrypted strongbox; each wallet is addressable via the
  Wallets screen (`Screens/WalletsViewController.swift`).
- **New wallet creation** with a 32-word seed phrase (
  `QuantumCoinSDK.Wallet.createRandom` →
  `SeedWordsSDK.getWordListFromSeedArray`). Seed verification quiz
  is enforced before the wallet is persisted.
- **Restore from seed words** with BIP39-style prefix
  auto-completion (`Components/SeedAutoCompleteTextField.swift`,
  word list mirrored in `JsBridge/BIP39Words.swift`).
- **Restore from `.wallet` backup file** — single file or a folder
  of files; batched password prompt walks through every wallet in
  the picked location (`Backup/RestoreFlow.swift`).
- **Reveal seed words** (gated by tap-to-reveal +
  voice-over / accessibility lockout, see
  `Screens/RevealWalletViewController.swift`).
- **Delete wallet / delete all** with explicit confirm dialogs.

### Sending and receiving

- **Send native QC** via the SDK's
  `wallet.sendTransaction({to, value, gasLimit, signingContext})`
  (matches Android byte-for-byte; see
  [JS SDK boundaries](#sdks-and-dependencies) below).
- **Send tokens (ERC-20-style)** via
  `IERC20.connect(contract, wallet).transfer(...)`. Token list is
  partitioned into **Tokens** (recognized) and **Unrecognized
  Tokens** tabs; impersonator filter blocks any token whose
  symbol or name resembles a stablecoin unless the contract is
  on the recognized allow-list (`Models/RecognizedTokens.swift`,
  `Models/StablecoinImpersonatorFilter.swift`).
- **Transaction review dialog** with checksum-cased addresses,
  fee summary, and explicit contract-address row for token sends
  (`Dialogs/TransactionReviewDialogViewController.swift`).
- **QR-code scanning** for recipient addresses via the system
  camera (`Components/QRScannerViewController.swift`,
  `NSCameraUsageDescription` declared in `Info.plist`).
- **Receive screen** with a `quantumcoin:` URI QR code and a
  centred copy-to-clipboard control
  (`Screens/ReceiveViewController.swift`).

### Network configuration

- **Mainnet preconfigured** at chain id `123123` and the public
  RPC endpoint
  (`Resources/blockchain_networks.json`).
- **Custom network support** — the user can add and switch between
  networks; the active network is captured at "Review" time and
  re-asserted at "Submit" time so a network switch in the middle
  of the signing flow aborts rather than producing a mis-bound
  transaction (`Networking/NetworkConfig.swift`).

### Backup and restore

- **File backup** via `UIDocumentPickerViewController(forExporting:)`
  — wallet is re-encrypted under a user-supplied backup password
  (independent of the unlock password), then handed to the picker.
- **Cloud-folder backup** — user picks a folder once
  (typically iCloud Drive) and subsequent writes go to a
  remembered security-scoped bookmark; an explicit
  "submitted to iCloud, sync may take time" dialog runs after
  iCloud writes so the user knows the file isn't yet on Apple's
  servers (`Backup/CloudBackupManager.swift`).
- **Restore from cloud folder** enumerates `.wallet` files in the
  remembered folder and runs the same batched-decrypt loop the
  file restore uses (`Backup/RestoreFlow.swift`).
- **Cross-platform backup compatibility** — the encrypted JSON
  envelope shape is byte-identical to the Android wallet's, so a
  backup created on one platform restores cleanly on the other.

### Localization and accessibility

- English (`en_us`) localization with 230+ keys
  (`Resources/en_us.json`,
  `Localization/Localization.swift`).
- VoiceOver / accessibility deliberately disabled on the four
  seed-handling surfaces (reveal, new-seed, verify, restore) so
  the seed words are never read aloud (`Screens/HomeWalletViewController.swift`).
- Dark mode with a small palette of semantic colors; primary
  buttons invert foreground in dark mode for contrast.

---

## Security & durability features

This is a high-value-asset wallet — every defense below has a
dedicated `(notes for reviewers)` comment in its source file with
the threat it closes, the design rationale, and the tradeoff the
team accepted. Search for `notes for reviewers` to find them.

### Key material and signing

- **AES-256-GCM** for every encrypted-at-rest blob, in a single
  Swift owner so there is one review surface for AEAD usage
  (`Crypto/Aead.swift`).
- **scrypt KDF** at `N=2^18, r=8, p=1, keyLen=32` — runs inside the
  shared JS bundle so the Android and iOS wallets derive identical
  keys for identical passwords. Min-bound enforced at the bridge
  boundary so a future debug-weakened call fails loud
  (`Crypto/PasswordKdf.swift`, `Resources/bridge.html` `scryptDerive`).
- **Brute-force lockout** with a stair-step backoff
  (typo-tolerant for the first four attempts; 30s, 60s, 2 min,
  5 min cap). Counter lives in Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) so it survives
  pref-file deletion (`Security/UnlockAttemptLimiter.swift`).
- **Tamper gate** — multi-signal jailbreak / debugger-attached /
  Mach-O-instrumentation detector. Requires ≥2 independent
  jailbreak signals before flagging; debugger-in-Release and
  runtime-tamper are hard signals. The signing chokepoint
  (`JsBridge.sendTransaction`) calls `assertSafeToSign()` before
  the private key reaches the bridge
  (`Security/TamperGate.swift`, `Security/TamperGatePolicy.swift`).
- **JS bundle SHA-256 pin** — the bundle owns every signing
  primitive, so its bytes are hashed at build time, embedded in a
  Swift `[UInt8]`, re-hashed at runtime, and the bridge refuses to
  initialize on mismatch (`scripts/embed_bundle_hash.sh`,
  `JsBridge/BundleIntegrity.swift`).
- **Binary key channel** between Swift and JS — private/public
  key bytes stage as `Uint8Array` via a synchronous custom-scheme
  XHR rather than base64 strings, so JS can `.fill(0)` them after
  use (string-pool residency would otherwise prevent zeroization)
  (`Resources/bridge.html` `pullPayloadBinary` /
  `JsEngine.PendingBinaryStore`).
- **TLS pinning** on the centralized scan API only. RPC endpoints
  are deliberately **not** pinned — the wallet is non-custodial
  and the user must be free to choose any RPC node (full node,
  Infura-class third party, community RPC). Pinning the RPC would
  hard-code centralization that the project explicitly rejects.
  Baseline TLS chain validation still applies on every endpoint
  (`Networking/TlsPinning.swift`).

### Storage durability

- **Two-slot rotating writer** for the strongbox file, so a power
  cut between rename and journal-flush still leaves a valid
  previous-good slot (`Storage/AtomicSlotWriter.swift`).
- **`fcntl(F_FULLFSYNC)`** on every persisted file so bytes reach
  the storage media, not just the page cache. iOS's `fsync` does
  not guarantee media-level flush.
- **Verify-before-promote** — after `F_FULLFSYNC`, the writer
  re-reads the staged bytes uncached, hands them to a
  schema-aware deep-verify closure, and only then renames the
  `.tmp` into place. Catches NAND bit-flips, encoder bugs, and
  stale-key MAC mismatches.
- **File-level MAC** with a UI-block hash binding so an attacker
  who swaps slot files' UI prefs cannot re-bind them under the
  original MAC (`Schema/StrongboxFileCodec.swift`).
- **`.completeFileProtection`** on every file the wallet writes.
- **`isExcludedFromBackupKey`** wired through a layered
  `BackupExclusion` so the user's "phone backup" toggle decides
  whether wallet files participate in iCloud / iTunes backups
  (`Backup/BackupExclusion.swift`).

### UI hardening

- **App-switcher snapshot redaction** — opaque branded overlay is
  added in `applicationWillResignActive` so the iOS-captured app
  switcher card never contains seed words, balances, or addresses
  (`UX/SnapshotRedactor.swift`).
- **Pasteboard auto-expiry** for copied seed phrases (30s
  countdown; cleared on view-disappear) (`UX/Pasteboard.swift`).
- **Screen-capture guard** on the seed-reveal screen
  (`Security/ScreenCaptureGuard.swift`).
- **Token impersonation defenses** — recognized-token allow-list
  by **contract address** (not name/symbol), plus a stablecoin
  impersonator hard-suppressor that blocks any token whose label
  resembles `USDT` / `USDC` / `Tether` / etc. unless its contract
  is on the allow-list (`Models/RecognizedTokens.swift`,
  `Models/StablecoinImpersonatorFilter.swift`).
- **Network-snapshot capture at Review time** — the chain id and
  RPC endpoint the user confirmed are re-asserted at Submit time;
  a network switch mid-flight aborts rather than producing a
  mis-bound EIP-155 signature (`Networking/NetworkConfig.swift`).

### Defense layering recap

Each layer below independently raises an attacker's cost; they
combine multiplicatively, not additively:

| Layer | Mechanism |
| --- | --- |
| Storage  | Two-slot rotation + `F_FULLFSYNC` + verify-before-promote |
| Schema   | File-level MAC binds wraps + payload + UI-block hash |
| Crypto   | AES-256-GCM AEAD + scrypt-derived 32-byte keys |
| Unlock   | scrypt cost + Keychain-backed brute-force lockout |
| Runtime  | Tamper gate + JS bundle SHA-256 pin |
| UI       | Snapshot redaction + pasteboard expiry + impersonator filter |
| Network  | TLS chain validation on all + SPKI pin on scan API |

---

## SDKs and dependencies

The iOS wallet has **zero CocoaPods / Carthage / SwiftPM
dependencies**. Every external piece of code ships in either:

- **Apple frameworks** linked from the iOS SDK
  (`UIKit`, `WebKit`, `CryptoKit`, `Security`, `Foundation`,
  `UniformTypeIdentifiers`), or
- **A single bundled JavaScript file** (`quantumcoin-bundle.js`,
  ≈12.3 MiB, MIT-licensed) loaded into a `WKWebView`.

That single file exposes **two** browser globals the bridge
consumes:

| Global | Purpose | Used in iOS |
| --- | --- | --- |
| `QuantumCoinSDK` | Wallet construction, address helpers, JSON-RPC provider, IERC20 contract helper, scrypt KDF, AEAD wallet envelopes | `Resources/bridge.html` (~36 callsites) |
| `SeedWordsSDK` | BIP39-style seed-word lookup tables | `Resources/bridge.html` (4 callsites — `getWordListFromSeedArray`, `getAllSeedWords`, `doesSeedWordExist`) |

Both globals are produced upstream from two distinct SDK packages:

| Upstream SDK | Repository | Role in the bundle |
| --- | --- | --- |
| `quantumcoin.js` | <https://github.com/quantumcoinproject/quantumcoin.js> | The ethers.js-compatible wrapper that exposes the high-level `Wallet` / `JsonRpcProvider` / `IERC20` surface this wallet calls (`wallet.sendTransaction`, `token.transfer`, `wallet.getSigningContext`, `wallet.populateTransaction`). |
| `quantum-coin-js-sdk` | <https://github.com/quantumcoinproject/quantum-coin-js-sdk> | The lower-level Quantum Coin JS SDK (npm: `quantum-coin-js-sdk`) that `quantumcoin.js` builds on. Provides the chain-specific primitives (post-quantum signing, encrypted-wallet JSON envelope, scrypt KDF). |

The iOS wallet only ever consumes the **curated `quantumcoin-bundle.js`** —
**no Swift code reaches into either upstream package directly**.
Adding a new SDK symbol means re-exporting it from the bundle, not
pulling an upstream package into iOS, so the SHA-256 pin and the
Android-iOS parity contract stay meaningful.

The bundle is byte-identical (MD5 `efaf322b…bbc6d9`) to the one
shipped by the Android wallet's `webview-sdk-bundle`, which is the
canonical re-export point.

### Native frameworks used

| Framework | Used for |
| --- | --- |
| `UIKit` | Every screen, every dialog |
| `WebKit` | The single in-process `WKWebView` that hosts `bridge.html` (`JsBridge/JsEngine.swift`) |
| `CryptoKit` | AES-256-GCM seal/open, SHA-256 (`Crypto/Aead.swift`, `JsBridge/BundleIntegrity.swift`) |
| `Security` | Keychain (brute-force lockout counter, legacy wrap-key cleanup) |
| `Foundation` | `URLSession`, file I/O, JSON, `URLBookmarkData` for cloud folders |
| `UniformTypeIdentifiers` | Custom `org.quantumcoin.wallet` UTI for `.wallet` backup files |

### Build tooling

- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** ≥ 2.38.0
  generates `QuantumCoinWallet.xcodeproj` from
  [`project.yml`](project.yml). The `.xcodeproj` is intentionally
  **not** committed.
- **`shasum -a 256`** (BSD, ships with macOS) used by
  `scripts/embed_bundle_hash.sh` at build time.

---

## Architecture overview

```
┌───────────────────────────────────────────────────────────────────┐
│                          UIKit screens                            │
│   HomeWallet / HomeMain / Send / Receive / Wallets / Settings /   │
│   Transactions / RevealWallet / BlockchainNetwork / BackupOptions │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────▼───────────────────────────────────────┐
│                     Strongbox accessor (L5)                       │
│        Strongbox/Strongbox.swift — single in-mem snapshot         │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────▼───────────────────────────────────────┐
│                  Unlock coordinator (L4)                          │
│   scrypt → AEAD open → install snapshot;  password is never       │
│   cached — re-derived per write                                   │
└──────────────┬────────────────────────────────────┬───────────────┘
               │                                    │
┌──────────────▼─────────────────┐  ┌───────────────▼───────────────┐
│   Crypto primitives (L3)       │  │   Schema codec (L2)           │
│   Aead, Mac, PasswordKdf,      │  │   StrongboxFileCodec,         │
│   SecureRandom                 │  │   StrongboxPadding            │
└──────────────┬─────────────────┘  └───────────────┬───────────────┘
               │                                    │
               │            ┌───────────────────────▼───────────────┐
               │            │   Storage primitive (L1)              │
               │            │   AtomicSlotWriter (two-slot,         │
               │            │   F_FULLFSYNC, verify-before-promote) │
               │            └───────────────────────────────────────┘
               │
┌──────────────▼─────────────────┐  ┌───────────────────────────────┐
│      JsBridge (Swift)          │◄─┤    bridge.html (WKWebView)    │
│   JsEngine, JsBridge,          │  │    quantumcoin-bundle.js      │
│   BundleIntegrity              │  │    (QuantumCoinSDK +          │
└────────────────────────────────┘  │     SeedWordsSDK globals)     │
                                    └───────────────────────────────┘
```

The strict layering is enforced by the storage / crypto / bridge
separation in code review and by invariant tests in
`QuantumCoinWalletTests/StrongboxLayerTests.swift`. The only
structurally-permitted writers of wallet-meaningful state are
the `Strongbox.shared` accessor and the `UnlockCoordinatorV2`
re-encrypt path; a stray `PrefConnect` write of a wallet field
is caught by a grep-based invariant test.

---

## Repository layout

```
.
├── LICENSE                            MIT
├── project.yml                        XcodeGen project spec
├── scripts/
│   └── embed_bundle_hash.sh           Build-time SHA-256 pin
└── QuantumCoinWallet/
    ├── AppDelegate.swift              Boot + tamper gate
    ├── Info.plist                     UIFileSharingEnabled = false, etc.
    ├── QuantumCoinWallet.entitlements
    ├── Assets.xcassets                App icon + brand colors
    ├── LaunchScreen.storyboard
    │
    ├── Backup/                        File / cloud backup + restore
    ├── Components/                    Reusable views (PillButton, QRScanner…)
    ├── Crypto/                        Aead, Mac, PasswordKdf, SecureRandom
    ├── Data/                          ApiClient, BlockchainNetwork, ApiModels
    ├── Diagnostics/                   Logger
    ├── Dialogs/                       UIKit dialogs (Unlock, Review, Wait…)
    ├── Generated/                     BundleHash_Generated.swift (auto)
    ├── JsBridge/                      JsEngine, JsBridge, BundleIntegrity
    ├── KeyMaterial/                   Key envelopes, key-type helpers
    ├── Localization/                  Localization.shared accessor
    ├── Models/                        RecognizedTokens, StablecoinImpersonatorFilter
    ├── Navigation/                    UINavigationController helpers
    ├── Networking/                    NetworkConfig (actor), TlsPinning, UrlBuilder
    ├── Resources/
    │   ├── bridge.html                JS bridge (the only HTML the WKWebView loads)
    │   ├── quantumcoin-bundle.js      The single JS SDK bundle (SHA-256 pinned)
    │   ├── quantumcoin-bundle.js.LICENSE.txt
    │   ├── blockchain_networks.json   Bundled MAINNET network seed
    │   └── en_us.json                 230+ localization keys
    ├── Schema/                        StrongboxFileCodec (v2), StrongboxPadding
    ├── Screens/                       11 top-level screens
    ├── Security/                      TamperGate, ScreenCaptureGuard, UnlockAttemptLimiter
    ├── Session/                       Idle relock + foreground/background tracking
    ├── Storage/                       AtomicSlotWriter (L1), PrefConnect (UI prefs)
    ├── Strongbox/                     Strongbox accessor (L5), payload, redundancy
    ├── Theme/                         Color tokens, typography
    ├── UX/                            SnapshotRedactor, Pasteboard
    └── Utilities/                     Constants, helpers
└── QuantumCoinWalletTests/            6 test suites, ~70 tests
```

Counts (at the time of writing): 78 Swift source files, 6 test
files, 833-line `bridge.html`, 12 MiB `quantumcoin-bundle.js`, 230+
localization keys.

---

## Build and run

### Prerequisites

- macOS with Xcode 17 or newer (iOS 17+ SDK).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`.
- Apple Developer account if you intend to run on a physical device.

### Generate, build, run

```bash
git clone https://github.com/quantumcoinproject/quantum-coin-wallet-ios.git
cd quantum-coin-wallet-ios
xcodegen generate
open QuantumCoinWallet.xcodeproj
```

Pick the **QuantumCoinWallet** scheme and a destination
(simulator or physical device). The first build runs the
`embed_bundle_hash.sh` pre-build script, which writes
`QuantumCoinWallet/Generated/BundleHash_Generated.swift` so the
SHA-256 of `quantumcoin-bundle.js` is embedded in the Swift
binary. **The generated file is gitignored** — every build
regenerates it, so an out-of-date hash is impossible by
construction.

### Command-line build

```bash
xcodegen generate
xcodebuild \
  -project QuantumCoinWallet.xcodeproj \
  -scheme QuantumCoinWallet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

### Updating the JS bundle

`quantumcoin-bundle.js` is built upstream by the Android wallet's
[`webview-sdk-bundle/`](https://github.com/quantumcoinproject/quantum-coin-wallet-android/tree/main/webview-sdk-bundle).
Drop the new bundle into
`QuantumCoinWallet/Resources/quantumcoin-bundle.js`; the next
build regenerates `BundleHash_Generated.swift` automatically.

---

## Testing

```bash
xcodebuild \
  -project QuantumCoinWallet.xcodeproj \
  -scheme QuantumCoinWallet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

The test target lives in
[`QuantumCoinWalletTests/`](QuantumCoinWalletTests). It includes:

| Suite | Coverage |
| --- | --- |
| `JsBridgeContractTests` | Live `WKWebView` boot + `bridge.createRandom` round-trip; pins the JSON envelope shape between Swift and the JS bundle |
| `StrongboxLayerTests` | Layer-isolation invariants (no `PrefConnect` writes of wallet fields, codec round-trip equality) |
| `SecurityFixesTests` | Password-verification, lockout-schedule, tamper-gate classifier |
| `TokenFilteringAndLockoutTests` | `RecognizedTokens.isRecognized`, `StablecoinImpersonatorFilter.filter`, `UnlockAttemptLimiter` 5-minute cap, contract-address row in the review dialog, localization-key smoke check |
| `LocalizationTests` | `en_us.json` key presence and accessor wiring |
| `ApiDecodingTests` | Scan-API JSON shapes against captured fixtures |

---

## Threat model & non-goals

### In scope

- **Lost or stolen device.** Sandbox isolation, complete file
  protection, brute-force lockout, snapshot redaction,
  pasteboard expiry, idle relock.
- **Hostile RPC.** Local-first transaction signing inside the
  bundled SDK; the user can verify the locally-derived hash on
  any block explorer.
- **Token impersonation.** Recognized-contract allow-list +
  stablecoin-name hard-suppressor.
- **JS bundle tamper / re-sign.** Build-time SHA-256 pin embedded
  in the code-signed Swift binary; runtime re-hash; refuse-to-init
  on mismatch.
- **Jailbreak / debugger / Mach-O instrumentation.** Multi-signal
  tamper gate at the signing chokepoint.
- **Power loss / sudden app kill mid-write.** Two-slot rotation,
  `F_FULLFSYNC`, verify-before-promote.

### Explicit non-goals

- **TLS pinning on RPC.** The wallet is non-custodial and the user
  picks the RPC. Pinning would impose centralization. Baseline
  TLS chain validation still applies. See
  `Networking/TlsPinning.swift` for the full coverage map.
- **Defending an unlocked, jailbroken, attacker-owned device with
  a Frida-class hook injected before the wallet binary loads.**
  The tamper gate raises cost; it does not claim to be impassable.
- **Custodial recovery.** There is no remote escrow of seed phrases
  or unlock passwords. Lost seed = lost wallet. The backup flow
  (file or iCloud Drive) is the only recovery path.
- **Investment, custody, or financial advice of any kind.**

---

## License

[MIT](LICENSE) — see the file for details.

The bundled `quantumcoin-bundle.js` and its embedded
third-party libraries are MIT-licensed (see
[`QuantumCoinWallet/Resources/quantumcoin-bundle.js.LICENSE.txt`](QuantumCoinWallet/Resources/quantumcoin-bundle.js.LICENSE.txt)).

---

## Further reading

- **Project home:** <https://quantumcoin.org>
- **FAQ:** <https://quantumcoin.org/faq.html>
- **Quantum-resistance whitepaper:**
  <https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Quantum-Resistance-Whitepaper.html>
- **Consensus whitepaper:**
  <https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Consensus-Whitepaper.html>
- **Quantum Coin Go node (open source):**
  <https://github.com/quantumcoinproject/quantum-coin-go>
- **Android wallet (parity reference):**
  <https://github.com/quantumcoinproject/quantum-coin-wallet-android>
- **`quantumcoin.js` (ethers.js-compatible wrapper SDK):**
  <https://github.com/quantumcoinproject/quantumcoin.js>
- **`quantum-coin-js-sdk` (lower-level upstream SDK, npm package):**
  <https://github.com/quantumcoinproject/quantum-coin-js-sdk>
- **Block explorer:** <https://quantumscan.com>
- **JSON-RPC API docs:** <https://apidoc.quantumcoin.org>
- **Community:** <https://discord.gg/bbbMPyzJTM>
