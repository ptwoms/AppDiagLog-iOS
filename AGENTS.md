# AppDiagLog-iOS SDK — AGENTS.md

## Project Overview

**AppDiagLog-iOS** = on-device diagnostic recording SDK for iOS. Encrypted black box. Continuously records app events into bounded local store (last N sessions). No auto network calls. Exports only when app explicitly triggers.

### Core Philosophy

- **Local-first**: No auto network calls. Logs stay on device until app explicitly exports.
- **Privacy by design**: All session data encrypted at rest via AES-256-GCM. Exported logs never decrypted on device.
- **Hybrid encryption envelope**: Each session DEK wrapped with PQC public key (ML-KEM-768). Only backend with private key can decrypt.
- **Zero-effort instrumentation**: Auto-tracks screen views, taps, API calls, lifecycle events — minimal integration code.
- **Bounded storage**: Rolling session ring buffer, configurable max sessions + max events/session.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      App Layer                           │
│  AppDiagLog.init() / .info() / .error() / .export()   │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                    Public API Module                      │
│  AppDiagLog (singleton entry point)                   │
│  AppDiagLogConfig / AutoTrackConfig                      │
│  ExportResult                                            │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                  Auto-Tracking Module                     │
│  ScreenTracker    │ TapTracker      │ ApiTracker         │
│  LifecycleTracker │ CrashTracker    │ ConnectivityTracker│
│  MemoryTracker    │ BatteryTracker  │ PermissionTracker  │
│  DeepLinkTracker  │ NotificationTracker                  │
│  WebViewTracker   │ DbQueryTracker  │ BackgroundTracker  │
│  PreferenceTracker│ DeviceSnapshot                       │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                   Core Engine Module                      │
│  SessionManager   → manages session lifecycle & ring buf │
│  EventBuffer      → in-memory buffer, flush to storage   │
│  EventEnvelope    → timestamp, sequence, screen context   │
│  RedactionEngine  → PII stripping before storage         │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                  Encryption Module                        │
│  AES-256-GCM encryption (per-session DEK)                │
│  ML-KEM-768 key encapsulation (wraps DEK)                │
│  Key generation (SecureRandom / SecRandomCopyBytes)       │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                   Storage Module                         │
│  One encrypted file per session                          │
│  Session index (SharedPreferences / UserDefaults)        │
│  Eviction policy (max sessions + max disk usage)         │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                   Export Module                           │
│  Bundle encrypted files as-is (NO decryption)            │
│  ZIP archive with session envelopes                      │
│  Return file path to app — app owns transport            │
└──────────────────────────────────────────────────────────┘
```

---

## Session Retention Strategy

SDK keeps last N sessions (default 5, configurable) via **file-per-session** + **index-based ring buffer**.

### Storage Layout

```
<app-private-dir>/appdiaglog/
├── session_index.json          ← lightweight index (ordered list of session IDs)
├── sessions/
│   ├── session_a1b2c3.enc      ← oldest session (position 0)
│   ├── session_d4e5f6.enc
│   ├── session_g7h8i9.enc
│   ├── session_j0k1l2.enc
│   └── session_m3n4o5.enc      ← current/newest session (position 4)
```

### Session Index

Minimal JSON tracking session ordering. **Only mutable metadata** — session files are append-only (re-encrypted on flush), never modified after sealing.

```json
{
  "version": 1,
  "max_sessions": 5,
  "sessions": [
    { "id": "a1b2c3", "created_at": "2026-04-18T08:00:00Z", "sealed": true,  "file_size_bytes": 42000 },
    { "id": "d4e5f6", "created_at": "2026-04-18T09:15:00Z", "sealed": true,  "file_size_bytes": 38000 },
    { "id": "g7h8i9", "created_at": "2026-04-18T10:30:00Z", "sealed": true,  "file_size_bytes": 51000 },
    { "id": "j0k1l2", "created_at": "2026-04-18T12:00:00Z", "sealed": true,  "file_size_bytes": 29000 },
    { "id": "m3n4o5", "created_at": "2026-04-18T14:00:00Z", "sealed": false, "file_size_bytes": 15000 }
  ]
}
```

### Session Lifecycle

```
App Launch / Foreground
        │
        ▼
