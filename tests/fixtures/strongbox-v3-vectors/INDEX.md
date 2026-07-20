# Strongbox v=3 Seeded Vectors

This directory intentionally contains no large JSON, hex, base64,
or 4 MiB binary fixtures.

The portability tests generate deterministic inputs at runtime
from one hardcoded 32-byte seed:

`368f07e78cfc016d5c1c84ed617b37d15490ce98578643309c5c91b4de736921`

The expansion rule is:

`SHAKE256(seed || UTF8(label), outputLength)`

iOS implements this in `QuantumSwapWalletTests/StrongboxLayerTests.swift`
as `TestShake256`; Android implements it in
`app/src/test/java/com/quantumcoin/app/strongbox/StrongboxPortabilityVectorTest.java`
through BouncyCastle `SHAKEDigest(256)`.

The test code hardcodes only the seed and small expected outputs
(digests, HMAC tags, checksum strings, canonical-byte hashes). It
does not check in generated slot files or large payload JSON.

## What The Seeded Tests Pin

- SHAKE-256 seed expansion itself (`label = "sanity"`).
- Published RFC vectors for HMAC-SHA-256 and HKDF-SHA-256.
- Seed-derived SHA-256, HMAC-SHA-256, and HKDF null-salt vectors.
- Fast scrypt vector on Android (`N=1024`, `r=8`, `p=1`).
- AES-256-GCM with injected deterministic nonce.
- `WalletEntryCodec` bytes for generated wallets.
- Canonical `StrongboxPayload` bytes, via SHA-256 over the canonical bytes.
- The v=3 keyed inner checksum, including `salt = null/empty` HKDF behavior.
- ISO/IEC 7816-4 padding to the 4 MiB bucket.

The full strongbox slot is generated from these same ingredients
inside the tests when needed. That preserves the portability
contract without making the repository carry large golden blobs.
