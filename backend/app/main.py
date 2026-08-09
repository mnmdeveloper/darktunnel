from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .admin_management import router as admin_management_router
from .client_config import published_servers, recommended_server, server_payload
from .config import get_settings
from .db import get_session, init_db
from .models import Activation, Announcement, Device, ServerNode
from .node_agent import NodeReport, apply_report, check_agent_token, generate_agent_token, put_agent_token
from .schemas import ActivationCreate, ActivationCreated, ActivationRedeem, ActivationResult
from .security import decode_activation_token, hash_token
from .server_crypto import decrypt_server_config
from .server_profile import get_server_profile, profile_payload
from .services import create_activation, redeem_activation


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.settings = settings
    await init_db()
    yield


app = FastAPI(title="DarkTunnel Backend", version="0.5.0", lifespan=lifespan)
app.include_router(admin_management_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/status")
async def status(session: AsyncSession = Depends(get_session)) -> dict[str, object]:
    servers = await published_servers(session)
    return {
        "status": "ok",
        "environment": get_settings().environment,
        "published_servers": len(servers),
        "online_servers": sum(1 for server in servers if server.online),
    }


@app.get("/v1/servers")
async def client_servers(session: AsyncSession = Depends(get_session)) -> dict[str, object]:
    servers = await published_servers(session)
    return {"servers": [server_payload(server) for server in servers]}


@app.get("/v1/servers/recommended")
async def client_recommended_server(session: AsyncSession = Depends(get_session)) -> dict[str, object]:
    servers = await published_servers(session)
    server = recommended_server(servers)
    if server is None:
        raise HTTPException(status_code=503, detail="No published servers available")
    return server_payload(server)


@app.get("/v1/announcements")
async def client_announcements(session: AsyncSession = Depends(get_session)) -> dict[str, object]:
    rows = (
        await session.execute(
            select(Announcement)
            .where(Announcement.active.is_(True))
            .order_by(Announcement.created_at.desc())
            .limit(10)
        )
    ).scalars().all()
    return {
        "announcements": [
            {
                "id": str(row.id),
                "title": row.title,
                "body": row.body,
                "placement": row.placement,
                "created_at": row.created_at.isoformat(),
            }
            for row in rows
        ]
    }


@app.get("/v1/activation/server-profile")
async def activation_server_profile(
    token: str,
    installation_id: str,
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    try:
        payload = decode_activation_token(token)
        activation_id = str(payload["activation_id"])
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Invalid activation token") from exc

    activation = await session.scalar(select(Activation).where(Activation.id == activation_id))
    now = __import__("datetime").datetime.now(__import__("datetime").UTC)
    if activation is None or activation.token_hash != hash_token(token) or activation.revoked_at is not None or activation.link_expires_at < now:
        raise HTTPException(status_code=401, detail="Activation token unavailable")

    device = await session.scalar(select(Device).where(Device.installation_id == installation_id, Device.user_id.is_not(None)))
    if device is None:
        raise HTTPException(status_code=401, detail="Device not activated")

    settings = get_settings()
    node = await session.scalar(select(ServerNode).where(ServerNode.host == settings.wdtt_public_host, ServerNode.archived_at.is_(None)))
    if node is None:
        raise HTTPException(status_code=503, detail="Primary server unavailable")
    try:
        config = decrypt_server_config(node.encrypted_config)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Server configuration unavailable") from exc

    return {
        "server": {
            "id": str(node.id),
            "name": node.name,
            "country_code": node.country_code,
            "country_name": node.country_name,
            "city": node.city,
            "latitude": node.latitude,
            "longitude": node.longitude,
            "host": node.host,
            "port": node.port,
            "mode": node.protocol_mode,
            "wrap_a_password": str(config.get("wrap_a_password", "")),
            "connections_balanced": node.balanced_connections,
            "connections_maximum": node.max_connections,
            "mtu": node.mtu,
            "dns": node.dns,
            "amnezia_config": str(config.get("awg_client_config", "")) or None,
        }
    }


def require_owner(x_admin_id: int = Header(alias="X-Admin-ID")) -> int:
    if x_admin_id != get_settings().telegram_owner_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    return x_admin_id


async def get_server(session: AsyncSession, server_id: str) -> ServerNode:
    try:
        server = await session.scalar(select(ServerNode).where(ServerNode.id == server_id))
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid server id") from exc
    if server is None:
        raise HTTPException(status_code=404, detail="Server not found")
    return server


@app.get("/v1/admin/servers/{server_id}/profile")
async def admin_server_profile(server_id: str, session: AsyncSession = Depends(get_session), admin_id: int = Depends(require_owner)) -> dict[str, object]:
    _ = admin_id
    profile = await get_server_profile(session, server_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="Server not found")
    return profile_payload(profile)


@app.post("/v1/admin/servers/{server_id}/agent-token")
async def admin_issue_agent_token(server_id: str, session: AsyncSession = Depends(get_session), admin_id: int = Depends(require_owner)) -> dict[str, str]:
    _ = admin_id
    server = await get_server(session, server_id)
    token = generate_agent_token()
    try:
        server.encrypted_config = put_agent_token(server.encrypted_config, token)
    except Exception as exc:
        raise HTTPException(status_code=500, detail="Server config encryption is unavailable") from exc
    await session.commit()
    return {"server_id": str(server.id), "node_agent_token": token}


@app.post("/v1/node/{server_id}/report")
async def node_report(server_id: str, body: NodeReport, x_node_token: str = Header(alias="X-Node-Token"), session: AsyncSession = Depends(get_session)) -> dict[str, object]:
    server = await get_server(session, server_id)
    if not x_node_token or not check_agent_token(server.encrypted_config, x_node_token):
        raise HTTPException(status_code=401, detail="Invalid node token")
    await apply_report(session, server, body)
    return {"status": "ok", "server_id": str(server.id)}


@app.post("/v1/admin/activations", response_model=ActivationCreated)
async def admin_create_activation(body: ActivationCreate, session: AsyncSession = Depends(get_session), admin_id: int = Depends(require_owner)) -> ActivationCreated:
    body.created_by = admin_id
    activation, token = await create_activation(session, body)
    return ActivationCreated(activation_id=str(activation.id), activation_link=f"darktunnel://activate?d={token}", link_expires_at=activation.link_expires_at)


@app.post("/v1/activation/redeem", response_model=ActivationResult)
async def activation_redeem(body: ActivationRedeem, session: AsyncSession = Depends(get_session)) -> ActivationResult:
    try:
        return await redeem_activation(session, body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
