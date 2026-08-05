import base64
import binascii
import json
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .config import get_settings


def _decode_key(raw: str) -> bytes:
    normalized = "".join(raw.strip().strip('"').strip("'").split())
    if not normalized:
        raise RuntimeError("SERVER_CONFIG_ENCRYPTION_KEY is not configured")

    candidates = [normalized]
    if "-" in normalized or "_" in normalized:
        candidates.append(normalized.replace("-", "+").replace("_", "/"))

    for candidate in candidates:
        try:
            padded = candidate + "=" * (-len(candidate) % 4)
            key = base64.b64decode(padded, validate=True)
            if len(key) == 32:
                return key
        except (binascii.Error, ValueError):
            continue

    raise RuntimeError("SERVER_CONFIG_ENCRYPTION_KEY is invalid; generate a new 32-byte base64 key")


def _master_key() -> bytes:
    return _decode_key(get_settings().server_config_encryption_key)


def encrypt_server_config(payload: dict[str, object]) -> str:
    data_key = AESGCM.generate_key(bit_length=256)
    data_nonce = os.urandom(12)
    key_nonce = os.urandom(12)
    plaintext = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ciphertext = AESGCM(data_key).encrypt(data_nonce, plaintext, b"darktunnel-server-config-v1")
    wrapped_key = AESGCM(_master_key()).encrypt(key_nonce, data_key, b"darktunnel-data-key-v1")
    container = {
        "v": 1,
        "kn": base64.urlsafe_b64encode(key_nonce).decode().rstrip("="),
        "wk": base64.urlsafe_b64encode(wrapped_key).decode().rstrip("="),
        "dn": base64.urlsafe_b64encode(data_nonce).decode().rstrip("="),
        "ct": base64.urlsafe_b64encode(ciphertext).decode().rstrip("="),
    }
    return json.dumps(container, separators=(",", ":"))


def decrypt_server_config(value: str) -> dict[str, object]:
    container = json.loads(value)
    if container.get("v") != 1:
        raise ValueError("Unsupported server config version")

    def decode(name: str) -> bytes:
        raw = str(container[name])
        return base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))

    data_key = AESGCM(_master_key()).decrypt(decode("kn"), decode("wk"), b"darktunnel-data-key-v1")
    plaintext = AESGCM(data_key).decrypt(decode("dn"), decode("ct"), b"darktunnel-server-config-v1")
    result = json.loads(plaintext)
    if not isinstance(result, dict):
        raise ValueError("Invalid server config")
    return result
