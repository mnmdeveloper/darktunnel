from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

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


app = FastAPI(title="DarkTunnel Backend", version="0.2.0", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/status")
async def status() -> dict[str, object]:
    settings = get_settings()
    return {
        "status": "ok",
        "environment": settings.environment,
        "wdtt": {"host": settings.wdtt_public_host, "port": settings.wdtt_public_port},
    }


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
