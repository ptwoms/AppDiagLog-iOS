# AppDiagLog-iOS

On-device diagnostic recording SDK for **iOS** (Swift)
plus a **Kotlin + Spring Boot** backend that ingests and decrypts exported
session archives.

It's an encrypted local black box: records app events, keeps the last N
sessions on device, and never phones home automatically. Export is always
driven by the host app — the SDK hands back a ZIP and stays out of your
transport path.

---

## The 30-second mental model

```
  Mobile device                                       Your backend
  ─────────────                                       ────────────

  AppDiagLog.info(…)
         │
         ▼
  Rate limiter  →  Event buffer  →  Flush coordinator
                                         │
                                         ▼
                         AES-256-GCM encrypt (per-session DEK)
                                         │
                                         ▼
                           <app-private>/sessions/session_*.enc
                                         │
                                         │ app calls AppDiagLog.export()
                                         ▼
                         ZIP (manifest.json + sessions/*.enc)
                                         │
                            app POSTs to backend over its own transport
                                         │
                                         ▼
                       POST /api/v1/diagnostics/upload ──────────▶   ingest
                                                                         │
                                                                         ▼
                                                           ML-KEM decapsulate
                                                             AES-KWP unwrap DEK
                                                           AES-GCM decrypt payload
                                                                         │
                                                                         ▼
                                                         Postgres (sessions + events)
                                                                         │
                                                                         ▼
                                                         GET /sessions  /events
```

Every session is encrypted with a unique 256-bit **DEK**. The DEK is wrapped
with an **ML-KEM-768** public key, so only the server holding the private
half can decrypt. The device never sees the private key.

---

## Repository layout

| Directory               | What's there                                                            |
| ----------------------- | ----------------------------------------------------------------------- |
| `ios/`                  | Swift Package. full auto-tracking, unit tests, actor-based concurrency. |
| `sample/ios-app/`       | Minimal SwiftUI app driving the SDK end-to-end.                       |
---

## Quick start

### 1. Generate a keypair

Use Python or go scripts under scripts folder

### 2. Integrate the iOS SDK

Add the local package (or pin a tag once you publish one):

```swift
// App init
AppDiagLog.initialize(
    config: AppDiagLogConfig(
        maxSessions: 5,
        maxEventsPerSession: 1_000,
        maxDiskUsageMB: 10,
        // Cryptographic agility: swap to .rsaOaep3072(...) / .ecdhP256(...) /
        // .mlKem512(...) without code changes elsewhere.
        keyWrap: .mlKem768(keyId: "key-2026-04", publicKey: publicKeyData),
        symmetric: .aes256gcm
    )
)

// Anywhere, any thread.
AppDiagLog.info("cart_abandoned", ["items": "3"])
AppDiagLog.error("checkout_failure", ["code": "402"])

// Modern async flavour:
let result = await AppDiagLog.export()
```

Annotate SwiftUI views with `.trackScreen("Cart")` and
`.trackDeepLinks()` to get screen-view / deep-link tracking without
swizzling.

---

## Transport paths

The SDK hands back a ZIP and stays out of your transport — the host app picks
how to deliver it. Two flows are supported end to end:


### Email + offline decrypt
Sample helpers: `sample/ios-app/.../EmailExportHelper.swift`
(uses `UIActivityViewController`). The recipient feeds the attached ZIP to one
of the standalone CLIs:

- **Python** — `scripts/python/decrypt.py` (`pip install -r scripts/requirements.txt`)
- **Go** — `scripts/go/cmd/diaglog-decrypt` (single static binary)

Both support `--format jsonl|csv` and dispatch on the algorithm strings in the
envelope, so a ZIP encrypted with `RSA-OAEP-3072` + `ChaCha20-Poly1305` is
just as decryptable as the default `ML-KEM-768` + `AES-256-GCM`.

---

## Key design decisions

| Decision                                                  | Rationale                                                                                                                                                                                |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **File-per-session** (not one DB)                         | Eviction = `rm`. Corruption is isolated. Export = copy files into a ZIP. No SQLite/SQLCipher dependency on the device.                                                                   |
| **Re-encrypt whole session on every flush**               | Simple, robust, and within budget for bounded sessions (max 1000 events).                                                                                                                |
| **Hybrid encryption (AES-256-GCM + ML-KEM-768 KEM-wrap)** | Classical AES for bulk payload, PQC KEM for DEK wrapping → post-quantum-safe without burning CPU on every event.                                                                         |
| **GCM AAD = `session_id \| key_id`**                      | Tampering with either header field invalidates the whole envelope on decryption — you can't swap a ciphertext into a different session's envelope.                                      |
| **`<100 KB` steady-state memory budget**                  | 50-event buffer + reserved capacity + shared encoders. The SDK is a utility; it must not compete with the host app.                                                                      |
| **No GCD on iOS (structured concurrency only)**           | One exception documented in code: `NWPathMonitor` and the crash-handler bridge use a queue/semaphore because the C API requires it.                                                      |
| **Swift actors for everything mutable**                   | `EventBuffer`, `SessionManager`, `LogPipeline`, `FlushCoordinator`, `ExportManager` — all actor-isolated. The public API is `nonisolated` and returns immediately.                        |
| **One-bad-session-doesn't-fail-whole-upload**             | Each session is decrypted in its own transaction. A missing key or bad AEAD tag is recorded in `failures[]` and returned to the client so support can chase the problem.                 |

---

## Testing posture

| Layer             | Tests                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------ |
| iOS SDK           | XCTest in `ios/Tests/AppDiagLogTests/`: crypto round-trip, redaction, eviction, buffer/rate-limiter, envelope.     |
| Backend           | WIP   |
| Sample apps       | Manual QA drivers — exercise the SDK end-to-end against a running backend.                                         |

---

## Security posture

- **No plaintext on disk.** Events hit encryption during the flush cold path,
  never on individual log calls.
- **No plaintext in the export.** Exports contain the exact same
  `session_*.enc` files the SDK stores; the device never decrypts.
- **DEKs are short-lived.** Generated at session start, wiped at session seal.
- **Private keys live in the vault.** The `KeyVaultService` interface defers
  to HSM / KMS in production. The bundled `InMemoryKeyVault` is dev-only.
- **Constant-time token compare** on the upload endpoint.
- **PII redaction is mandatory.** Query strings stripped, UUID/numeric path
  segments masked to `{id}`, sensitive headers blocklisted, password/secure
  text-fields opted out of tap tracking.

---

## Non-goals

- The SDK does **not** transport logs itself. The host app picks a channel
  (support ticket, S3 signed upload, etc.).
- ML-KEM-768 on iOS requires iOS 26+ (native CryptoKit) **or** a liboqs
  XCFramework injected via `PQCProvider`. The bundled `SystemPQCProvider`
  fails fast on older runtimes — fail secure rather than fall back to a
  weaker cipher.
- PQC key rotation is supported via the `key_id` field in every envelope;
  operational procedures are an ops concern, not an SDK concern.