from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timezone

from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import ServerHealth, ServerNode, ServerTransport
from .server_crypto import decrypt_server_config, encrypt_server_config


class TransportReport(BaseModel):
    type: str
    enabled: bool = True
    detected: bool = False
    healthy: bool = False
    host: str = ""
    port: int | None = Field(default=None, ge=1, le=65535)
    interface: str = ""
    version: str = ""
    details: dict[str, object] = Field(default_factory=dict)


class NodeReport(BaseModel):
    hostname: str = ""
    agent_version: str = ""
    transports: list[TransportReport] = Field(default_factory=list)
    online: bool = True
    latency_ms: int | None = Field(default=None, ge=0)
    load_percent: float | None = Field(default=None, ge=0, le=100)
    active_users: int = Field(default=0, ge=0)
    active_connections: int = Field(default=0, ge=0)
    rx_bytes: int = Field(default=0, ge=0)
    tx_bytes: int = Field(default=0, ge=0)
    uptime_seconds: int = Field(default=0, ge=0)
    error_code: str = ""


def generate_agent_token() -> str:
    return secrets.token_urlsafe(48)


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def put_agent_token(config_value: str, token: str) -> str:
    config = decrypt_server_config(config_value)
    config["node_agent_token_hash"] = token_hash(token)
    return encrypt_server_config(config)


def check_agent_token(config_value: str, token: str) -> bool:
    try:
        config = decrypt_server_config(config_value)
        expected = str(config.get("node_agent_token_hash", ""))
    except Exception:
        return False
    return bool(expected) and secrets.compare_digest(expected, token_hash(token))


async def apply_report(session: AsyncSession, node: ServerNode, report: NodeReport) -> None:
    now = datetime.now(timezone.utc)
    node.updated_at = now

    for item in report.transports:
        if item.type not in {"wdtt", "vkturn", "amneziawg2"}:
            continue
        row = await session.scalar(
            select(ServerTransport).where(
                ServerTransport.server_id == node.id,
                ServerTransport.transport_type == item.type,
            )
        )
        if row is None:
            row = ServerTransport(
                id=uuid.uuid4(),
                server_id=node.id,
                transport_type=item.type,
            )
            session.add(row)
        row.enabled = item.enabled
        row.detected = item.detected
        row.healthy = item.healthy
        row.host = item.host or node.host
        row.port = item.port
        row.interface_name = item.interface
        row.version = item.version
        row.details_json = item.model_dump_json(indent=None)
        row.last_seen_at = now

    session.add(
        ServerHealth(
            server_id=node.id,
            timestamp=now,
            online=report.online,
            latency_ms=report.latency_ms,
            load_percent=report.load_percent,
            active_users=report.active_users,
            active_connections=report.active_connections,
            rx_bytes=report.rx_bytes,
            tx_bytes=report.tx_bytes,
            uptime_seconds=report.uptime_seconds,
            version=report.agent_version,
            error_code=report.error_code,
        )
    )
    await session.commit()
