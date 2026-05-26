#!/usr/bin/env python3
"""AppDiagLog offline decryption CLI.

Takes an exported ZIP (produced by `AppDiagLog.export()` on iOS)
plus a key file mapping `key_id -> base64 private key`, decrypts every session
envelope it finds, and writes the events in the chosen output format:

  jsonl     — one .jsonl file per session (default)
  csv       — sessions.csv + events.csv
  combined  — single combined.jsonl with continuous sequence across sessions
  xls       — export.xlsx with two sheets: Sessions and Events

Algorithm dispatch is driven by the strings embedded in each envelope:

  symmetric  AEAD: AES-256-GCM | AES-128-GCM | ChaCha20-Poly1305
  asymmetric KEK:  ML-KEM-768 | ML-KEM-512 | RSA-OAEP-3072 | ECDH-P256+HKDF

Run --help for options. Exit codes:
  0  every session decrypted
  1  partial success (failures printed to stderr)
  2  no sessions decrypted (likely wrong keys or no envelopes)
"""

from __future__ import annotations

import argparse
import base64
import csv
import io
import json
import os
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# -- optional deps: failing imports are turned into actionable errors at runtime --
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
    from cryptography.hazmat.primitives.asymmetric import padding, rsa, ec
    from cryptography.hazmat.primitives import hashes, serialization, hmac
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives.keywrap import aes_key_unwrap_with_padding, aes_key_unwrap
    from cryptography.hazmat.backends import default_backend
except ImportError as e:  # pragma: no cover
    sys.stderr.write(
        "ERROR: 'cryptography' is required.\n"
        "Install with: pip install -r requirements.txt\n"
        f"Original error: {e}\n"
    )
    sys.exit(2)

try:
    import openpyxl  # type: ignore
    from openpyxl.styles import Font  # type: ignore
    _OPENPYXL_AVAILABLE = True
except ImportError:
    _OPENPYXL_AVAILABLE = False


# ---------------------------------------------------------------------------
# data model
# ---------------------------------------------------------------------------

@dataclass
class Envelope:
    session_id: str
    created_at: str
    sealed_at: str | None
    event_count: int
    session_tag: str | None
    device_metadata: dict[str, str]
    algorithm: str
    nonce_b64: str
    kek_algorithm: str
    key_id: str
    kem_ciphertext_b64: str
    wrapped_dek_b64: str
    payload_b64: str

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Envelope":
        enc = data["encryption"]
        return cls(
            session_id=data["session_id"],
            created_at=data["created_at"],
            sealed_at=data.get("sealed_at"),
            event_count=data.get("event_count", 0),
            session_tag=data.get("session_tag"),
            device_metadata=data.get("device_metadata", {}),
            algorithm=enc["algorithm"],
            nonce_b64=enc["nonce"],
            kek_algorithm=enc["kek_algorithm"],
            key_id=enc["key_id"],
            kem_ciphertext_b64=enc.get("kem_ciphertext", ""),
            wrapped_dek_b64=enc["wrapped_dek"],
            payload_b64=data["payload"],
        )


# ---------------------------------------------------------------------------
# symmetric AEADs
# ---------------------------------------------------------------------------

def decrypt_payload(algorithm: str, dek: bytes, iv: bytes, ciphertext_and_tag: bytes, aad: bytes) -> bytes:
    if algorithm == "AES-256-GCM":
        if len(dek) != 32:
            raise ValueError(f"AES-256-GCM needs a 32-byte key, got {len(dek)}")
        return AESGCM(dek).decrypt(iv, ciphertext_and_tag, aad)
    if algorithm == "AES-128-GCM":
        if len(dek) != 16:
            raise ValueError(f"AES-128-GCM needs a 16-byte key, got {len(dek)}")
        return AESGCM(dek).decrypt(iv, ciphertext_and_tag, aad)
    if algorithm == "ChaCha20-Poly1305":
        if len(dek) != 32:
            raise ValueError(f"ChaCha20-Poly1305 needs a 32-byte key, got {len(dek)}")
        return ChaCha20Poly1305(dek).decrypt(iv, ciphertext_and_tag, aad)
    raise ValueError(f"Unsupported symmetric algorithm: {algorithm}")


# ---------------------------------------------------------------------------
# asymmetric KEM dispatchers
# ---------------------------------------------------------------------------

