from __future__ import annotations

import secrets
from datetime import UTC, datetime

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import SubscriptionAccess, User, UserStatus
from .security import hash_token


ACCESS_SCHEME = "darktunnel://subscription?t="


def make_access_link(token: str) -> str:
    return ACCESS_SCHEME + token


async def create_subscription_access(
    session: AsyncSession,
    user: User,
    *,
    revoke_existing: bool = True,
) -> tuple[SubscriptionAccess, str]:
    if user.status == UserStatus.blocked:
        raise ValueError("Subscription blocked")
    now = datetime.now(UTC)
    if not user.lifetime and (user.subscription_expires_at is None or user.subscription_expires_at <= now):
        raise ValueError("Subscription expired")

    if revoke_existing:
        rows = (await session.execute(
            select(SubscriptionAccess).where(
                SubscriptionAccess.user_id == user.id,
                SubscriptionAccess.revoked_at.is_(None),
            )
        )).scalars().all()
        for row in rows:
            row.revoked_at = now

    token = secrets.token_urlsafe(32)
    row = SubscriptionAccess(user_id=user.id, token_hash=hash_token(token))
    session.add(row)
    await session.flush()
    return row, token


async def resolve_subscription_access(session: AsyncSession, token: str) -> tuple[SubscriptionAccess, User]:
    if not token or len(token) > 256:
        raise HTTPException(status_code=401, detail="Invalid subscription link")
    row = await session.scalar(
        select(SubscriptionAccess).where(
            SubscriptionAccess.token_hash == hash_token(token),
            SubscriptionAccess.revoked_at.is_(None),
        )
    )
    if row is None:
        raise HTTPException(status_code=401, detail="Subscription link unavailable")
    user = await session.get(User, row.user_id)
    if user is None or user.status == UserStatus.blocked:
        raise HTTPException(status_code=403, detail="Subscription blocked")
    now = datetime.now(UTC)
    if not user.lifetime and (user.subscription_expires_at is None or user.subscription_expires_at <= now):
        raise HTTPException(status_code=403, detail="Subscription expired")
    row.last_used_at = now
    return row, user
