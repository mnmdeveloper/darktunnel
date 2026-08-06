from __future__ import annotations

from urllib.parse import quote

from .config import get_settings


def public_activation_link(token: str) -> str:
    base = get_settings().public_api_url.rstrip("/")
    return f"{base}/activate/{quote(token, safe='')}"


def app_activation_link(token: str) -> str:
    return f"darktunnel://activate?d={quote(token, safe='')}"