def unwrap_dek(envelope: Envelope, private_key_bytes: bytes) -> bytes:
    kem_ct = base64.b64decode(envelope.kem_ciphertext_b64) if envelope.kem_ciphertext_b64 else b""
    wrapped = base64.b64decode(envelope.wrapped_dek_b64)
    alg = envelope.kek_algorithm

    if alg in ("ML-KEM-768", "ML-KEM-512"):
        return _unwrap_ml_kem(kem_ct, wrapped, private_key_bytes, alg)
    if alg == "RSA-OAEP-3072":
        return _unwrap_rsa_oaep(wrapped, private_key_bytes)
    if alg == "ECDH-P256+HKDF":
        return _unwrap_ecdh_p256(kem_ct, wrapped, private_key_bytes)
    raise ValueError(f"Unsupported KEK algorithm: {alg}")


_RFC3394_IV = b'\xa6\xa6\xa6\xa6\xa6\xa6\xa6\xa6'
_RFC5649_MARKER = b'\xa6\x59\x59\xa6'


def _rfc5649_unpad(data: bytes) -> bytes:
    """Strip the RFC 5649 header [A6 59 59 A6 | length_4be] from the start of data."""
    if len(data) < 8:
        raise ValueError(f"data too short ({len(data)} B) for RFC 5649 header")
    if data[:4] != _RFC5649_MARKER:
        raise ValueError(f"invalid RFC 5649 marker: {data[:4].hex()}")
    length = int.from_bytes(data[4:8], 'big')
    if 8 + length > len(data):
        raise ValueError(f"RFC 5649 MLI {length} exceeds available data ({len(data) - 8} B)")
    return data[8:8 + length]


def _aes_kwp_unwrap(kek: bytes, wrapped: bytes) -> bytes:
    """Unwrap a DEK regardless of which AES key-wrap scheme was used.

    Two schemes exist in the wild:

    **iOS (AesKwp.swift)**
      CCSymmetricKeyWrap uses RFC 3394 (IV = A6A6A6A6A6A6A6A6).  The caller
      manually prepends [A6 59 59 A6 | length_4be] to the plaintext *before*
      wrapping, so the decrypted plaintext blocks contain that header.
      Detect: ``aes_key_unwrap`` succeeds → recovered plaintext starts with A65959A6.

    **True RFC 5649 (Android BouncyCastle AESWRAPPAD, any compliant SDK)**
      The AIV A65959A6+MLI is used as the initial vector *inside* the KW loop.
      The wrapped blob is smaller (no manual header in plaintext).
      Detect: ``aes_key_unwrap`` raises (wrong IV) → fall back to
      ``aes_key_unwrap_with_padding``.
    """
    # iOS path: RFC 3394 unwrap → plaintext contains the manual RFC 5649 header.
    try:
        return _rfc5649_unpad(aes_key_unwrap(kek, wrapped, default_backend()))
    except Exception:
        pass
    # True RFC 5649 path (Android BouncyCastle AESWRAPPAD or any compliant SDK).
    return aes_key_unwrap_with_padding(kek, wrapped, default_backend())


def _unwrap_ml_kem(kem_ct: bytes, wrapped: bytes, priv: bytes, alg: str) -> bytes:
    # ML-KEM via the optional `oqs` Python package. We surface a clear error if it's
    # not installed because the install story is platform-specific.
    try:
        import oqs  # type: ignore
    except ImportError as e:
        raise RuntimeError(
            "Decrypting ML-KEM envelopes needs the 'oqs' Python package.\n"
            "On macOS/Linux: `pip install pyoqs` (or follow https://github.com/open-quantum-safe/liboqs-python).\n"
            f"Underlying error: {e}"
        )
    name = "ML-KEM-768" if alg == "ML-KEM-768" else "ML-KEM-512"
    with oqs.KeyEncapsulation(name, secret_key=priv) as kem:
        shared = kem.decap_secret(kem_ct)
    return _aes_kwp_unwrap(shared, wrapped)



def _unwrap_rsa_oaep(wrapped: bytes, priv: bytes) -> bytes:
    private_key = serialization.load_der_private_key(priv, password=None, backend=default_backend())
    if not isinstance(private_key, rsa.RSAPrivateKey):
        raise ValueError("RSA-OAEP key did not parse as RSA private key.")
    return private_key.decrypt(
        wrapped,
        padding.OAEP(
            mgf=padding.MGF1(algorithm=hashes.SHA256()),
            algorithm=hashes.SHA256(),
            label=None,
        ),
    )


