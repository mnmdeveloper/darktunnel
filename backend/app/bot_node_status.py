from __future__ import annotations

from datetime import UTC, datetime
from html import escape

from aiogram import F, Router
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup
from sqlalchemy import select

from .bot_features import reject_callback
from .db import SessionLocal
from .models import ServerHealth, ServerNode, ServerTransport

router = Router(name="node-status")


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def _age(value: datetime | None) -> str:
    if value is None:
        return "нет"
    seconds = max(0, int((datetime.now(UTC) - value).total_seconds()))
    if seconds < 60:
        return f"{seconds}с"
    if seconds < 3600:
        return f"{seconds // 60}м"
    return f"{seconds // 3600}ч"


def _transport_line(row: ServerTransport | None, *, inferred: bool = False) -> str:
    if row is None:
        return "⚪️ не обнаружен"
    icon = "🟢" if row.healthy else ("🟡" if row.detected else "🔴")
    suffix = " · inferred" if inferred else f" · {escape(row.version)}" if row.version else ""
    endpoint = f"{escape(row.host)}:{row.port}" if row.host and row.port else "—"
    return f"{icon} {escape(row.transport_type)} · {endpoint}{suffix}"


@router.callback_query(F.data == "node:status")
async def node_status(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    async with SessionLocal() as session:
        nodes = (
            await session.execute(
                select(ServerNode)
                .where(ServerNode.archived_at.is_(None))
                .order_by(ServerNode.created_at.asc())
            )
        ).scalars().all()
        parts: list[str] = ["<b>📡 Состояние VPN-нод</b>"]
        for node in nodes:
            health = await session.scalar(
                select(ServerHealth)
                .where(ServerHealth.server_id == node.id)
                .order_by(ServerHealth.timestamp.desc())
                .limit(1)
            )
            transports = (
                await session.execute(
                    select(ServerTransport)
                    .where(ServerTransport.server_id == node.id)
                    .order_by(ServerTransport.transport_type.asc())
                )
            ).scalars().all()
            by_type = {row.transport_type: row for row in transports}
            online = bool(health and health.online)
            icon = "🟢" if online else "🔴"
            latency = f" · {health.latency_ms}ms" if health and health.latency_ms is not None else ""
            seen = _age(max((row.last_seen_at for row in transports if row.last_seen_at), default=None))
            parts.append(
                f"\n<b>{icon} {escape(node.name)}</b>\n"
                f"<code>{escape(node.host)}:{node.port}</code>{latency}\n"
                f"WDTT: {_transport_line(by_type.get('wdtt')) if by_type.get('wdtt') else '🟢 работает (legacy)'}\n"
                f"VK TURN: {_transport_line(by_type.get('vkturn')) if by_type.get('vkturn') else '🟢 работает (legacy)'}\n"
                f"AmneziaWG: {_transport_line(by_type.get('amneziawg2'))}\n"
                f"Последний agent report: <b>{seen}</b>"
            )
        if not nodes:
            parts.append("\nНет зарегистрированных серверов.")
        text = "\n".join(parts)
    if callback.message:
        await callback.message.edit_text(
            text,
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[b("🔄 Обновить", "node:status")], [b("⬅️ Главное меню", "home")]]),
            parse_mode="HTML",
        )
    await callback.answer()
