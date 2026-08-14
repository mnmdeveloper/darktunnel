from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .db import get_session
from .models import Device, ServerHealth, ServerNode, User, UserStatus
from .security import hash_token
from .server_crypto import decrypt_server_config
from .subscription_access import create_subscription_access, resolve_subscription_access, make_access_link

router = APIRouter(prefix="/v1")


def _validate_user(user: User | None) -> User:
    if user is None or user.status == UserStatus.blocked:
        raise HTTPException(status_code=403, detail="Subscription blocked")
    now = datetime.now(UTC)
    if not user.lifetime and (user.subscription_expires_at is None or user.subscription_expires_at <= now):
        raise HTTPException(status_code=403, detail="Subscription expired")
    return user


async def _device_user(
    installation_id: str,
    x_device_token: str | None,
    session: AsyncSession,
) -> tuple[Device, User]:
    if not installation_id or not x_device_token:
        raise HTTPException(status_code=401, detail="Device authentication required")
    device = await session.scalar(select(Device).where(
        Device.installation_id == installation_id,
        Device.auth_token_hash == hash_token(x_device_token),
        Device.revoked_at.is_(None),
    ))
    if device is None:
        raise HTTPException(status_code=401, detail="Device authentication unavailable")
    user = _validate_user(await session.get(User, device.user_id))
    device.last_seen_at = datetime.now(UTC)
    return device, user


async def _server_config(session: AsyncSession, node: ServerNode) -> dict[str, object]:
    try:
        config = decrypt_server_config(node.encrypted_config)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Server configuration unavailable") from exc
    return config


def _server_payload(node: ServerNode, config: dict[str, object], health: ServerHealth | None) -> dict[str, object]:
    awg = str(config.get("awg_client_config", "")).strip()
    return {
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
        "latency_ms": health.latency_ms if health else None,
        "online": bool(health.online) if health else True,
        "amnezia_config": awg or None,
    }


