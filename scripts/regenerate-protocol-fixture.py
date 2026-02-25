#!/usr/bin/env python3
"""Regenerate the protocol fixture with cliprelay-v1 crypto strings."""
import hashlib
import hmac
import json
import base64
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

TOKEN_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
TX_ID = "11111111-2222-3333-4444-555555555555"
MAX_CHUNK_PAYLOAD = 509
AAD = b"cliprelay-v1"
INFO_ENC = "cliprelay-enc-v1"


def hex_to_bytes(hex_str: str) -> bytes:
    return bytes.fromhex(hex_str)


def hkdf(ikm: bytes, info: str, length: int) -> bytes:
    """HKDF-Extract-Expand with zero salt."""
    # Extract: PRK = HMAC-SHA256(salt=zeros, IKM)
    salt = b"\x00" * 32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    # Expand
    info_bytes = info.encode("utf-8")
    okm = b""
    t = b""
    for i in range(1, 256):
        t = hmac.new(prk, t + info_bytes + bytes([i]), hashlib.sha256).digest()
        okm += t
        if len(okm) >= length:
            break
    return okm[:length]


def chunk_data(data: bytes) -> list[bytes]:
    """Split data into chunk frames (2-byte index + payload)."""
    frames = []
    for i in range((len(data) + MAX_CHUNK_PAYLOAD - 1) // MAX_CHUNK_PAYLOAD):
        start = i * MAX_CHUNK_PAYLOAD
        end = min(start + MAX_CHUNK_PAYLOAD, len(data))
        payload = data[start:end]
        prefix = bytes([(i >> 8) & 0xFF, i & 0xFF])
        frames.append(prefix + payload)
    return frames


def main():
    token_bytes = hex_to_bytes(TOKEN_HEX)
    key_bytes = hkdf(token_bytes, INFO_ENC, 32)
    key = AESGCM(key_bytes)

    # Create 1280-byte plaintext (same size as original)
    chunk = "ClipRelay fixture payload v1 | "
    plaintext = (chunk * (1280 // len(chunk) + 1))[:1280].encode("utf-8")

    nonce = os.urandom(12)
    encrypted = key.encrypt(nonce, plaintext, AAD)
    encrypted_blob = nonce + encrypted

    plaintext_sha = hashlib.sha256(plaintext).hexdigest()
    encrypted_sha = hashlib.sha256(encrypted_blob).hexdigest()

    frames = chunk_data(encrypted_blob)
    total_chunks = len(frames)

    fixture = {
        "fixture_id": "interop-v1-basic",
        "version": 1,
        "tx_id": TX_ID,
        "token_hex": TOKEN_HEX,
        "plaintext_base64": base64.b64encode(plaintext).decode("ascii"),
        "plaintext_sha256_hex": plaintext_sha,
        "encrypted_blob_hex": encrypted_blob.hex(),
        "encrypted_sha256_hex": encrypted_sha,
        "total_chunks": total_chunks,
        "chunk_frames_hex": [f.hex() for f in frames],
    }

    script_dir = os.path.dirname(os.path.abspath(__file__))
    fixture_path = os.path.join(script_dir, "..", "test-fixtures", "protocol", "v1", "interop_fixture_v1.json")
    with open(fixture_path, "w") as f:
        json.dump(fixture, f, indent=2)

    print(f"Regenerated fixture at {fixture_path}")


if __name__ == "__main__":
    main()
