#!/usr/bin/env python3
"""AppDiagLog keypair generator.

Generates an asymmetric keypair for use with the AppDiagLog SDK:

  Public key  → embed in the app as `PQCPublicKey(keyBytes = ...)` in SDK init.
  Private key → store in keys.json for offline decryption via decrypt.py /
                diaglog-decrypt.

Supported algorithms
--------------------
  ML-KEM-768      (default, PQC)  requires `pyoqs`
  ML-KEM-512      (PQC)           requires `pyoqs`
  RSA-OAEP-3072   (classic RSA)   requires `cryptography` only
  ECDH-P256+HKDF  (classic ECDH)  requires `cryptography` only

Output files
------------
  <out>/keys.json         — private key file (append-safe); pass to --keys
  <out>/<key-id>.pub.b64  — base64 public key; paste into SDK config

Usage
-----
  python3 scripts/keygen.py --key-id my-key-2026-06 --out /path/to/keys/
  python3 scripts/keygen.py --algorithm RSA-OAEP-3072 --key-id rsa-key --out .
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Required: cryptography (RSA + ECDH generation; always needed)
# ---------------------------------------------------------------------------
try:
    from cryptography.hazmat.primitives.asymmetric import rsa, ec
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.backends import default_backend
except ImportError as e:  # pragma: no cover
    sys.stderr.write(
        "ERROR: 'cryptography' is required.\n"
        "Install with: pip install -r scripts/requirements.txt\n"
        f"Original error: {e}\n"
    )
    sys.exit(2)


# ---------------------------------------------------------------------------
# Key generation helpers
# ---------------------------------------------------------------------------

def _generate_ml_kem(algorithm: str) -> tuple[bytes, bytes]:
    """Return (public_key_bytes, private_key_bytes) for ML-KEM-768/512.

    Requires the optional `pyoqs` package (liboqs Python binding).
    Public and private key bytes are the raw binary representations produced
    by liboqs — the same format that `decrypt.py` and `diaglog-decrypt` expect.
    """
    try:
        import oqs  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            f"Generating {algorithm} keypairs requires the 'pyoqs' package.\n"
            "Install: pip install pyoqs\n"
            "  or follow https://github.com/open-quantum-safe/liboqs-python\n"
            f"Underlying error: {exc}"
        ) from exc
    with oqs.KeyEncapsulation(algorithm) as kem:
        public_key: bytes = kem.generate_keypair()
        private_key: bytes = kem.export_secret_key()
    return public_key, private_key


def _generate_rsa_oaep_3072() -> tuple[bytes, bytes]:
    """Return (SubjectPublicKeyInfo DER, PKCS#8 DER) for RSA-3072."""
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=3072,
        backend=default_backend(),
    )
    pub_bytes = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    priv_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return pub_bytes, priv_bytes


def _generate_ecdh_p256() -> tuple[bytes, bytes]:
    """Return (SubjectPublicKeyInfo DER, PKCS#8 DER) for ECDH-P256."""
    private_key = ec.generate_private_key(ec.SECP256R1(), backend=default_backend())
    pub_bytes = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    priv_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return pub_bytes, priv_bytes


def generate_keypair(algorithm: str) -> tuple[bytes, bytes]:
    """Return (public_key_bytes, private_key_bytes) for `algorithm`.

    Raises ValueError for unknown algorithms, RuntimeError if a required
    optional dependency is missing.
    """
    if algorithm in ("ML-KEM-768", "ML-KEM-512"):
        return _generate_ml_kem(algorithm)
    if algorithm == "RSA-OAEP-3072":
        return _generate_rsa_oaep_3072()
    if algorithm == "ECDH-P256+HKDF":
        return _generate_ecdh_p256()
    raise ValueError(
        f"Unsupported algorithm: {algorithm!r}. "
        "Choose from: ML-KEM-768, ML-KEM-512, RSA-OAEP-3072, ECDH-P256+HKDF"
    )


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def _update_keys_json(keys_path: Path, key_id: str, priv_b64: str) -> None:
    """Append or overwrite key_id in keys.json without touching other entries."""
    existing: dict[str, str] = {}
    if keys_path.exists():
        try:
            existing = json.loads(keys_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            sys.stderr.write(
                f"WARNING: {keys_path} is not valid JSON — overwriting.\n"
            )
    if key_id in existing:
        sys.stderr.write(
            f"WARNING: key_id '{key_id}' already exists in keys.json — overwriting.\n"
        )
    existing[key_id] = priv_b64
    # Write with restricted permissions (private key material).
    keys_path.touch(mode=0o600, exist_ok=True)
    keys_path.write_text(
        json.dumps(existing, indent=2) + "\n", encoding="utf-8"
    )
    os.chmod(keys_path, 0o600)


def _print_sdk_snippet(algorithm: str, key_id: str, pub_b64: str) -> None:
    preview = pub_b64[:48] + ("…" if len(pub_b64) > 48 else "")
    print("── SDK init snippet ──────────────────────────────────────────────────")
    print("iOS (Swift):")
    print(f'  AppDiagLog.initialize(config: .init(')
    print(f'    pqcPublicKey: .init(')
    print(f'      algorithm: .{_swift_enum(algorithm)},')
    print(f'      keyId:     "{key_id}",')
    print(f'      keyBytes:  Data(base64Encoded: "{preview}")!,')
    print(f'    ),')
    print(f'  ))')
    print("─────────────────────────────────────────────────────────────────────")


def _swift_enum(algorithm: str) -> str:
    return {
        "ML-KEM-768": "mlKEM768",
        "ML-KEM-512": "mlKEM512",
        "RSA-OAEP-3072": "rsaOAEP3072",
        "ECDH-P256+HKDF": "ecdhP256HKDF",
    }.get(algorithm, algorithm)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a AppDiagLog keypair. "
            "Writes a keys.json entry (private key) and a .pub.b64 file (public key), "
            "then prints the SDK init snippet."
        )
    )
    parser.add_argument(
        "--algorithm",
        default="ML-KEM-768",
        choices=("ML-KEM-768", "ML-KEM-512", "RSA-OAEP-3072", "ECDH-P256+HKDF"),
        help="KEK algorithm. Default: ML-KEM-768.",
    )
    parser.add_argument(
        "--key-id",
        required=True,
        metavar="KEY_ID",
        help="Logical identifier, e.g. 'key-2026-06'. Must be unique per backend deployment.",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="Output directory. keys.json is created/updated; <key-id>.pub.b64 is written.",
    )
    args = parser.parse_args(argv)

    try:
        pub_bytes, priv_bytes = generate_keypair(args.algorithm)
    except (ValueError, RuntimeError) as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        return 1

    args.out.mkdir(parents=True, exist_ok=True)

    pub_b64 = base64.b64encode(pub_bytes).decode("ascii")
    priv_b64 = base64.b64encode(priv_bytes).decode("ascii")

    # Private key → keys.json (used by decrypt.py --keys)
    keys_path = args.out / "keys.json"
    _update_keys_json(keys_path, args.key_id, priv_b64)

    # Public key → <key-id>.pub.b64 (paste into SDK init config)
    pub_path = args.out / f"{args.key_id}.pub.b64"
    pub_path.write_text(pub_b64 + "\n", encoding="ascii")

    print(f"Algorithm : {args.algorithm}")
    print(f"Key ID    : {args.key_id}")
    print(f"Private   : {keys_path}  (pass as --keys to decrypt.py)")
    print(f"Public    : {pub_path}  (embed in SDK init config)")
    print()
    _print_sdk_snippet(args.algorithm, args.key_id, pub_b64)
    return 0


if __name__ == "__main__":
    sys.exit(main())
