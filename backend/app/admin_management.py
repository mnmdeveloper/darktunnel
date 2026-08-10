from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Annotated
import uuid

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import String, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .config import get_settings
from .db import get_session
from .models import Activation, Announcement, AuditLog, Device, User, UserStatus
from .schemas import AnnouncementCreate, AnnouncementPatch

router = APIRouter(prefix="/v1/admin", tags=["admin-management"])


def require_owner(x_admin_id: Annotated[int, Header(alias="X-Admin-ID")]) -> int:
    if x_admin_id != get_settings().telegram_owner_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    return x_admin_id


class ExtendBody(BaseModel):
    days: int = Field(ge=-3650, le=3650)


class UserPatch(BaseModel):
    note: str | None = Field(default=None, max_length=500)
    telegram_id: int | None = None
    blocked: bool | None = None
    lifetime: bool | None = None
    subscription_expires_at: datetime | None = None


def user_payload(user: User) -> dict[str, object]:
    devices = list(user.devices or [])
    return {
        "id": str(user.id), "status": user.status.value, "telegram_id": user.telegram_id, "note": user.note,
        "activated_at": user.activated_at, "subscription_expires_at": user.subscription_expires_at, "lifetime": user.lifetime,
        "created_at": user.created_at,
        "devices": [{
            "id": str(device.id), "installation_id_suffix": device.installation_id[-8:], "app_version": device.app_version,
            "ios_version": device.ios_version, "created_at": device.created_at, "last_seen_at": device.last_seen_at, "revoked_at": device.revoked_at,
        } for device in devices],
    }


def activation_payload(row: Activation) -> dict[str, object]:
    now = datetime.now(UTC)
    status = "revoked" if row.revoked_at else "expired" if row.link_expires_at <= now else "used" if row.uses >= row.max_uses else "ready"
    return {
        "id": str(row.id), "status": status, "duration_days": row.duration_days, "max_devices": row.max_devices,
        "max_uses": row.max_uses, "uses": row.uses, "link_expires_at": row.link_expires_at, "telegram_id": row.telegram_id,
        "note": row.note, "created_by": row.created_by, "created_at": row.created_at, "revoked_at": row.revoked_at,
        "user_id": str(row.user_id) if row.user_id else None,
    }


def announcement_payload(row: Announcement) -> dict[str, object]:
    return {
        "id": str(row.id), "title": row.title, "body": row.body, "placement": row.placement,
        "color_hex": row.color_hex, "active": row.active, "created_by": row.created_by, "created_at": row.created_at,
    }


@router.get("/users")
async def users(q: str = Query(default="", max_length=128), status: str = Query(default="all", pattern="^(all|active|expired|blocked)$"), page: int = Query(default=1, ge=1), page_size: int = Query(default=25, ge=1, le=100), session: AsyncSession = Depends(get_session), _: int = Depends(require_owner)) -> dict[str, object]:
    conditions = []
    now = datetime.now(UTC)
    if status == "active": conditions += [User.status == UserStatus.active, or_(User.lifetime.is_(True), User.subscription_expires_at > now)]
    elif status == "expired": conditions += [User.lifetime.is_(False), or_(User.subscription_expires_at.is_(None), User.subscription_expires_at <= now)]
    elif status == "blocked": conditions += [User.status == UserStatus.blocked]
    if q:
        terms = [User.note.ilike(f"%{q}%"), func.cast(User.id, String).ilike(f"%{q}%")]
        if q.isdigit(): terms.append(User.telegram_id == int(q))
        device_users = select(Device.user_id).where(or_(Device.installation_id.ilike(f"%{q}%"), func.cast(Device.id, String).ilike(f"%{q}%")))
        conditions.append(or_(*terms, User.id.in_(device_users)))
    total = int(await session.scalar(select(func.count(User.id)).where(*conditions)) or 0)
    rows = (await session.execute(select(User).where(*conditions).options(selectinload(User.devices)).order_by(User.created_at.desc()).offset((page - 1) * page_size).limit(page_size))).scalars().all()
    return {"items": [user_payload(row) for row in rows], "total": total, "page": page, "page_size": page_size}


@router.get("/users/{user_id}")
async def user_detail(user_id: uuid.UUID, session: AsyncSession = Depends(get_session), _: int = Depends(require_owner)) -> dict[str, object]:
    user = await session.scalar(select(User).where(User.id == user_id).options(selectinload(User.devices)))
    if user is None: raise HTTPException(status_code=404, detail="User not found")
    return user_payload(user)


@router.patch("/users/{user_id}")
async def patch_user(user_id: uuid.UUID, body: UserPatch, session: AsyncSession = Depends(get_session), admin: int = Depends(require_owner)) -> dict[str, object]:
    user = await session.scalar(select(User).where(User.id == user_id).options(selectinload(User.devices)))
    if user is None: raise HTTPException(status_code=404, detail="User not found")
    if body.note is not None: user.note = body.note
    if body.telegram_id is not None: user.telegram_id = body.telegram_id
    if body.blocked is not None: user.status = UserStatus.blocked if body.blocked else UserStatus.active
    if body.lifetime is not None: user.lifetime = body.lifetime
    if body.subscription_expires_at is not None: user.subscription_expires_at = body.subscription_expires_at; user.lifetime = False
    session.add(AuditLog(admin_id=admin, action="user.patch", entity_type="user", entity_id=str(user.id)))
    await session.commit(); await session.refresh(user)
    return user_payload(user)


