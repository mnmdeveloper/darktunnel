from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import ServerHealth, ServerNode
from .server_crypto import decrypt_server_config


@dataclass(slots=True)
class ClientServer:
    id: str
    name: str
    country_code: str
    country_name: str
    city: str
    latitude: float | None
    longitude: float | None
    host: str
    port: int
    protocol_mode: str
    mtu: int
    dns: str
    balanced_connections: int
    max_connections: int
    latency_ms: int | None
    online: bool
    config: dict[str, object]


async def published_servers(session: AsyncSession) -> list[ClientServer]:
    rows = (
        await session.execute(
            select(ServerNode)
            .where(
                ServerNode.published.is_(True),
                ServerNode.maintenance.is_(False),
                ServerNode.archived_at.is_(None),
            )
            .order_by(ServerNode.created_at.asc())
        )
    ).scalars().all()

    result: list[ClientServer] = []
    for node in rows:
        health = await session.scalar(
            select(ServerHealth)
            .where(ServerHealth.server_id == node.id)
            .order_by(ServerHealth.timestamp.desc())
            .limit(1)
        )
        try:
            config = decrypt_server_config(node.encrypted_config)
        except Exception:
            continue
        result.append(
            ClientServer(
                id=str(node.id),
                name=node.name,
                country_code=node.country_code,
                country_name=node.country_name,
                city=node.city,
                latitude=node.latitude,
                longitude=node.longitude,
                host=node.host,
                port=node.port,
                protocol_mode=node.protocol_mode,
                mtu=node.mtu,
                dns=node.dns,
                balanced_connections=node.balanced_connections,
                max_connections=node.max_connections,
                latency_ms=health.latency_ms if health else None,
                online=bool(health.online) if health else True,
                config=config,
            )
        )
    return result


def server_payload(server: ClientServer) -> dict[str, object]:
    return {
        "id": server.id,
        "name": server.name,
        "country_code": server.country_code,
        "country_name": server.country_name,
        "city": server.city,
        "latitude": server.latitude,
        "longitude": server.longitude,
        "host": server.host,
        "port": server.port,
        "mode": server.protocol_mode,
        "wrap_a_password": str(server.config.get("wrap_a_password", "")),
        "connections_balanced": server.balanced_connections,
        "connections_maximum": server.max_connections,
        "mtu": server.mtu,
        "dns": server.dns,
        "latency_ms": server.latency_ms,
        "online": server.online,
    }


def recommended_server(servers: list[ClientServer]) -> ClientServer | None:
    candidates = [server for server in servers if server.online]
    if not candidates:
        candidates = servers
    if not candidates:
        return None
    return min(candidates, key=lambda server: server.latency_ms if server.latency_ms is not None else 999_999)
