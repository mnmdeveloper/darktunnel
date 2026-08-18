from __future__ import annotations

import secrets
from datetime import UTC, datetime

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import SubscriptionAccess, User
from .security import hash_token


ACCESS_SCHEME = "darktunnel://activate?d="


def make_access_link(token: str) -> str:
    return ACCESS_SCHEME + token


async def create_subscription_access(session: AsyncSession, user: User, *, revoke_existing: bool = True) -> tuple[SubscriptionAccess, str]:
    now = datetime.now(UTC)
    if revoke_existing:
        rows = (await session.execute(select(SubscriptionAccess).where(SubscriptionAccess.user_id == user.id, SubscriptionAccess.revoked_at.is_(None)))).scalars().all()
        for row in rows: row.revoked_at = now
    token = secrets.token_urlsafe(32)
    row = SubscriptionAccess(user_id=user.id, token_hash=hash_token(token))
    session.add(row)
    await session.flush()
    return row, token


async def resolve_subscription_access(session: AsyncSession, token: str) -> tuple[SubscriptionAccess, User]:
    if not token or len(token) > 256: raise HTTPException(status_code=401, detail="Invalid activation link")
    row = await session.scalar(select(SubscriptionAccess).where(SubscriptionAccess.token_hash == hash_token(token), SubscriptionAccess.revoked_at.is_(None)))
    if row is None: raise HTTPException(status_code=401, detail="Activation link unavailable")
    user = await session.get(User, row.user_id)
    if user is None: raise HTTPException(status_code=404, detail="Subscription not found")
    row.last_used_at = datetime.now(UTC)
    return row, user
