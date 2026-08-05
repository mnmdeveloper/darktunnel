from __future__ import annotations

import asyncio
import base64
import json
import subprocess
from datetime import UTC, datetime, timedelta
from html import escape

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import select

from .config import get_settings
from .db import SessionLocal
from .models import AuditLog, VkTurnAccess, VkTurnSetting

router = Router(name="vkturn-management")


class VkTurnCreate(StatesGroup):
    telegram_id = State()
    note = State()


class VkTurnLink(StatesGroup):
    value = State()


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def owner(user_id: int | None) -> bool:
    s = get_settings()
    return bool(user_id and s.telegram_owner_id and user_id == s.telegram_owner_id)


def run(*args: str, input_text: str | None = None) -> str:
    return subprocess.run(args, input=input_text, text=True, check=True, capture_output=True).stdout.strip()


def generate_keypair() -> tuple[str, str]:
    private = run("wg", "genkey")
    public = run("wg", "pubkey", input_text=private + "\n")
    return private, public


def add_peer(public_key: str, ip: str) -> None:
    run("wg", "set", "wg0", "peer", public_key, "allowed-ips", f"{ip}/32")


def remove_peer(public_key: str) -> None:
    try:
        run("wg", "set", "wg0", "peer", public_key, "remove")
    except Exception:
        pass


def server_public_key() -> str:
    return run("wg", "show", "wg0", "public-key")


def make_link(row: VkTurnAccess, vk_link: str) -> str:
    settings = get_settings()
    endpoint = getattr(settings, "vkturn_public_endpoint", "31.77.148.80:56100")
    payload = {
        "serverName": f"DarkTunnel VK #{str(row.id)[:8]}",
        "privateKey": row.private_key,
        "peerPublicKey": server_public_key(),
        "tunnelAddress": f"{row.tunnel_ip}/24",
        "dnsServers": "1.1.1.1",
        "vkLink": vk_link,
        "peerAddress": endpoint,
        "numConnections": 30,
        "useDTLS": True,
        "useWrap": False,
        "wrapKeyHex": "",
        "useSrtp": True,
        "useUDP": False,
        "useWrapA": False,
        "useWrapS": False,
        "obfProfile": "rtpopus",
        "clientID": "",
    }
    encoded = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")
    return f"vkturnproxy://import?data={encoded}"


async def edit(c: CallbackQuery, text: str, rows: list[list[InlineKeyboardButton]]) -> None:
    if c.message:
        await c.message.edit_text(text, reply_markup=kb(rows), parse_mode="HTML")
    await c.answer()


async def next_ip(session) -> str:
    rows = (await session.execute(select(VkTurnAccess.tunnel_ip))).scalars().all()
    used = {int(x.rsplit(".", 1)[1]) for x in rows if x.startswith("10.79.0.")}
    for suffix in range(2, 255):
        if suffix not in used:
            return f"10.79.0.{suffix}"
    raise RuntimeError("Свободные адреса VK Turn закончились")


@router.callback_query(F.data == "vkturn")
async def menu(c: CallbackQuery) -> None:
    if not owner(c.from_user.id):
        await c.answer("Доступ запрещён", show_alert=True); return
    async with SessionLocal() as s:
        rows = (await s.execute(select(VkTurnAccess).order_by(VkTurnAccess.created_at.desc()).limit(20))).scalars().all()
        setting = await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key == "vk_link"))
    now = datetime.now(UTC)
    buttons = [[b("➕ 3 дня", "vk:new:3"), b("➕ 30 дней", "vk:new:30")], [b("🔗 Задать VK-звонок", "vk:set-link")]]
    for row in rows:
        active = not row.revoked_at and row.expires_at > now
        buttons.append([b(f"{'✅' if active else '❌'} {row.note or str(row.telegram_id or row.id)[:16]}", f"vk:view:{row.id}")])
    buttons.append([b("⬅️ Главное меню", "home")])
    await edit(c, f"<b>📡 VK Turn Proxy</b>\n\nVK-звонок: <b>{'настроен' if setting and setting.value else 'не задан'}</b>\nДоступы управляются отдельно от DarkTurn.", buttons)


@router.callback_query(F.data.startswith("vk:new:"))
async def create_start(c: CallbackQuery, state: FSMContext) -> None:
    if not owner(c.from_user.id): return
    days = int(c.data.rsplit(":", 1)[1])
    await state.set_state(VkTurnCreate.telegram_id)
    await state.update_data(days=days)
    await edit(c, f"<b>Новый VK Turn · {days} дней</b>\n\nОтправьте Telegram ID пользователя или 0.", [[b("❌ Отмена", "vkturn")]])


@router.message(VkTurnCreate.telegram_id)
async def create_tg(m: Message, state: FSMContext) -> None:
    if not owner(m.from_user.id if m.from_user else None): return
    try: telegram_id = int((m.text or "0").strip())
    except ValueError: telegram_id = -1
    if telegram_id < 0:
        await m.answer("Введите числовой Telegram ID или 0."); return
    await state.update_data(telegram_id=telegram_id or None)
    await state.set_state(VkTurnCreate.note)
    await m.answer("Отправьте заметку/имя пользователя.")