@router.post("/subscription/access/redeem")
async def redeem_subscription_access(
    body: dict[str, str],
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    """Exchange a subscription access link for a device token used by the app."""
    token = str(body.get("token", "")).strip()
    installation_id = str(body.get("installation_id", "")).strip()
    public_key = str(body.get("public_key", "")).strip()
    if not token or not installation_id or not public_key:
        raise HTTPException(status_code=400, detail="Некорректная ссылка подписки или данные устройства")

    _, user = await resolve_subscription_access(session, token)
    user = _validate_user(user)
    now = datetime.now(UTC)

    device = await session.scalar(select(Device).where(Device.installation_id == installation_id).with_for_update())
    if device is not None and device.user_id != user.id:
        raise HTTPException(status_code=409, detail="Это устройство уже привязано к другой подписке")

    if device is None:
        device = Device(
            user_id=user.id,
            installation_id=installation_id,
            public_key=public_key,
            app_version=str(body.get("app_version", "")),
            ios_version=str(body.get("android_version", "")),
            last_seen_at=now,
        )
        session.add(device)
        await session.flush()
    else:
        device.public_key = public_key
        device.app_version = str(body.get("app_version", ""))
        device.ios_version = str(body.get("android_version", ""))
        device.revoked_at = None
        device.last_seen_at = now

    import secrets
    refresh_token = secrets.token_urlsafe(32)
    device.auth_token_hash = hash_token(refresh_token)

    settings = get_settings()
    node = await session.scalar(select(ServerNode).where(
        ServerNode.host == settings.wdtt_public_host,
        ServerNode.archived_at.is_(None),
    ))
    if node is None:
        raise HTTPException(status_code=503, detail="Основной VPN-сервер недоступен")
    config = await _server_config(session, node)
    health = await session.scalar(select(ServerHealth).where(
        ServerHealth.server_id == node.id,
    ).order_by(ServerHealth.timestamp.desc()).limit(1))

    await session.commit()
    return {
        "refresh_token": refresh_token,
        "subscription_expires_at": user.subscription_expires_at,
        "lifetime": user.lifetime,
        "user_status": user.status.value,
        "server": _server_payload(node, config, health),
    }


@router.post("/subscription/access-link")
async def create_access_link(
    installation_id: str,
    x_device_token: str | None = Header(default=None, alias="X-Device-Token"),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    _, user = await _device_user(installation_id, x_device_token, session)
    _, token = await create_subscription_access(session, user, revoke_existing=True)
    await session.commit()
    return {"subscription_link": make_access_link(token), "user_id": str(user.id)}


@router.post("/subscription/access/rotate")
async def rotate_access_link(
    token: str,
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    _, user = await resolve_subscription_access(session, token)
    _, new_token = await create_subscription_access(session, user, revoke_existing=True)
    await session.commit()
    return {"subscription_link": make_access_link(new_token), "user_id": str(user.id)}


@router.get("/subscription/access")
async def subscription_access(token: str, session: AsyncSession = Depends(get_session)) -> dict[str, object]:
    _, user = await resolve_subscription_access(session, token)
    devices = (await session.execute(
        select(Device).where(Device.user_id == user.id).order_by(Device.created_at.asc())
    )).scalars().all()
    await session.commit()
    return {
        "user_id": str(user.id),
        "status": user.status.value,
        "active": user.lifetime or bool(user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)),
        "lifetime": user.lifetime,
        "subscription_expires_at": user.subscription_expires_at,
        "telegram_id": user.telegram_id,
        "note": user.note,
        "devices": [
            {
                "id": str(device.id),
                "installation_id": device.installation_id,
                "app_version": device.app_version,
                "ios_version": device.ios_version,
                "created_at": device.created_at,
                "last_seen_at": device.last_seen_at,
                "revoked_at": device.revoked_at,
            }
            for device in devices
        ],
    }


@router.delete("/subscription/access/devices/{device_id}")
async def revoke_subscription_device(
    device_id: str,
    x_subscription_access_token: str = Header(alias="X-Subscription-Access-Token"),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    _, user = await resolve_subscription_access(session, x_subscription_access_token)
    device = await session.scalar(select(Device).where(Device.id == device_id, Device.user_id == user.id))
    if device is None:
        raise HTTPException(status_code=404, detail="Device not found")
    device.revoked_at = datetime.now(UTC)
    device.auth_token_hash = ""
    await session.commit()
    return {"status": "ok", "device_id": str(device.id)}


@router.get("/subscription/servers/{server_id}")
async def subscription_server_profile(
    server_id: str,
    installation_id: str,
    x_device_token: str | None = Header(default=None, alias="X-Device-Token"),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    await _device_user(installation_id, x_device_token, session)
    node = await session.scalar(select(ServerNode).where(
        ServerNode.id == server_id,
        ServerNode.published.is_(True),
        ServerNode.maintenance.is_(False),
        ServerNode.archived_at.is_(None),
    ))
    if node is None:
        raise HTTPException(status_code=404, detail="Server not found")
    config = await _server_config(session, node)
    if not str(config.get("awg_client_config", "")).strip():
        raise HTTPException(status_code=404, detail="AmneziaWG is not provisioned for this server")
    health = await session.scalar(select(ServerHealth).where(ServerHealth.server_id == node.id).order_by(ServerHealth.timestamp.desc()).limit(1))
    await session.commit()
    return {"server": _server_payload(node, config, health)}


@router.get("/subscription/servers")
async def subscription_servers(
    installation_id: str,
    x_device_token: str | None = Header(default=None, alias="X-Device-Token"),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    await _device_user(installation_id, x_device_token, session)
    nodes = (await session.execute(select(ServerNode).where(
        ServerNode.published.is_(True), ServerNode.maintenance.is_(False), ServerNode.archived_at.is_(None)
    ).order_by(ServerNode.name.asc()))).scalars().all()
    payload: list[dict[str, object]] = []
    for node in nodes:
        config = await _server_config(session, node)
        health = await session.scalar(select(ServerHealth).where(ServerHealth.server_id == node.id).order_by(ServerHealth.timestamp.desc()).limit(1))
        payload.append(_server_payload(node, config, health))
    await session.commit()
    return {"servers": payload}


@router.post("/admin/users/{user_id}/subscription-link")
async def admin_create_subscription_link(
    user_id: str,
    x_admin_id: int = Header(alias="X-Admin-ID"),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    if x_admin_id != get_settings().telegram_owner_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    _, token = await create_subscription_access(session, user, revoke_existing=True)
    await session.commit()
    return {"subscription_link": make_access_link(token), "user_id": str(user.id)}