def _unwrap_ecdh_p256(kem_ct: bytes, wrapped: bytes, priv: bytes) -> bytes:
    private_key = serialization.load_der_private_key(priv, password=None, backend=default_backend())
    if not isinstance(private_key, ec.EllipticCurvePrivateKey):
        raise ValueError("ECDH key did not parse as EC private key.")
    # Recipient's static private key; ephemeral pub came in kem_ciphertext (SPKI/X.509 DER).
    ephemeral_pub = serialization.load_der_public_key(kem_ct, backend=default_backend())
    shared = private_key.exchange(ec.ECDH(), ephemeral_pub)
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=kem_ct,
        info=b"AppDiagLog/ECDH-P256+HKDF",
        backend=default_backend(),
    )
    wrap_key = hkdf.derive(shared)
    return _aes_kwp_unwrap(wrap_key, wrapped)


# ---------------------------------------------------------------------------
# core ingest loop
# ---------------------------------------------------------------------------

def decrypt_envelope(envelope: Envelope, keys: dict[str, bytes]) -> list[dict[str, Any]]:
    """Decrypt a session envelope and return its events with boundary markers injected.

    Returns an empty list only for sessions that have zero events AND ended cleanly
    (app launched briefly with nothing to record). Callers should skip those.

    Boundary events injected:
    - ``session_start`` (first): carries device metadata as props.
    - ``session_end`` (last): level=info when cleanly sealed; level=warning + sealed=false
      for abnormal terminations (force-kill, OOM, watchdog, debugger-intercepted crash).
    """
    priv = keys.get(envelope.key_id)
    if priv is None:
        raise KeyError(f"no private key for key_id '{envelope.key_id}'")
    dek = unwrap_dek(envelope, priv)
    iv = base64.b64decode(envelope.nonce_b64)
    payload = base64.b64decode(envelope.payload_b64)
    aad = f"{envelope.session_id}|{envelope.key_id}".encode("utf-8")
    plaintext = decrypt_payload(envelope.algorithm, dek, iv, payload, aad)
    events: list[dict[str, Any]] = json.loads(plaintext.decode("utf-8"))

    has_clean_seal = bool(envelope.sealed_at)

    # Skip only truly empty sessions that ended normally (app launched and closed
    # within the flush interval with nothing to record). Keep empty sessions that
    # ended abnormally — they are the most likely crash-before-first-flush cases.
    if not events and has_clean_seal:
        return []

    # -- session_start --------------------------------------------------------
    start_props = dict(envelope.device_metadata)
    if envelope.session_tag:
        start_props["session_tag"] = envelope.session_tag
    start_event: dict[str, Any] = {
        "seq": 0,
        "ts": envelope.created_at,
        "session_id": envelope.session_id,
        "screen": None,
        "event": "session_start",
        "level": "info",
        "props": start_props,
    }

    # Best-effort end timestamp when sealed_at is absent
    end_ts = (events[-1].get("ts") if events else None) or envelope.sealed_at or envelope.created_at
    end_seq = max((_seq_sort_key(ev.get("seq")) for ev in events), default=0) + 1

    # -- session_end ----------------------------------------------------------
    end_props: dict[str, str] = {"event_count": str(len(events))}
    if has_clean_seal:
        tail: list[dict[str, Any]] = [{
            "seq": end_seq,
            "ts": envelope.sealed_at,
            "session_id": envelope.session_id,
            "screen": None,
            "event": "session_end",
            "level": "info",
            "props": end_props,
        }]
    else:
        end_props["sealed"] = "false"
        tail = [{
            "seq": end_seq,
            "ts": end_ts,
            "session_id": envelope.session_id,
            "screen": None,
            "event": "session_end",
            "level": "warning",
            "props": end_props,
        }]

    return [start_event, *events, *tail]


def iter_envelopes(zip_path: Path) -> list[Envelope]:
    envelopes: list[Envelope] = []
    with zipfile.ZipFile(zip_path) as zf:
        for name in zf.namelist():
            if not (name.startswith("sessions/") and name.endswith(".enc")):
                continue
            with zf.open(name) as fh:
                data = json.load(io.TextIOWrapper(fh, encoding="utf-8"))
                envelopes.append(Envelope.from_json(data))
    return envelopes


def load_keys(keys_path: Path) -> dict[str, bytes]:
    raw = json.loads(keys_path.read_text())
    return {k: base64.b64decode(v) for k, v in raw.items()}


# ---------------------------------------------------------------------------
# output writers
# ---------------------------------------------------------------------------

