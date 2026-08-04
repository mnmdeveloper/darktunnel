import base64
import hashlib
import json
import secrets
from datetime import UTC, datetime

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .config import get_settings


def _key() -> bytes:
    raw = get_settings().activation_encryption_key
    try:
        key = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
    except Exception as exc:
        raise RuntimeError("ACTIVATION_ENCRYPTION_KEY must be base64url") from exc
    if len(key) != 32:
        raise RuntimeError("ACTIVATION_ENCRYPTION_KEY must decode to 32 bytes")
    return key


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_activation_token(activation_id: str, expires_at: datetime) -> str:
    nonce = secrets.token_bytes(12)
    payload = json.dumps(
        {
            "v": 1,
            "activation_id": activation_id,
            "issued_at": int(datetime.now(UTC).timestamp()),
            "expires_at": int(expires_at.timestamp()),
        },
        separators=(",", ":"),
    ).encode("utf-8")
    encrypted = AESGCM(_key()).encrypt(nonce, payload, b"darktunnel-activation-v1")
    return base64.urlsafe_b64encode(nonce + encrypted).decode("ascii").rstrip("=")


def decode_activation_token(token: str) -> dict[str, object]:
    raw = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
    if len(raw) < 29:
        raise ValueError("Invalid activation token")
    payload = AESGCM(_key()).decrypt(raw[:12], raw[12:], b"darktunnel-activation-v1")
    data = json.loads(payload)
    if int(data["expires_at"]) < int(datetime.now(UTC).timestamp()):
        raise ValueError("Activation link expired")
    return data


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)
