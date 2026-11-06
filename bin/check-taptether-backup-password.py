#!/usr/bin/env python3
"""Verify a TapTether .ttbackup password without printing or restoring secrets.

Compatible with DeviceBackupCodec format v1 (AES-256-GCM + PBKDF2-SHA256).
No network, cloud, app, or iOS Keychain access is used.
"""

import argparse
import base64
import binascii
import getpass
import hashlib
import json
from pathlib import Path
import sys

ENCRYPTED = "taptether-encrypted-devices"
UNPROTECTED = "taptether-unprotected-devices"
VERSION = 1
ITERATIONS = 240_000
MAX_BYTES = 4 * 1024 * 1024
MAX_KEYS = 150


class InvalidBackup(Exception):
    pass


def read_envelope(path: Path) -> dict:
    try:
        # Read no more than the application's maximum file size plus one byte.
        with path.open("rb") as handle:
            data = handle.read(MAX_BYTES + 1)
    except OSError as exc:
        raise InvalidBackup(f"Cannot read backup: {exc.strerror or exc}") from None
    if not data or len(data) > MAX_BYTES:
        raise InvalidBackup("Backup is empty or exceeds TapTether's 4 MiB limit.")
    try:
        envelope = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise InvalidBackup("Not a valid TapTether JSON backup.") from None
    if not isinstance(envelope, dict) or type(envelope.get("version")) is not int or envelope["version"] != VERSION:
        raise InvalidBackup("Unsupported TapTether backup version.")
    if envelope.get("format") not in (ENCRYPTED, UNPROTECTED):
        raise InvalidBackup("Unknown TapTether backup format.")
    return envelope


def decode_part(envelope: dict, field: str) -> bytes:
    value = envelope.get(field)
    if not isinstance(value, str):
        raise InvalidBackup(f"Missing {field} data in encrypted backup.")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise InvalidBackup(f"Invalid {field} encoding in backup.") from None


def encrypted_parts(envelope: dict):
    if (envelope.get("kdf") != "PBKDF2-HMAC-SHA256" or
            envelope.get("cipher") != "AES-256-GCM" or
            type(envelope.get("iterations")) is not int or
            envelope["iterations"] != ITERATIONS):
        raise InvalidBackup("Unsupported encryption parameters in backup.")
    salt = decode_part(envelope, "salt")
    nonce = decode_part(envelope, "nonce")
    mac = decode_part(envelope, "mac")
    ciphertext = decode_part(envelope, "ciphertext")
    if len(salt) != 16 or len(nonce) != 12 or len(mac) != 16 or not ciphertext or len(ciphertext) > MAX_BYTES:
        raise InvalidBackup("Corrupt or unsupported encrypted backup fields.")
    return salt, nonce, mac, ciphertext


def show_info(envelope: dict) -> None:
    protected = envelope["format"] == ENCRYPTED
    print("TapTether backup format: v1")
    print(f"Password protected: {'yes' if protected else 'no'}")
    created = envelope.get("createdUtc")
    if isinstance(created, str) and len(created) < 100:
        print(f"Created (UTC): {created}")
    if protected:
        encrypted_parts(envelope)
        print("Encryption: AES-256-GCM")
        print("Password derivation: PBKDF2-HMAC-SHA256 (240,000 iterations)")


def validate_decrypted(plaintext: bytes) -> None:
    # The plaintext contains device pairings and keys: NEVER print or save it.
    try:
        data = json.loads(plaintext.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise InvalidBackup("Password authenticated but backup data is invalid.") from None
    if not isinstance(data, dict) or type(data.get("schema")) is not int or data["schema"] != VERSION:
        raise InvalidBackup("Password authenticated but backup schema is invalid.")
    items = data.get("items")
    if not isinstance(items, dict) or not 1 <= len(items) <= MAX_KEYS or any(
            not isinstance(k, str) or not isinstance(v, str) for k, v in items.items()):
        raise InvalidBackup("Password authenticated but backup entries are invalid.")


def verify_password(envelope: dict) -> int:
    if envelope["format"] == UNPROTECTED:
        print("NO PASSWORD: this backup is unencrypted. No password to check.")
        return 0
    salt, nonce, mac, ciphertext = encrypted_parts(envelope)
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.exceptions import InvalidTag
    except ImportError:
        print("Missing Python package: cryptography", file=sys.stderr)
        print("Install it for your Python environment, then rerun this script:", file=sys.stderr)
        print("  python3 -m pip install cryptography", file=sys.stderr)
        return 2
    try:
        password = getpass.getpass("TapTether backup password (hidden): ")
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled. No backup data changed.", file=sys.stderr)
        return 2
    if not password:
        print("NO MATCH: no password entered. The backup was not modified.")
        return 1
    secret_key = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, ITERATIONS, dklen=32)
    # Avoid retaining an extra reference to the password string after derivation.
    password = None
    try:
        plaintext = AESGCM(secret_key).decrypt(nonce, ciphertext + mac, ENCRYPTED.encode("utf-8"))
    except InvalidTag:
        print("NO MATCH: incorrect password OR modified/corrupt backup. No data was restored.")
        return 1
    validate_decrypted(plaintext)
    print("SUCCESS: correct password — backup authenticated; no data displayed or restored.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Check a TapTether backup password without restoring private data.")
    parser.add_argument("--info", action="store_true", help="Show backup metadata only; do not prompt for a password")
    parser.add_argument("backup", type=Path, help="Path to a .ttbackup file")
    args = parser.parse_args()
    try:
        envelope = read_envelope(args.backup.expanduser())
        if args.info:
            show_info(envelope)
            return 0
        return verify_password(envelope)
    except InvalidBackup as exc:
        print(f"INVALID BACKUP: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