def write_jsonl(out_dir: Path, envelope: Envelope, events: list[dict[str, Any]]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{envelope.session_id}.jsonl"
    with path.open("w", encoding="utf-8") as f:
        for ev in sorted(events, key=_event_sort_key):
            f.write(json.dumps(ev, sort_keys=True) + "\n")


def write_combined_jsonl(
    out_dir: Path,
    collected: list[tuple[Envelope, list[dict[str, Any]]]],
) -> None:
    """Write every event from every session into a single combined.jsonl file.

    Sessions are walked by creation time, then events are sorted by their
    SDK-assigned per-session ``seq`` field. The output ``seq`` is rewritten as a
    continuous combined counter so the file is self-contained and globally
    ordered.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    all_events: list[dict[str, Any]] = []
    combined_seq = 1
    for envelope, events in sorted(collected, key=_session_sort_key):
        for ev in sorted(events, key=_event_sort_key):
            merged = {"session_id": envelope.session_id}
            merged.update(ev)
            merged["seq"] = combined_seq
            all_events.append(merged)
            combined_seq += 1
    path = out_dir / "combined.jsonl"
    with path.open("w", encoding="utf-8") as f:
        for ev in all_events:
            f.write(json.dumps(ev, sort_keys=True) + "\n")


_SESSIONS_HEADERS = ["id", "key_id", "created_at", "sealed_at", "event_count",
                     "session_tag", "device_metadata"]
_EVENTS_HEADERS = ["session_id", "seq", "ts", "level", "event_name", "screen", "props"]


def write_xlsx(
    out_dir: Path,
    collected: list[tuple[Envelope, list[dict[str, Any]]]],
) -> None:
    """Write all sessions and events into a single export.xlsx workbook.

    The workbook has two sheets:
    - **Sessions** — one row per session (same columns as sessions.csv).
    - **Events**   — one row per event across all sessions (same columns as
      events.csv), sorted by session creation time and SDK per-session sequence.
      The exported ``seq`` column is rewritten as a continuous combined counter.

    Requires ``openpyxl`` (pip install openpyxl).
    """
    if not _OPENPYXL_AVAILABLE:
        raise RuntimeError(
            "'openpyxl' is required for XLS output.\n"
            "Install with: pip install openpyxl  (or pip install -r scripts/requirements.txt)"
        )
    out_dir.mkdir(parents=True, exist_ok=True)

    wb = openpyxl.Workbook()
    bold = Font(bold=True)

    # -- Sessions sheet -------------------------------------------------------
    ws_sessions = wb.active
    ws_sessions.title = "Sessions"
    ws_sessions.append(_SESSIONS_HEADERS)
    for cell in ws_sessions[1]:
        cell.font = bold

    # -- Events sheet ---------------------------------------------------------
    ws_events = wb.create_sheet("Events")
    ws_events.append(_EVENTS_HEADERS)
    for cell in ws_events[1]:
        cell.font = bold

    # Collect events for sorting, then write both sheets together
    all_event_rows: list[list[Any]] = []
    combined_seq = 1
    for envelope, events in sorted(collected, key=_session_sort_key):
        ws_sessions.append([
            envelope.session_id,
            envelope.key_id,
            envelope.created_at,
            envelope.sealed_at or "",
            envelope.event_count,
            envelope.session_tag or "",
            json.dumps(envelope.device_metadata, sort_keys=True),
        ])
        for ev in sorted(events, key=_event_sort_key):
            all_event_rows.append([
                envelope.session_id,
                combined_seq,
                ev.get("ts") or "",
                ev.get("level") or "",
                ev.get("event") or "",
                ev.get("screen") or "",
                json.dumps(ev.get("props") or {}, sort_keys=True),
            ])
            combined_seq += 1

    for row in all_event_rows:
        ws_events.append(row)

    wb.save(str(out_dir / "export.xlsx"))


def open_csv_writers(out_dir: Path) -> tuple[csv.writer, csv.writer, Any, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    sessions_f = (out_dir / "sessions.csv").open("w", encoding="utf-8", newline="")
    events_f = (out_dir / "events.csv").open("w", encoding="utf-8", newline="")
    sessions_w = csv.writer(sessions_f)
    sessions_w.writerow(["id", "key_id", "created_at", "sealed_at", "event_count",
                         "session_tag", "device_metadata"])
    events_w = csv.writer(events_f)
    events_w.writerow(["session_id", "seq", "ts", "level", "event_name", "screen", "props"])
    return sessions_w, events_w, sessions_f, events_f


def write_csv_rows(sessions_w: csv.writer, events_w: csv.writer,
                   envelope: Envelope, events: list[dict[str, Any]]) -> None:
    sessions_w.writerow([
        envelope.session_id,
        envelope.key_id,
        envelope.created_at,
        envelope.sealed_at or "",
        envelope.event_count,
        envelope.session_tag or "",
        json.dumps(envelope.device_metadata, sort_keys=True),
    ])
    for ev in sorted(events, key=_event_sort_key):
        events_w.writerow([
            envelope.session_id,
            ev.get("seq"),
            ev.get("ts"),
            ev.get("level"),
            ev.get("event"),
            ev.get("screen") or "",
            json.dumps(ev.get("props") or {}, sort_keys=True),
        ])


def _event_sort_key(ev: dict[str, Any]) -> tuple[int, str]:
    return (_seq_sort_key(ev.get("seq")), ev.get("ts") or "9999-99-99")


def _session_sort_key(item: tuple[Envelope, list[dict[str, Any]]]) -> tuple[str, str]:
    envelope, _ = item
    return (envelope.created_at, envelope.session_id)


def _seq_sort_key(value: Any) -> int:
    try:
        seq = int(value)
    except (TypeError, ValueError):
        return 2**63 - 1
    if seq < 0:
        return 2**63 - 1
    return seq


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Decrypt a AppDiagLog export ZIP using offline private keys."
    )
    parser.add_argument("--zip", required=True, type=Path, help="Path to the exported ZIP.")
    parser.add_argument("--keys", required=True, type=Path,
                        help="JSON file mapping key_id -> base64 PKCS#8 private key.")
    parser.add_argument("--out", required=True, type=Path, help="Output directory.")
    parser.add_argument("--format", choices=("jsonl", "csv", "combined", "xls"), default="jsonl",
                        help="Output format. 'jsonl' = one file per session. "
                             "'csv' = sessions.csv + events.csv. "
                             "'combined' = single combined.jsonl with continuous sequence. "
                             "'xls' = export.xlsx with Sessions and Events sheets.")
    args = parser.parse_args(argv)

    if not args.zip.exists():
        sys.stderr.write(f"ZIP not found: {args.zip}\n"); return 2
    if not args.keys.exists():
        sys.stderr.write(f"Keys file not found: {args.keys}\n"); return 2

    envelopes = iter_envelopes(args.zip)
    if not envelopes:
        sys.stderr.write("No session envelopes found in the ZIP.\n"); return 2
    keys = load_keys(args.keys)

    successes: list[str] = []
    failures: list[tuple[str, str]] = []

    if args.format == "csv":
        sessions_w, events_w, sessions_f, events_f = open_csv_writers(args.out)
        try:
            for envelope in envelopes:
                try:
                    events = decrypt_envelope(envelope, keys)
                    if not events:
                        continue  # empty session — skip silently
                    write_csv_rows(sessions_w, events_w, envelope, events)
                    successes.append(envelope.session_id)
                except Exception as e:  # noqa: BLE001
                    failures.append((envelope.session_id, str(e)))
        finally:
            sessions_f.close()
            events_f.close()
    elif args.format in ("combined", "xls"):
        collected: list[tuple[Envelope, list[dict[str, Any]]]] = []
        for envelope in envelopes:
            try:
                events = decrypt_envelope(envelope, keys)
                if not events:
                    continue  # empty session — skip silently
                collected.append((envelope, events))
                successes.append(envelope.session_id)
            except Exception as e:  # noqa: BLE001
                failures.append((envelope.session_id, str(e)))
        if collected:
            if args.format == "combined":
                write_combined_jsonl(args.out, collected)
            else:
                write_xlsx(args.out, collected)
    else:
        for envelope in envelopes:
            try:
                events = decrypt_envelope(envelope, keys)
                if not events:
                    continue  # empty session — skip silently
                write_jsonl(args.out, envelope, events)
                successes.append(envelope.session_id)
            except Exception as e:  # noqa: BLE001
                failures.append((envelope.session_id, str(e)))

    print(f"Decrypted: {len(successes)} sessions to {args.out}")
    if failures:
        print(f"Failed: {len(failures)} sessions", file=sys.stderr)
        for sid, reason in failures:
            print(f"  - {sid}: {reason}", file=sys.stderr)

    if not successes:
        return 2
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