┌─ Read session_index.json ─┐
│                            │
│  Is there an unsealed      │
│  session within timeout?   │──── YES ──→ Resume existing session
│                            │              (append to same file + DEK)
└────────────┬───────────────┘
             │ NO
             ▼
┌─ Create new session ──────────────────────────────────┐
│  1. Generate session ID (UUID)                         │
│  2. Generate new DEK (AES-256) + nonce                 │
│  3. Wrap DEK with PQC public key                       │
│  4. Write empty envelope file: session_{id}.enc        │
│  5. Append to session_index.sessions[]                 │
│  6. If len(sessions) > maxSessions → EVICT oldest      │
│  7. Persist session_index.json                         │
└────────────────────────────────────────────────────────┘

App Background / Session Timeout
        │
        ▼
┌─ Seal current session ────────────────────────────────┐
│  1. Final flush: serialize + encrypt remaining buffer  │
│  2. Mark session as sealed in index                    │
│  3. Persist session_index.json                         │
└────────────────────────────────────────────────────────┘
```

### Eviction Policy

Triggered at **session creation time**, not continuously. Two guards:

1. **Session count guard** (primary): When `sessions.count > maxSessions`, delete oldest sealed session file + remove from index. Repeat until within limit.
2. **Disk usage guard** (secondary): Sum `file_size_bytes` across all sessions. If total exceeds `maxDiskUsageMb`, delete oldest sealed sessions until under budget. Handles unusually large sessions.

**Never evict current unsealed session.** If disk budget too tight for even one session, log warning + cap events via `maxEventsPerSession`.

```swift
// iOS
actor SessionManager {
    private func evictIfNeeded() {
        // Guard 1: session count
        while index.sessions.count > config.maxSessions,
              let oldest = index.sessions.first(where: \.sealed) {
            try? FileManager.default.removeItem(at: sessionFileURL(oldest.id))
            index.sessions.removeAll { $0.id == oldest.id }
        }

        // Guard 2: disk usage
        while index.totalDiskBytes > config.maxDiskUsageMB * 1_000_000,
              let oldest = index.sessions.first(where: \.sealed) {
            try? FileManager.default.removeItem(at: sessionFileURL(oldest.id))
            index.sessions.removeAll { $0.id == oldest.id }
        }

        persistIndex()
    }
}
```

### Crash Recovery

If app crashes mid-session, file contains all data up to last flush. On next launch:

1. Read `session_index.json`
2. Find unsealed session — survived crash
3. Seal retroactively (`sealed: true`, set `end_at` to last flush timestamp)
4. Start fresh session

Worst-case data loss = one buffer worth of events (50 events / 5 seconds). Sealed-on-recovery session still exportable + decryptable.

### Why File-Per-Session

| Alternative | Problem |
|---|---|
| Single SQLite database | Corruption cascades across all sessions. Encryption requires SQLCipher (~2MB binary). Eviction = DELETE + VACUUM (slow, fragmentation). |
| Single encrypted file | Must decrypt + re-encrypt everything on every flush and eviction. Grows unbounded during long sessions. |
| **File-per-session** ✓ | Eviction = delete file (instant, no fragmentation). Corruption isolated. Export = copy files into ZIP. No DB dependency. |

---

### Per-Session Encryption Flow

1. Session start → generate random 256-bit AES key (DEK) + 12-byte nonce
2. During session → buffer events in memory, flush periodically by serializing + encrypting with DEK
3. Session end → final flush, seal session file
4. DEK encrypted (encapsulated) with PQC public key (ML-KEM-768)
5. Stored per session: `{ ciphertext, wrapped_dek, nonce, metadata }`

### Export Flow (No Decryption on Device)

1. Collect all encrypted session files as-is
2. Bundle into ZIP archive
3. Return ZIP file path to app
4. App sends ZIP to backend via own transport (API upload, email, support ticket)

### Backend Decryption Flow

1. Unzip bundle
2. Per session: read `key_id` → select PQC private key → decapsulate DEK
3. Decrypt payload with AES-256-GCM using recovered DEK + stored nonce
4. Parse JSON log entries

### Session File Envelope Format

```json
{
  "version": 1,
  "session_id": "uuid",
  "created_at": "ISO-8601",
  "device_metadata": {
    "os": "iOS 18",
    "app_version": "x.y.z",
    "model": "iPhone 16",
    "locale": "en-SG",
    "timezone": "Asia/Singapore"
  },
  "encryption": {
    "algorithm": "AES-256-GCM",
    "nonce": "<base64>",
    "kek_algorithm": "ML-KEM-768",
    "key_id": "key-2026-04",
    "wrapped_dek": "<base64>"
  },
  "payload": "<base64 encrypted session log>"
}
```

`device_metadata` plaintext intentionally — non-sensitive, helps triage before decryption.

---

## Event Schema

```json
{
  "seq": 42,
  "ts": "2026-04-18T10:30:00.123Z",
  "session_id": "uuid",
  "screen": "HomeScreen",
  "event": "api_call",
  "level": "error",
  "props": {
    "method": "POST",
    "url": "https://api.example.com/users/{id}",
    "status": "500",
    "duration_ms": "1230"
  }
}
```

Fields:
- `seq` — monotonically increasing per session
- `ts` — ISO 8601 UTC timestamp
- `session_id` — links event to session
- `screen` — current screen at event time (maintained by ScreenTracker)
- `event` — event name (e.g., `screen_view`, `tap`, `api_call`, `crash`, `connectivity_change`)
- `level` — `debug | info | warning | error`
- `props` — flexible key-value map, always `Map<String, String>`

---

## Auto-Tracking Tiers

### Tier 1 — Always On (near-zero overhead)

| Tracker |  iOS |
|---------|------|
| App Lifecycle | `UIApplication` notifications |
| Screen Views | Swizzle `viewDidAppear` / SwiftUI modifier |
| Taps | Swizzle `sendEvent` |
| API Calls | `URLProtocol` subclass |
| Crashes | `NSSetUncaughtExceptionHandler` |
| Connectivity `NWPathMonitor` |
| Deep Links | Universal link logging |
| Device Snapshot | Captured once at session start |

### Tier 2 — On by Default

| Tracker | iOS |
|---------| -----|
| Memory Pressure | `didReceiveMemoryWarning` + `task_info` |
| Battery/Thermal | `ProcessInfo.thermalState`, `UIDevice.batteryState` |
| Permission Changes | Observe authorization status |
| Push Notifications | `UNUserNotificationCenterDelegate` |

### Tier 3 — Opt-In

| Tracker | iOS |
|---------|-----|
| Slow DB Queries | Core Data instrumentation |
| WebView Events | `WKNavigationDelegate` wrapper |
| Background Tasks `BGTask` begin/expiration |
| Preference Changes `UserDefaults.didChangeNotification` |

---

## PII Redaction Rules

All auto-trackers MUST pass through `RedactionEngine` before storage:

- **URLs**: Strip query params, replace path segments matching UUID/ID patterns with `{id}`
- **Taps**: Never log text from password/secure fields
- **Headers**: Never log `Authorization`, `Cookie`, `Set-Cookie`
- **Request/Response bodies**: Never logged by default
- **Custom redaction**: App can register callback to strip domain-specific fields

---

## Coding Conventions

### iOS (Swift)

- Target: iOS 15+ (structured concurrency backport), prefer iOS 16+ for full actor reentrancy control
- **Use Swift structured concurrency exclusively — no GCD dispatch queues anywhere in SDK**
- Use `actor` for all mutable shared state: `EventBuffer`, `SessionManager`, `StorageWriter`
- Use `Task.detached(priority: .utility)` for background work — never `.high` or `.userInitiated`
- Public API is `nonisolated` and non-blocking — enqueues work, returns immediately
- Use `CryptoKit` for AES-GCM, `liboqs` Swift wrapper for ML-KEM
- Key storage in Keychain
- Module: `AppDiagLog`

### Memory Footprint Rules

Target: **< 100 KB steady-state runtime memory**. SDK is a utility — must not compete with host app for resources.

- **Small in-memory buffer, not full session**: Buffer only 50 events in memory, flush to disk frequently. Session lives on disk, not RAM.
- **Reuse allocations**: `removeAll(keepingCapacity: true)` on drain. Avoid repeated alloc/dealloc cycles.
- **Reserve capacity upfront**: `events.reserveCapacity(flushThreshold)`. One allocation, reused forever.
- **Lazy tracker initialization**: Tier 2/3 trackers instantiate only when accessed, not at SDK init. If disabled in config, never allocate.
- **Shared encoder instances**: Single `JSONEncoder` — encoder creation expensive, reuse it.
- **Use enums for repeated event names**: `EventName.screenView` instead of allocating `"screen_view"` string per event.
- **Autoreleasepool during export**: Wrap per-session iteration in `autoreleasepool { }` to prevent transient memory spike accumulation.

Memory budget breakdown:

| Component | Steady State |
|---|---|
| Event buffer (50 envelopes) | ~20–40 KB |
| Session index | ~1 KB |
| Tracker registrations | ~5 KB |
| Rate limiter state | ~0.5 KB |
| Shared encoder | ~2 KB |
| **Total** | **< 100 KB** |
| Flush spike (transient) | +200–500 KB |
| Export spike (transient) | +1–2 MB |

### Performance Safety Rules

- **Never block main thread**: Logging calls enqueue work, return immediately. All serialization, encryption, I/O on background threads/tasks.
- **Rate limiting**: Max 100 events/second default. Guards against logging loops (e.g., scroll listeners). Events beyond cap silently dropped.
- **Flush coalescing**: Use debounce — burst of events → flush once after burst settles, not during.
- **Encryption off hot path**: AES-GCM encryption during flush (cold path), not on every `.info()` / `.error()` call (hot path).
- **Low-priority background work**: Use `Task.detached(priority: .utility)`. SDK work never preempts UI rendering.
- **No-throw guarantee on public API**: All auto-tracking hooks wrap in try-catch. SDK bug must never crash host app.

### Other Rules

- One encrypted file per session (not monolithic database)
- Session index tracked via lightweight key-value store (SharedPreferences / UserDefaults)
- Buffer events in memory, flush every 50 events OR every 5 seconds OR on app backgrounding
- Re-encrypt entire session file on each flush (simple, fine for bounded sessions)
- Each session gets own DEK — never reuse across sessions
- All timestamps in UTC ISO 8601
- All string properties — no nested objects in event props

---

## Public API Surface

### Initialization

```swift
// iOS
AppDiagLog.initialize(config: .init(
    maxSessions: 5,
    maxEventsPerSession: 1000,
    maxDiskUsageMB: 10,
    pqcPublicKey: .init(
        algorithm: .mlKEM768,
        keyId: "key-2026-04",
        keyBytes: publicKeyData
    ),
    autoTrack: .init(/* ... */),
    redactor: { event in /* custom PII filter */ }
))
```

### Logging

```swift
AppDiagLog.debug("cache_hit", ["key": "user_prefs"])
AppDiagLog.info("screen_view", ["screen": "home"])
AppDiagLog.warning("low_memory", ["available_mb": "45"])
AppDiagLog.error("api_failure", ["endpoint": "/users", "status": "500"])
```

### Export

```swift
AppDiagLog.export { result in
    switch result {
    case .success(let export):
        uploadToSupport(export.file, export.sessionCount)
    case .failure(let error):
        showError(error)
    }
}

// Async version
let result = await AppDiagLog.export()
switch result {
  case .success(let export):
    uploadToSupport(export.file, export.sessionCount)
  case .failure(let error):
    showError(error)
}
```

### Session Tagging

```swift
AppDiagLog.tagSession("user reported checkout crash")
```

---

## Testing Strategy

- **Unit tests**: EventBuffer, SessionManager, RedactionEngine, encryption round-trip
- **Integration tests**: Full init → log → flush → export cycle
- **Encryption tests**: Verify envelope format, verify backend can decrypt, key rotation
- **Performance tests**: Measure overhead of auto-trackers on main thread
- **Size budget**: SDK binary < 200KB (excluding PQC library)
- **Stress tests**: Max events/session, rapid session cycling, low disk scenarios
