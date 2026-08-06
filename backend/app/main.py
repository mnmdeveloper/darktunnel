from contextlib import asynccontextmanager
from html import escape

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse
from sqlalchemy.ext.asyncio import AsyncSession

from .activation_links import app_activation_link, public_activation_link
from .admin_management import router as admin_management_router
from .client_config import published_servers, recommended_server, server_payload
from .config import get_settings
from .db import get_session, init_db
from .schemas import ActivationCreate, ActivationCreated, ActivationRedeem, ActivationResult
from .security import decode_activation_token
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


@app.get("/activate/{token}", response_class=HTMLResponse)
async def activate_entry(token: str) -> HTMLResponse:
    try:
        decode_activation_token(token)
    except Exception:
        return HTMLResponse(
            status_code=400,
            content="""<!doctype html><html lang='ru'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>DarkTunnel</title><body style='font-family:-apple-system,system-ui;padding:32px;max-width:560px;margin:auto'><h2>Ссылка недействительна</h2><p>Попросите администратора создать новую ссылку.</p></body></html>""",
        )
    deep_link = app_activation_link(token)
    safe_link = escape(deep_link, quote=True)
    html = f"""<!doctype html>
<html lang='ru'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=cover'>
<title>DarkTunnel</title>
<meta http-equiv='refresh' content='0;url={safe_link}'>
<style>
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0b0d12;color:#fff;margin:0;min-height:100vh;display:grid;place-items:center;padding:24px}}
.card{{max-width:420px;width:100%;background:#151923;border-radius:24px;padding:28px;box-sizing:border-box;text-align:center}}
a{{display:block;background:#fff;color:#111;text-decoration:none;padding:15px 18px;border-radius:14px;font-weight:700;margin-top:18px}}
p{{color:#b8bfcc;line-height:1.5}}
</style>
<script>window.location.replace({deep_link!r});</script>
</head>
<body><div class='card'><h1>DarkTunnel</h1><p>Открываем приложение и загружаем настройки автоматически.</p><a href='{safe_link}'>Открыть DarkTunnel</a></div></body>
</html>"""
    return HTMLResponse(content=html, headers={"Cache-Control": "no-store"})


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
        activation_link=public_activation_link(token),
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
