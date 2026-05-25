# AppDiagLog Backend

Spring Boot service that ingests encrypted export ZIPs from the mobile SDKs,
decrypts them using ML-KEM-768 private keys from the vault, and exposes the
decrypted sessions + events through a small REST API.

## Prerequisites

- JDK 17–21 (Spring Boot 3.3 support matrix).
- Gradle 8.7+ (or invoke via `./gradlew` once the wrapper is generated — see
  below).

## One-time bootstrap

This project ships without the Gradle wrapper binary. Generate it once:

```bash
cd backend
gradle wrapper --gradle-version 9.5.1
```

That creates `gradlew`, `gradlew.bat`, and `gradle/wrapper/`. Commit those to
version control afterwards.

## Run locally

```bash
# Dev profile uses in-memory H2 and expects inline-loaded vault keys.
./gradlew bootRun --args='--spring.profiles.active=dev'
```

Generate an ML-KEM-768 keypair for dev:

```kotlin
// One-off script — anywhere with BouncyCastle on the classpath.
val (pub, priv) = com.appdiaglog.server.vault.InMemoryKeyVault.generateKeyPair()
println("PUBLIC_KEY_BASE64=" + java.util.Base64.getEncoder().encodeToString(pub))
println("PRIVATE_KEY_BASE64=" + java.util.Base64.getEncoder().encodeToString(priv))
```

Wire the private key into the vault via env var before `bootRun`:

```bash
export DIAGNOSTICLOG_VAULT_KEYS="key-2026-04=<base64 private key>"
export DIAGNOSTICLOG_INGEST_TOKEN="<random token>"
```

The public half goes into the SDK config so the client can wrap the DEK.

## Endpoints

| Method | Path                                                    | Auth                    |
| ------ | ------------------------------------------------------- | ----------------------- |
| POST   | `/api/v1/diagnostics/upload`                            | `Authorization: Bearer` |
| GET    | `/api/v1/diagnostics/sessions?…`                        | none (operator-gated)   |
| GET    | `/api/v1/diagnostics/sessions/{id}`                     | none                    |
| GET    | `/api/v1/diagnostics/sessions/{id}/events?…`            | none                    |
| GET    | `/api/v1/diagnostics/sessions/{id}/events.csv`            | none                    |
| GET    | `/api/v1/diagnostics/sessions/events.xls`            | none                    |
| GET    | `/actuator/health`                                      | none                    |

See the OpenAPI-style comments on the controllers for the full param surface.

## Security posture

- **Private keys live in [`KeyVaultService`]**. The bundled `InMemoryKeyVault`
  is dev-grade. Production deployments must back the interface with HSM / KMS.
- **Bearer token is minimal**. It protects the upload endpoint from drive-by
  abuse, nothing more. Wrap the service with mTLS or a real auth server in
  production.
- **DEK wipe**. Every decrypted DEK is zeroed after use; the private-key copy
  returned by the vault is wiped after decryption completes.
- **AAD binding**. AES-GCM authenticates `session_id|key_id` — tampering with
  either envelope field surfaces as a `javax.crypto.AEADBadTagException` and
  the session is recorded as a failure, not persisted.
