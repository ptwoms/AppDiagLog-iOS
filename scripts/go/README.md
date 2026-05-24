# diaglog-decrypt — offline decryption & keygen (Go)

Static-binary CLIs that decrypt a `AppDiagLog.export()` ZIP and generate
keypairs for the SDK, using private keys from a `keys.json` file. Implements
the same algorithm matrix as the Python scripts.

## Build

```bash
cd scripts/go

# Decrypt tool
go build -o diaglog-decrypt ./cmd/diaglog-decrypt

# Keygen tool
go build -o diaglog-keygen ./cmd/diaglog-keygen
```

---

## diaglog-keygen — generate a keypair

```bash
./diaglog-keygen \
    --key-id  my-key-2026-06 \
    --out     /path/to/keys/ \
    --algorithm ML-KEM-768   # ML-KEM-768 (default) | ML-KEM-512 | RSA-OAEP-3072 | ECDH-P256+HKDF
```

### What it writes

| File | Purpose |
|------|---------|
| `<out>/keys.json` | Private key entry `{ "key-id": "<base64>" }`. Append-safe — running again with a different `--key-id` adds a new entry. Pass this file to `diaglog-decrypt --keys`. |
| `<out>/<key-id>.pub.b64` | Base64 public key. Paste the contents into the SDK's `PQCPublicKey(keyBytes = …)`. |

The tool also prints a ready-to-paste SDK init snippet for iOS (Swift).

### Key format per algorithm

| Algorithm | Public key format | Private key format |
|-----------|------------------|--------------------|
| ML-KEM-768 | Raw ML-KEM public key bytes (circl) | Raw ML-KEM private key bytes (circl) |
| ML-KEM-512 | Raw ML-KEM public key bytes (circl) | Raw ML-KEM private key bytes (circl) |
| RSA-OAEP-3072 | SubjectPublicKeyInfo DER | PKCS#8 DER |
| ECDH-P256+HKDF | SubjectPublicKeyInfo DER | PKCS#8 DER |

---

## diaglog-decrypt — decrypt an export ZIP

```bash
./diaglog-decrypt \
    --zip /path/to/export.zip \
    --keys /path/to/keys.json \
    --out /tmp/decrypted/ \
    --format jsonl       # jsonl | csv | combined | xls
```

### Output formats

| Format | Output | Description |
|--------|--------|-------------|
| `jsonl` (default) | `out/<session_id>.jsonl` | One file per session; events one-per-line as JSON objects. |
| `csv` | `out/sessions.csv` + `out/events.csv` | Two flat CSV files. |
| `combined` | `out/combined.jsonl` | Single JSONL with **all** events from all sessions, sorted by timestamp. Each event has an injected `session_id` field. |
| `xls` | `out/export.xlsx` | Excel workbook with a **Sessions** sheet and an **Events** sheet. Events sorted by timestamp. |

### keys.json format

```json
{
  "my-key-2026-06":     "MIIE...base64...==",
  "sample-key-rsa-2026-04": "MIIE...base64...=="
}
```

For ML-KEM keys the value is the raw seed bytes (or a PKCS#8 wrapper around
them) — the CLI auto-detects the encoding. For RSA-OAEP and ECDH the value
must be a PKCS#8-encoded private key.

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | All sessions decrypted |
| 1    | Partial — some failed (see stderr) |
| 2    | None decrypted (wrong keys, empty ZIP, missing deps) |
