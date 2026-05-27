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
| `backend/`              | Spring Boot service. Ingest + decrypt + query API + round-trip test.  |
| `sample/ios-app/`       | Minimal SwiftUI app driving the SDK end-to-end.                       |

---

## Quick start

### 1. Generate a keypair

Using the backend's bundled helper (any JVM with BouncyCastle on the
classpath):

```kotlin
val (pub, priv) = com.appdiaglog.server.vault.InMemoryKeyVault.generateKeyPair()
println("public: "  + java.util.Base64.getEncoder().encodeToString(pub))
println("private: " + java.util.Base64.getEncoder().encodeToString(priv))
```

Keep the public half for the app; keep the private half for the backend
vault. **Never** ship the private key with an app.

(OR)

Use Python or go scripts under scripts folder

### 2. Run the backend

```bash
cd backend
gradle wrapper --gradle-version 9.5   # one-off, see backend/README.md
export DIAGNOSTICLOG_INGEST_TOKEN="<random token>"
export DIAGNOSTICLOG_VAULT_KEYS="key-2026-04=<PRIVATE_KEY_BASE64>"
./gradlew bootRun --args='--spring.profiles.active=dev'
```

The service listens on `:8080`, uses in-memory H2 in dev, and exposes
`/actuator/health` plus the API surface under `/api/v1/diagnostics/*`.

### 3. Integrate the iOS SDK

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

Annotate SwiftUI views with `.trackIdentifier("Cart")` and `.trackDeepLinks()` to
get screen-view / deep-link tracking without relying on UIKit controller
swizzling. Use `.trackIdentifier(_:)` only on meaningful screens. Set
`AutoTrackConfig(screenViews: nil)` to disable all screen-view tracking,
including explicit SwiftUI `.trackIdentifier(_:)` calls.

UIKit apps can keep automatic screen tracking and narrow the swizzle with
`AutomaticScreenTrackConfig`:

```swift
AutoTrackConfig(
    screenViews: .automatic(
        AutomaticScreenTrackConfig() // using all defaults
    )
)
```

For stricter production logging, track only view accessibility identifiers:

```swift
AutoTrackConfig(
    screenViews: .accessibilityIdentifier(
        AccessibilityIdentifierScreenTrackConfig(requiredPrefix: "screen.")
    )
)
```

```swift
view.accessibilityIdentifier = "screen.checkout"
```

For SwiftUI, pass the accepted identifier to `.trackIdentifier(_:)`; SwiftUI's own
`.accessibilityIdentifier(...)` remains useful for UI tests, but the SDK cannot
read it back from the view modifier chain:

```swift
CheckoutView()
    .accessibilityIdentifier("screen.checkout")
    .trackIdentifier("screen.checkout")
```

### 4. Upload & query

```bash
curl -X POST http://localhost:8080/api/v1/diagnostics/upload \
  -H "Authorization: Bearer $DIAGNOSTICLOG_INGEST_TOKEN" \
  -F "file=@/path/to/appdiaglog_export_*.zip"

curl "http://localhost:8080/api/v1/diagnostics/sessions?size=20"
curl "http://localhost:8080/api/v1/diagnostics/sessions/<id>/events?level=error"

# Stream a single session as CSV (works with all storage adapters):
curl "http://localhost:8080/api/v1/diagnostics/sessions/<id>/events.csv" > events.csv

# Download xls
curl -o events.xls "http://localhost:8080/api/v1/diagnostics/sessions/events.xls"

```

---

## Transport paths

The SDK hands back a ZIP and stays out of your transport — the host app picks
how to deliver it. Two flows are supported end to end:

### HTTP upload
Sample code: `sample/ios-app/.../AppDiagLogAPIClient.swift`. POST the ZIP as `multipart/form-data`
to `POST /api/v1/diagnostics/upload`. Backend decrypts in-process.

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

## Backend storage adapters

Pick at boot via `appdiaglog.storage.adapter`:

| Value    | Where data lives                          | Use case |
|----------|-------------------------------------------|----------|
| `jpa`    | Postgres / H2 via Spring Data (default)   | Production / shared dashboards |
| `sqlite` | Local SQLite file, **per-row AES-256-GCM**| Single-host deployments, air-gapped |
| `csv`    | Append-only `sessions.csv` + `events.csv` | Offline analysis, spreadsheet hand-off |

```yaml
appdiaglog:
  storage:
    adapter: sqlite
    sqlite:
      file: /var/appdiaglog/sessions.db
      master-key: <base64 32-byte AES key>   # encrypts sensitive columns
```

The ingest pipeline and query API are unchanged regardless of adapter — the
choice only affects where rows land.

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
| **Idempotent re-upload** (backend)                        | Sessions are keyed by the device-generated ID. Re-uploading the same export overwrites cleanly — a retry after a flaky network doesn't create duplicates.                                |
| **One-bad-session-doesn't-fail-whole-upload**             | Each session is decrypted in its own transaction. A missing key or bad AEAD tag is recorded in `failures[]` and returned to the client so support can chase the problem.                 |

---

## Testing posture

| Layer             | Tests                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------ |
| iOS SDK           | XCTest in `ios/Tests/AppDiagLogTests/`: crypto round-trip, redaction, eviction, buffer/rate-limiter, envelope.     |
| Backend           | Spring integration test `DecryptionRoundtripTest` that builds an envelope with BC, ingests it, and asserts rows.   |
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
- No backend dashboard ships with this repo. The REST API is the contract;
  build whatever UI your org prefers on top.
- ML-KEM-768 on iOS requires iOS 26+ (native CryptoKit) **or** a liboqs
  XCFramework injected via `PQCProvider`. The bundled `SystemPQCProvider`
  fails fast on older runtimes — fail secure rather than fall back to a
  weaker cipher.
- PQC key rotation is supported via the `key_id` field in every envelope;
  operational procedures are an ops concern, not an SDK concern.
