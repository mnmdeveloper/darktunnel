from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .admin_models import AdminAccount, AdminRole, AuditEvent
from .config import get_settings


ROLE_PERMISSIONS: dict[AdminRole, frozenset[str]] = {
    AdminRole.owner: frozenset({"*"}),
    AdminRole.administrator: frozenset({
        "stats.read", "users.read", "users.write", "links.read", "links.write",
        "servers.read", "servers.write", "maintenance.write", "push.write",
        "themes.read", "themes.write", "announcements.read", "announcements.write",
        "audit.read", "settings.read",
    }),
    AdminRole.support: frozenset({
        "stats.read", "users.read", "users.write", "links.read", "links.write",
        "servers.read", "audit.read",
    }),
    AdminRole.content_manager: frozenset({
        "stats.read", "themes.read", "themes.write", "announcements.read",
        "announcements.write", "push.write", "maintenance.write",
    }),
    AdminRole.viewer: frozenset({
        "stats.read", "users.read", "links.read", "servers.read", "themes.read",
        "announcements.read", "audit.read", "settings.read",
    }),
}


@dataclass(slots=True, frozen=True)
class AdminPrincipal:
    telegram_id: int
    role: AdminRole
    display_name: str = ""

    def can(self, permission: str) -> bool:
        allowed = ROLE_PERMISSIONS[self.role]
        return "*" in allowed or permission in allowed


async def resolve_admin(session: AsyncSession, telegram_id: int | None) -> AdminPrincipal | None:
    if not telegram_id:
        return None
    settings = get_settings()
    if telegram_id == settings.telegram_owner_id:
        return AdminPrincipal(telegram_id=telegram_id, role=AdminRole.owner, display_name="Owner")
    row = await session.scalar(
        select(AdminAccount).where(AdminAccount.telegram_id == telegram_id, AdminAccount.enabled.is_(True))
    )
    if row is None:
        return None
    return AdminPrincipal(telegram_id=row.telegram_id, role=row.role, display_name=row.display_name)


async def require_permission(
    session: AsyncSession,
    telegram_id: int | None,
    permission: str,
) -> AdminPrincipal:
    principal = await resolve_admin(session, telegram_id)
    if principal is None or not principal.can(permission):
        raise PermissionError("Недостаточно прав")
    return principal


def redact(value: Any) -> Any:
    secret_fragments = ("password", "private_key", "secret", "token", "authorization", "wrap_a_password")
    if isinstance(value, Mapping):
        result: dict[str, Any] = {}
        for key, item in value.items():
            name = str(key)
            if any(fragment in name.lower() for fragment in secret_fragments):
                result[name] = "***"
            else:
                result[name] = redact(item)
        return result
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, tuple):
        return [redact(item) for item in value]
    return value


async def write_audit(
    session: AsyncSession,
    *,
    admin_id: int,
    action: str,
    entity_type: str,
    entity_id: str,
    old_data: dict[str, Any] | None = None,
    new_data: dict[str, Any] | None = None,
    result: str = "success",
    detail: str = "",
) -> AuditEvent:
    event = AuditEvent(
        admin_id=admin_id,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        old_data=redact(old_data) if old_data is not None else None,
        new_data=redact(new_data) if new_data is not None else None,
        result=result,
        detail=detail[:4000],
    )
    session.add(event)
    return event
