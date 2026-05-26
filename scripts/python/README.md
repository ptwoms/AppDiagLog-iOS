# AppDiagLog — offline decryption (Python)

`decrypt.py` decrypts a `AppDiagLog.export()` ZIP without running the
backend. Useful when the host app emailed the export to support and you want
to read it locally.

`keygen.py` generates the asymmetric keypair: the public key is embedded in
the app at build time; the private key stays on the backend (or in a local
`keys.json`) for decryption.

## Install

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

ML-KEM envelopes additionally need `pyoqs`. Install instructions are at
<https://github.com/open-quantum-safe/liboqs-python> — the wheel availability
varies by OS/architecture. RSA-OAEP-3072 and ECDH-P256+HKDF envelopes have no
extra dependencies beyond `cryptography`.

---

## keygen.py — generate a keypair

```bash
python3 keygen.py \
    --key-id  my-key-2026-06 \
    --out     /path/to/keys/ \
    --algorithm ML-KEM-768   # ML-KEM-768 (default) | ML-KEM-512 | RSA-OAEP-3072 | ECDH-P256+HKDF
```

### What it writes

| File | Purpose |
|------|---------|
| `<out>/keys.json` | Private key entry `{ "key-id": "<base64>" }`. Append-safe — running again with a different `--key-id` adds a new entry. Pass this file to `decrypt.py --keys`. |
| `<out>/<key-id>.pub.b64` | Base64 public key. Paste the contents into the SDK's `PQCPublicKey(keyBytes = …)`. |

The tool also prints a ready-to-paste SDK init snippet for iOS (Swift).

### Key format per algorithm

| Algorithm | Public key format | Private key format |
|-----------|------------------|--------------------|
| ML-KEM-768 | Raw ML-KEM public key bytes | Raw ML-KEM private key bytes |
| ML-KEM-512 | Raw ML-KEM public key bytes | Raw ML-KEM private key bytes |
| RSA-OAEP-3072 | SubjectPublicKeyInfo DER | PKCS#8 DER |
| ECDH-P256+HKDF | SubjectPublicKeyInfo DER | PKCS#8 DER |

> **Note:** ML-KEM-768/512 generation requires `pyoqs`. RSA and ECDH work with
> only the `cryptography` package.

---

## decrypt.py — decrypt an export ZIP

```bash
python3 decrypt.py \
    --zip /path/to/export.zip \
    --keys /path/to/keys.json \
    --out /tmp/decrypted/ \
    --format jsonl          # jsonl | csv | combined | xls
```

### Output formats

| Format | Output | Description |
|--------|--------|-------------|
| `jsonl` (default) | `out/<session_id>.jsonl` | One file per session; events one-per-line as JSON objects. |
| `csv` | `out/sessions.csv` + `out/events.csv` | Two flat CSV files; props are a JSON blob in a single column. |
| `combined` | `out/combined.jsonl` | Single JSONL with **all** events from all sessions, ordered by session creation time + SDK per-session sequence. Each event has an injected `session_id` field and a continuous combined `seq`. |
| `xls` | `out/export.xlsx` | Excel workbook with a **Sessions** sheet and an **Events** sheet. Events use a continuous combined `seq`. Requires `openpyxl` (included in `requirements.txt`). |

### keys.json format

Map of `key_id` to base64-encoded private key bytes. Generate it with
`keygen.py` above, or produce it manually:

```json
{
  "my-key-2026-06": "MIIE...base64...==",
  "rsa-key-2026-06": "MIIE...base64...=="
}
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | All sessions decrypted |
| 1    | Partial success — some sessions failed (printed to stderr) |
| 2    | Nothing decrypted — wrong keys, empty ZIP, or missing deps |