@router.post("/users/{user_id}/extend")
async def extend_user(user_id: uuid.UUID, body: ExtendBody, session: AsyncSession = Depends(get_session), admin: int = Depends(require_owner)) -> dict[str, object]:
    if body.days == 0: raise HTTPException(status_code=400, detail="days must not be zero")
    user = await session.scalar(select(User).where(User.id == user_id).options(selectinload(User.devices)))
    if user is None: raise HTTPException(status_code=404, detail="User not found")
    base = user.subscription_expires_at or datetime.now(UTC)
    user.subscription_expires_at = max(datetime.now(UTC), base + timedelta(days=body.days)); user.lifetime = False
    session.add(AuditLog(admin_id=admin, action=f"user.days.{body.days}", entity_type="user", entity_id=str(user.id)))
    await session.commit(); return user_payload(user)


@router.post("/users/{user_id}/reset-devices")
async def reset_devices(user_id: uuid.UUID, session: AsyncSession = Depends(get_session), admin: int = Depends(require_owner)) -> dict[str, int]:
    devices = (await session.execute(select(Device).where(Device.user_id == user_id, Device.revoked_at.is_(None)))).scalars().all()
    now = datetime.now(UTC)
    for device in devices: device.revoked_at = now
    session.add(AuditLog(admin_id=admin, action="user.devices.reset", entity_type="user", entity_id=str(user_id)))
    await session.commit(); return {"revoked_devices": len(devices)}


@router.get("/activations")
async def activations(q: str = Query(default="", max_length=128), status: str = Query(default="all", pattern="^(all|ready|used|expired|revoked)$"), page: int = Query(default=1, ge=1), page_size: int = Query(default=25, ge=1, le=100), session: AsyncSession = Depends(get_session), _: int = Depends(require_owner)) -> dict[str, object]:
    conditions = []; now = datetime.now(UTC)
    if status == "ready": conditions += [Activation.revoked_at.is_(None), Activation.link_expires_at > now, Activation.uses < Activation.max_uses]
    elif status == "used": conditions += [Activation.uses > 0]
    elif status == "expired": conditions += [Activation.link_expires_at <= now, Activation.revoked_at.is_(None)]
    elif status == "revoked": conditions += [Activation.revoked_at.is_not(None)]
    if q:
        terms = [Activation.note.ilike(f"%{q}%"), func.cast(Activation.id, String).ilike(f"%{q}%")]
        if q.isdigit(): terms.append(Activation.telegram_id == int(q))
        conditions.append(or_(*terms))
    total = int(await session.scalar(select(func.count(Activation.id)).where(*conditions)) or 0)
    rows = (await session.execute(select(Activation).where(*conditions).order_by(Activation.created_at.desc()).offset((page - 1) * page_size).limit(page_size))).scalars().all()
    return {"items": [activation_payload(row) for row in rows], "total": total, "page": page, "page_size": page_size}


@router.post("/activations/{activation_id}/revoke")
async def revoke_activation(activation_id: uuid.UUID, session: AsyncSession = Depends(get_session), admin: int = Depends(require_owner)) -> dict[str, object]:
    row = await session.get(Activation, activation_id)
    if row is None: raise HTTPException(status_code=404, detail="Activation not found")
    row.revoked_at = datetime.now(UTC)
    # Revoking an activation must also invalidate the already-redeemed subscription.
    if row.user_id is not None:
        user = await session.get(User, row.user_id)
        if user is not None:
            user.status = UserStatus.blocked
            for device in (await session.execute(select(Device).where(Device.user_id == user.id, Device.revoked_at.is_(None)))).scalars().all():
                device.revoked_at = datetime.now(UTC)
    session.add(AuditLog(admin_id=admin, action="activation.revoke", entity_type="activation", entity_id=str(row.id)))
    await session.commit(); return activation_payload(row)


@router.get("/announcements")
async def announcements(session: AsyncSession = Depends(get_session), _: int = Depends(require_owner)) -> dict[str, object]:
    rows = (await session.execute(select(Announcement).order_by(Announcement.created_at.desc()).limit(100))).scalars().all()
    return {"items": [announcement_payload(row) for row in rows]}


@router.post("/announcements")
async def create_announcement(body: AnnouncementCreate, session: AsyncSession = Depends(get_session), admin: int = Depends(require_owner)) -> dict[str, object]:
    row = Announcement(title=body.title, body=body.body, placement=body.placement, color_hex=body.color_hex.upper(), created_by=admin)
    session.add(row)
    session.add(AuditLog(admin_id=admin, action="announcement.create", entity_type="announcement", entity_id=str(row.id)))
    await session.commit(); await session.refresh(row)
    return announcement_payload(row)


@router.patch("/announcements/{announcement_id}")
async def patch_announcement(announcement_id: uuid.UUID, body: AnnouncementPatch, session: AsyncSession = Depends(get_session), admin: int = Depends(require_owner)) -> dict[str, object]:
    row = await session.get(Announcement, announcement_id)
    if row is None: raise HTTPException(status_code=404, detail="Announcement not found")
    if body.title is not None: row.title = body.title
    if body.body is not None: row.body = body.body
    if body.placement is not None: row.placement = body.placement
    if body.color_hex is not None: row.color_hex = body.color_hex.upper()
    if body.active is not None: row.active = body.active
    session.add(AuditLog(admin_id=admin, action="announcement.patch", entity_type="announcement", entity_id=str(row.id)))
    await session.commit(); await session.refresh(row)
    return announcement_payload(row)
