from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import ServerNode, ServerTransport
from .server_crypto import decrypt_server_config


TRANSPORT_TYPES = ("wdtt", "vkturn", "amneziawg2")


@dataclass(slots=True)
class TransportProfile:
    type: str
    enabled: bool
    detected: bool
    healthy: bool
    host: str
    port: int | None
    interface: str
    version: str
    details: dict[str, object]
    last_seen_at: datetime | None


@dataclass(slots=True)
class ServerProfile:
    id: str
    name: str
    host: str
    location: dict[str, object]
    published: bool
    auto_select: bool
    maintenance: bool
    transports: list[TransportProfile]


async def get_server_profile(session: AsyncSession, server_id: str) -> ServerProfile | None:
    try:
        node_uuid = __import__("uuid").UUID(server_id)
    except ValueError:
        return None

    node = await session.scalar(select(ServerNode).where(ServerNode.id == node_uuid))
    if node is None:
        return None

    rows = (
        await session.execute(
            select(ServerTransport)
            .where(ServerTransport.server_id == node.id)
            .order_by(ServerTransport.transport_type.asc())
        )
    ).scalars().all()

    transports: list[TransportProfile] = []
    by_type: dict[str, ServerTransport] = {row.transport_type: row for row in rows}

    # Backward compatibility: existing nodes were created before ServerTransport.
    # Do not require a migration or an app change just to describe the already
    # working WDTT + VK Turn path. Explicit agent records override these inferred
    # values as soon as a node-agent reports them.
    config: dict[str, object] = {}
    try:
        config = decrypt_server_config(node.encrypted_config)
    except Exception:
        config = {}

    inferred: dict[str, dict[str, object]] = {
        "wdtt": {
            "enabled": True,
            "detected": True,
            "healthy": True,
            "host": node.host,
            "port": node.port,
            "interface": "wdtt0",
            "version": "",
            "details": {"mode": node.protocol_mode, "source": "server_profile_legacy"},
        },
        "vkturn": {
            "enabled": True,
            "detected": True,
            "healthy": True,
            "host": node.host,
            "port": 56100,
            "interface": "",
            "version": "",
            "details": {
                "transport": "srtp",
                "source": "server_profile_legacy",
                "wrap_a_configured": bool(config.get("wrap_a_password")),
            },
        },
    }

    for transport_type in TRANSPORT_TYPES:
        row = by_type.get(transport_type)
        if row is not None:
            try:
                details = json.loads(row.details_json or "{}")
                if not isinstance(details, dict):
                    details = {}
            except Exception:
                details = {}
            transports.append(
                TransportProfile(
                    type=row.transport_type,
                    enabled=row.enabled,
                    detected=row.detected,
                    healthy=row.healthy,
                    host=row.host,
                    port=row.port,
                    interface=row.interface_name,
                    version=row.version,
                    details=details,
                    last_seen_at=row.last_seen_at,
                )
            )
            continue

        item = inferred.get(transport_type)
        if item is None:
            # AmneziaWG is deliberately not inferred. Its presence must be
            # positively reported by the node-agent; WDTT + VK Turn remain the
            # minimum server-side stack.
            continue
        transports.append(
            TransportProfile(
                type=transport_type,
                enabled=bool(item["enabled"]),
                detected=bool(item["detected"]),
                healthy=bool(item["healthy"]),
                host=str(item["host"]),
                port=int(item["port"]) if item["port"] is not None else None,
                interface=str(item["interface"]),
                version=str(item["version"]),
                details=dict(item["details"]),
                last_seen_at=None,
            )
        )

    return ServerProfile(
        id=str(node.id),
        name=node.name,
        host=node.host,
        location={
            "country_code": node.country_code,
            "country_name": node.country_name,
            "city": node.city,
            "latitude": node.latitude,
            "longitude": node.longitude,
        },
        published=node.published,
        auto_select=node.auto_select,
        maintenance=node.maintenance,
        transports=transports,
    )


def profile_payload(profile: ServerProfile) -> dict[str, object]:
    return {
        "id": profile.id,
        "name": profile.name,
        "host": profile.host,
        "location": profile.location,
        "published": profile.published,
        "auto_select": profile.auto_select,
        "maintenance": profile.maintenance,
        "transports": [
            {
                "type": item.type,
                "enabled": item.enabled,
                "detected": item.detected,
                "healthy": item.healthy,
                "host": item.host,
                "port": item.port,
                "interface": item.interface,
                "version": item.version,
                "details": item.details,
                "last_seen_at": item.last_seen_at.isoformat() if item.last_seen_at else None,
            }
            for item in profile.transports
        ],
    }
