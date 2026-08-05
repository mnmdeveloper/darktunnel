from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from .client_config import published_servers, recommended_server, server_payload
from .config import get_settings
from .db import get_session, init_db
from .schemas import ActivationCreate, ActivationCreated, ActivationRedeem, ActivationResult
from .services import create_activation, redeem_activation


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.settings = settings
    await init_db()
    yield


app = FastAPI(title="DarkTunnel Backend", version="0.3.0", lifespan=lifespan)


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


def require_owner(x_admin_id: int = Header(alias="X-Admin-ID")) -> int:
    if x_admin_id != get_settings().telegram_owner_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    return x_admin_id


@app.post("/v1/admin/activations", response_model=ActivationCreated)
async def admin_create_activation(
    body: ActivationCreate,
    session: AsyncSession = Depends(get_session),
    admin_id: int = Depends(require_owner),
) -> ActivationCreated:
    body.created_by = admin_id
    activation, token = await create_activation(session, body)
    return ActivationCreated(
        activation_id=str(activation.id),
        activation_link=f"darktunnel://activate?d={token}",
        link_expires_at=activation.link_expires_at,
    )


@app.post("/v1/activation/redeem", response_model=ActivationResult)
async def activation_redeem(
    body: ActivationRedeem,
    session: AsyncSession = Depends(get_session),
) -> ActivationResult:
    try:
        return await redeem_activation(session, body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