@router.message(VkTurnCreate.note)
async def create_finish(m: Message, state: FSMContext) -> None:
    if not owner(m.from_user.id if m.from_user else None): return
    data = await state.get_data(); await state.clear()
    private, public = generate_keypair()
    async with SessionLocal() as s:
        setting = await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key == "vk_link"))
        if not setting or not setting.value:
            await m.answer("Сначала задайте ссылку VK-звонка в разделе VK Turn."); return
        ip = await next_ip(s)
        row = VkTurnAccess(telegram_id=data.get("telegram_id"), note=(m.text or "")[:200], private_key=private, public_key=public, tunnel_ip=ip, expires_at=datetime.now(UTC) + timedelta(days=int(data["days"])))
        s.add(row); await s.flush()
        s.add(AuditLog(admin_id=m.from_user.id, action="vkturn.create", entity_type="vkturn_access", entity_id=str(row.id)))
        await s.commit(); await s.refresh(row)
    add_peer(public, ip)
    link = make_link(row, setting.value)
    await m.answer(f"<b>✅ VK Turn доступ создан</b>\n\nСрок до: <b>{row.expires_at.astimezone().strftime('%d.%m.%Y %H:%M')}</b>\nIP: <code>{ip}</code>\n\n<code>{escape(link)}</code>", reply_markup=kb([[b("📡 К VK Turn", "vkturn")]]), parse_mode="HTML")


@router.callback_query(F.data == "vk:set-link")
async def set_link_start(c: CallbackQuery, state: FSMContext) -> None:
    if not owner(c.from_user.id): return
    await state.set_state(VkTurnLink.value)
    await edit(c, "Отправьте полную ссылку VK-звонка.", [[b("❌ Отмена", "vkturn")]])


@router.message(VkTurnLink.value)
async def set_link_finish(m: Message, state: FSMContext) -> None:
    if not owner(m.from_user.id if m.from_user else None): return
    value = (m.text or "").strip()
    if not value.startswith("http") or "/call/" not in value and "vk.me/join/" not in value:
        await m.answer("Это не похоже на ссылку VK-звонка."); return
    async with SessionLocal() as s:
        row = await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key == "vk_link"))
        if row: row.value = value
        else: s.add(VkTurnSetting(key="vk_link", value=value))
        await s.commit()
    await state.clear(); await m.answer("✅ Ссылка VK-звонка сохранена.", reply_markup=kb([[b("📡 VK Turn", "vkturn")]]))


@router.callback_query(F.data.startswith("vk:view:"))
async def view(c: CallbackQuery) -> None:
    if not owner(c.from_user.id): return
    ident = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        row = await s.get(VkTurnAccess, ident)
        setting = await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key == "vk_link"))
    if not row: await c.answer("Не найдено", show_alert=True); return
    active = not row.revoked_at and row.expires_at > datetime.now(UTC)
    rows = [[b("➕ 30 дней", f"vk:extend:{row.id}")], [b("⛔️ Отключить" if active else "✅ Включить", f"vk:toggle:{row.id}")]]
    if setting and setting.value: rows.append([b("🔗 Показать ссылку", f"vk:show:{row.id}")])
    rows.append([b("⬅️ VK Turn", "vkturn")])
    await edit(c, f"<b>VK Turn доступ</b>\n\nID: <code>{row.id}</code>\nTelegram: <code>{row.telegram_id or '—'}</code>\nЗаметка: {escape(row.note or '—')}\nIP: <code>{row.tunnel_ip}</code>\nДо: <b>{row.expires_at.astimezone().strftime('%d.%m.%Y %H:%M')}</b>\nСтатус: <b>{'активен' if active else 'отключён'}</b>", rows)


@router.callback_query(F.data.startswith("vk:extend:"))
async def extend(c: CallbackQuery) -> None:
    ident = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        row = await s.get(VkTurnAccess, ident)
        if not row: return
        base = max(row.expires_at, datetime.now(UTC)); row.expires_at = base + timedelta(days=30); row.revoked_at = None
        await s.commit(); public, ip = row.public_key, row.tunnel_ip
    add_peer(public, ip); await c.answer("Продлено на 30 дней", show_alert=True); c.data = f"vk:view:{ident}"; await view(c)


@router.callback_query(F.data.startswith("vk:toggle:"))
async def toggle(c: CallbackQuery) -> None:
    ident = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        row = await s.get(VkTurnAccess, ident)
        if not row: return
        if row.revoked_at:
            row.revoked_at = None
            if row.expires_at <= datetime.now(UTC): row.expires_at = datetime.now(UTC) + timedelta(days=30)
            action = "on"
        else:
            row.revoked_at = datetime.now(UTC); action = "off"
        await s.commit(); public, ip = row.public_key, row.tunnel_ip
    add_peer(public, ip) if action == "on" else remove_peer(public)
    await c.answer("Готово", show_alert=True); c.data = f"vk:view:{ident}"; await view(c)


@router.callback_query(F.data.startswith("vk:show:"))
async def show_link(c: CallbackQuery) -> None:
    ident = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        row = await s.get(VkTurnAccess, ident)
        setting = await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key == "vk_link"))
    if row and setting and setting.value and c.message:
        await c.message.answer(f"<code>{escape(make_link(row, setting.value))}</code>", parse_mode="HTML")
    await c.answer()


async def sync_peers_forever() -> None:
    while True:
        try:
            now = datetime.now(UTC)
            async with SessionLocal() as s:
                rows = (await s.execute(select(VkTurnAccess))).scalars().all()
            for row in rows:
                if row.revoked_at or row.expires_at <= now: remove_peer(row.public_key)
                else: add_peer(row.public_key, row.tunnel_ip)
        except Exception:
            pass
        await asyncio.sleep(60)
