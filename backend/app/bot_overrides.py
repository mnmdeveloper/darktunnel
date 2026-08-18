from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from html import escape

from aiogram import Bot, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import delete, func, or_, select

from .bot_admins import add_admin, get_admin_ids, is_admin, remove_admin
from .config import get_settings
from .db import SessionLocal
from .models import Activation, AuditLog, Device, User, UserStatus
from .subscription_access import create_subscription_access, make_access_link

router = Router(name="bot-overrides")


class SearchState(StatesGroup):
    query = State()


class BroadcastState(StatesGroup):
    text = State()


class AddAdminState(StatesGroup):
    query = State()


class RenewState(StatesGroup):
    days = State()


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def user_label(user: User) -> str:
    if user.telegram_username:
        return f"@{user.telegram_username.lstrip('@')}"
    return str(user.id)[:8]


def telegram_label(user: User) -> str:
    if user.telegram_username:
        return f"@{escape(user.telegram_username.lstrip('@'))}"
    return f"Telegram ID: <code>{user.telegram_id or '—'}</code>"


def expiry(user: User) -> str:
    if user.lifetime:
        return "бессрочно"
    return user.subscription_expires_at.astimezone().strftime("%d.%m.%Y %H:%M") if user.subscription_expires_at else "—"


def days_left(user: User) -> str:
    if user.lifetime:
        return "∞"
    if not user.subscription_expires_at:
        return "0"
    return str(max(0, (user.subscription_expires_at - datetime.now(UTC)).days + 1))


def status_icon(user: User) -> str:
    if user.status == UserStatus.blocked:
        return "⛔️"
    if user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)):
        return "✅"
    return "⌛️"


async def deny(c: CallbackQuery | Message) -> bool:
    user_id = c.from_user.id if c.from_user else None
    if await is_admin(user_id):
        return False
    if isinstance(c, CallbackQuery):
        await c.answer("Доступ запрещён", show_alert=True)
    else:
        await c.answer("Доступ запрещён.")
    return True


async def ensure_user(telegram_id: int, username: str | None) -> User:
    async with SessionLocal() as session:
        user = await session.scalar(select(User).where(User.telegram_id == telegram_id))
        if user is None:
            user = User(telegram_id=telegram_id, telegram_username=username)
            session.add(user)
        else:
            user.telegram_username = username
        await session.commit()
        await session.refresh(user)
        return user


async def render_user(c: CallbackQuery, user_id: str) -> None:
    async with SessionLocal() as session:
        user = await session.scalar(select(User).where(User.id == user_id))
        devices = [] if user is None else (await session.execute(select(Device).where(Device.user_id == user.id, Device.revoked_at.is_(None)).order_by(Device.created_at.asc()))).scalars().all()
    if user is None:
        await c.answer("Пользователь не найден", show_alert=True)
        return
    lines = []
    for device in devices[:10]:
        platform = (getattr(device, "platform", "") or "unknown").strip().lower()
        platform_label = {"ios": "iOS", "android": "Android"}.get(platform, "Платформа не определена")
        lines.append(f"• <code>{escape(device.installation_id[-8:])}</code> · {platform_label} · app {escape(device.app_version or '—')} · {escape(device.ios_version or '—')} · {device.last_seen_at.astimezone().strftime('%d.%m.%Y %H:%M')}")
    device_text = "\n".join(lines) or "—"
    label = user_label(user)
    rows = [
        [b("🔗 Получить ссылку", f"subscription:link:{user.id}"), b("📤 Отправить", f"subscription:link_send:{user.id}")],
        [b("➕ 3 дня", f"override:user:add:3:{user.id}"), b("➕ 7 дней", f"override:user:add:7:{user.id}")],
        [b("➕ 14 дней", f"override:user:add:14:{user.id}"), b("➕ 30 дней", f"override:user:add:30:{user.id}")],
        [b("➕ 90 дней", f"override:user:add:90:{user.id}"), b("➕ 365 дней", f"override:user:add:365:{user.id}")],
        [b("➕/➖ Свой срок", f"override:user:custom:{user.id}"), b("📅 Точная дата", f"override:user:date:{user.id}")],
        [b("🔄 Запросить продление", f"override:user:renew:{user.id}")],
        [b("⛔️ Заблокировать" if user.status != UserStatus.blocked else "✅ Разблокировать", f"override:user:toggle:{user.id}")],
        [b("📱 Сбросить устройства", f"override:user:reset:{user.id}"), b("🗑 Удалить", f"override:user:delete:{user.id}")],
        [b("⬅️ Пользователи", "override:users:0")],
    ]
    text = (
        f"<b>{status_icon(user)} {escape(label)}</b>\n\n"
        f"{telegram_label(user)}\n"
        f"Статус: <b>{escape(user.status.value)}</b>\n"
        f"Активирована: <b>{user.activated_at.astimezone().strftime('%d.%m.%Y %H:%M') if user.activated_at else '—'}</b>\n"
        f"Подписка до: <b>{expiry(user)}</b>\n"
        f"Осталось: <b>{days_left(user)} дн.</b>\n"
        f"Заметка: {escape(user.note or '—')}\n"
        f"Устройств: <b>{len(devices)}</b>\n\n"
        f"<b>Устройства</b>\n{device_text}"
    )
    if c.message:
        await c.message.edit_text(text, reply_markup=kb(rows), parse_mode="HTML")
    await c.answer()


@router.message(CommandStart())
@router.message(Command("menu"))
async def start_override(message: Message, state: FSMContext) -> None:
    if not message.from_user:
        return
    user = await ensure_user(message.from_user.id, message.from_user.username)
    await state.clear()
    if await is_admin(message.from_user.id):
        await message.answer(
            "<b>DarkTunnel Admin</b>\n\nВыберите раздел:",
            reply_markup=kb([
                [b("💳 Подписки", "override:subscriptions"), b("👥 Пользователи", "override:users:0")],
                [b("📢 Объявление всем", "override:broadcast")],
                [b("👮 Администраторы", "override:admins")],
                [b("📊 Статистика", "override:stats")],
                [b("⬅️ Главное меню", "override:home")],
            ]),
            parse_mode="HTML",
        )
        return
    active = user.status == UserStatus.active and (user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)))
    if active:
        await message.answer(
            f"<b>DarkTunnel</b>\n\nВаша подписка активна до: <b>{expiry(user)}</b>.\n\nВыберите действие:",
            reply_markup=kb([
                [b("💳 Моя подписка", "override:user:subscription")],
                [b("➕ Продлить подписку", "override:user:renew")],
                [b("🔗 Получить ссылку управления", "override:user:link")],
                [b("📱 Мои устройства", "override:user:devices")],
            ]),
            parse_mode="HTML",
        )
    else:
        await message.answer(
            "<b>DarkTunnel</b>\n\nУ вас пока нет активной подписки. Нажмите кнопку ниже — заявка уйдёт администратору.",
            reply_markup=kb([[b("🔑 Запросить доступ", "override:user:request")]]),
            parse_mode="HTML",
        )


@router.callback_query(F.data == "override:home")
async def home(c: CallbackQuery) -> None:
    if await deny(c): return
    await c.answer()
    if c.message:
        await c.message.edit_text("<b>DarkTunnel Admin</b>\n\nВыберите раздел:", reply_markup=kb([
            [b("💳 Подписки", "override:subscriptions"), b("👥 Пользователи", "override:users:0")],
            [b("📢 Объявление всем", "override:broadcast")],
            [b("👮 Администраторы", "override:admins")],
            [b("📊 Статистика", "override:stats")],
        ]), parse_mode="HTML")


@router.callback_query(F.data == "override:subscriptions")
async def subscriptions(c: CallbackQuery) -> None:
    if await deny(c): return
    async with SessionLocal() as s:
        total = int(await s.scalar(select(func.count(User.id))) or 0)
        active = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.active, or_(User.lifetime.is_(True), User.subscription_expires_at > datetime.now(UTC)))) or 0)
        expired = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.active, User.lifetime.is_(False), User.subscription_expires_at <= datetime.now(UTC))) or 0)
        blocked = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.blocked)) or 0)
    await c.answer()
    if c.message:
        await c.message.edit_text(
            f"<b>💳 Подписки</b>\n\nВсего: <b>{total}</b> · активных: <b>{active}</b> · истёкших: <b>{expired}</b> · заблокированных: <b>{blocked}</b>",
            reply_markup=kb([
                [b("🔎 Найти пользователя", "override:user:search")],
                [b("👥 Пользователи", "override:users:0")],
                [b("➕ 3 дня всем", "override:bulk:ask:3"), b("➕ 7 дней всем", "override:bulk:ask:7")],
                [b("⬅️ Главное", "override:home")],
            ]),
            parse_mode="HTML",
        )


@router.callback_query(F.data.startswith("override:bulk:ask:"))
async def bulk_ask(c: CallbackQuery) -> None:
    if await deny(c): return
    days = int(c.data.rsplit(":", 1)[1])
    await c.answer()
    if c.message:
        await c.message.edit_text(
            f"<b>➕ Добавить {days} дней всем?</b>\n\nБудут продлены все не заблокированные пользователи с конечной датой подписки. Бессрочные подписки не изменятся.",
            reply_markup=kb([[b("✅ Да, продлить", f"override:bulk:{days}")], [b("Отмена", "override:subscriptions")]]),
            parse_mode="HTML",
        )


@router.callback_query(F.data.startswith("override:bulk:"))
async def bulk_extend(c: CallbackQuery) -> None:
    if await deny(c): return
    days = int(c.data.rsplit(":", 1)[1])
    now = datetime.now(UTC)
    async with SessionLocal() as s:
        users = (await s.execute(select(User).where(User.status == UserStatus.active, User.lifetime.is_(False)))).scalars().all()
        for user in users:
            base = user.subscription_expires_at if user.subscription_expires_at and user.subscription_expires_at > now else now
            user.subscription_expires_at = base + timedelta(days=days)
        s.add(AuditLog(admin_id=c.from_user.id, action=f"users.bulk_extend.{days}", entity_type="users", entity_id="ALL"))
        await s.commit()
    await c.answer(f"Продлено: {len(users)} пользователей", show_alert=True)
    await subscriptions(c)


@router.callback_query(F.data.startswith("override:users:"))
async def users(c: CallbackQuery) -> None:
    if await deny(c): return
    page = max(0, int(c.data.rsplit(":", 1)[1]))
    page_size = 8
    async with SessionLocal() as s:
        total = int(await s.scalar(select(func.count(User.id))) or 0)
        rows = (await s.execute(select(User).order_by(User.created_at.desc()).offset(page * page_size).limit(page_size))).scalars().all()
    buttons = [[b(f"{status_icon(u)} {escape(user_label(u))} · {days_left(u)}д", f"override:user:view:{u.id}")] for u in rows]
    nav = []
    if page > 0: nav.append(b("◀️", f"override:users:{page - 1}"))
    if (page + 1) * page_size < total: nav.append(b("▶️", f"override:users:{page + 1}"))
    if nav: buttons.append(nav)
    buttons += [[b("🔎 Найти", "override:user:search")], [b("⬅️ Подписки", "override:subscriptions")]]
    await c.answer()
    if c.message:
        await c.message.edit_text(f"<b>👥 Пользователи</b>\n\nВсего: <b>{total}</b> · страница {page + 1}", reply_markup=kb(buttons), parse_mode="HTML")


@router.callback_query(F.data == "override:user:search")
async def search_start(c: CallbackQuery, state: FSMContext) -> None:
    if await deny(c): return
    await state.set_state(SearchState.query)
    if c.message:
        await c.message.edit_text("<b>🔎 Найти пользователя</b>\n\n@username, Telegram ID, User ID, installation ID или заметка:", reply_markup=kb([[b("Отмена", "override:users:0")]]), parse_mode="HTML")
    await c.answer()


@router.message(SearchState.query)
async def search_text(m: Message, state: FSMContext) -> None:
    if await deny(m): return
    q = (m.text or "").strip()
    await state.clear()
    username_q = q.lstrip("@").strip()
    async with SessionLocal() as s:
        conditions = [User.note.ilike(f"%{q}%"), User.telegram_username.ilike(f"%{username_q}%"), func.cast(User.id, type(User.id.type)).ilike(f"%{q}%") if False else User.telegram_username.ilike(f"%{username_q}%")]
        if q.isdigit():
            conditions.append(User.telegram_id == int(q))
        device_users = select(Device.user_id).where(or_(Device.installation_id.ilike(f"%{q}%"), func.cast(Device.id, type(Device.id.type)).ilike(f"%{q}%") if False else Device.installation_id.ilike(f"%{q}%")))
        rows = (await s.execute(select(User).where(or_(*conditions, User.id.in_(device_users))).order_by(User.created_at.desc()).limit(20))).scalars().all()
    buttons = [[b(f"{status_icon(u)} {escape(user_label(u))} · {days_left(u)}д", f"override:user:view:{u.id}")] for u in rows]
    buttons.append([b("⬅️ Пользователи", "override:users:0")])
    await m.answer(f"<b>Результаты</b>\n\nНайдено: <b>{len(rows)}</b>", reply_markup=kb(buttons), parse_mode="HTML")


@router.callback_query(F.data.startswith("override:user:view:"))
async def user_view(c: CallbackQuery) -> None:
    if await deny(c): return
    await render_user(c, c.data.rsplit(":", 1)[1])


@router.callback_query(F.data.startswith("override:user:add:"))
async def user_add(c: CallbackQuery) -> None:
    if await deny(c): return
    _, _, _, days_s, user_id = c.data.split(":")
    days = int(days_s)
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await c.answer("Пользователь не найден", show_alert=True); return
        now = datetime.now(UTC)
        base = user.subscription_expires_at if user.subscription_expires_at and user.subscription_expires_at > now else now
        user.status = UserStatus.active
        user.lifetime = False
        user.subscription_expires_at = base + timedelta(days=days)
        s.add(AuditLog(admin_id=c.from_user.id, action=f"user.extend.{days}", entity_type="user", entity_id=str(user.id)))
        await s.commit()
    await c.answer(f"Добавлено {days} дней", show_alert=True)
    await render_user(c, user_id)


@router.callback_query(F.data.startswith("override:user:toggle:"))
async def user_toggle(c: CallbackQuery) -> None:
    if await deny(c): return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await c.answer("Не найден", show_alert=True); return
        user.status = UserStatus.active if user.status == UserStatus.blocked else UserStatus.blocked
        s.add(AuditLog(admin_id=c.from_user.id, action=f"user.status.{user.status.value}", entity_type="user", entity_id=str(user.id)))
        await s.commit()
    await render_user(c, user_id)
    await c.answer("Статус изменён")


@router.callback_query(F.data.startswith("override:user:reset:"))
async def user_reset(c: CallbackQuery) -> None:
    if await deny(c): return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        devices = (await s.execute(select(Device).where(Device.user_id == user_id, Device.revoked_at.is_(None)))).scalars().all()
        for device in devices:
            device.revoked_at = datetime.now(UTC)
            device.auth_token_hash = ""
        s.add(AuditLog(admin_id=c.from_user.id, action="user.devices.reset", entity_type="user", entity_id=user_id))
        await s.commit()
    await c.answer(f"Сброшено устройств: {len(devices)}", show_alert=True)
    await render_user(c, user_id)


@router.callback_query(F.data.startswith("override:user:delete:"))
async def user_delete(c: CallbackQuery) -> None:
    if await deny(c): return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await c.answer("Уже удалён", show_alert=True); return
        await s.execute(delete(Activation).where(Activation.user_id == user.id))
        await s.delete(user)
        s.add(AuditLog(admin_id=c.from_user.id, action="subscription.delete", entity_type="user", entity_id=user_id))
        await s.commit()
    await c.answer("Удалено", show_alert=True)
    c.data = "override:users:0"
    await users(c)


@router.callback_query(F.data.startswith("subscription:link:"))
async def subscription_link(c: CallbackQuery) -> None:
    if not await is_admin(c.from_user.id):
        return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await c.answer("Пользователь не найден", show_alert=True); return
        _, token = await create_subscription_access(s, user, revoke_existing=True)
        await s.commit()
    link = make_access_link(token)
    if c.message:
        await c.message.answer(f"<b>🔗 DarkTunnel activation</b>\n\nПользователь: <b>{escape(user_label(user))}</b>\n\n<code>{escape(link)}</code>", parse_mode="HTML", reply_markup=kb([[b("⬅️ К пользователю", f"override:user:view:{user.id}")]]))
    await c.answer("Ссылка создана")


@router.callback_query(F.data.startswith("subscription:link_send:"))
async def subscription_link_send(c: CallbackQuery, bot: Bot) -> None:
    if not await is_admin(c.from_user.id):
        return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None or not user.telegram_id:
            await c.answer("Telegram ID не указан", show_alert=True); return
        _, token = await create_subscription_access(s, user, revoke_existing=True)
        await s.commit()
    await bot.send_message(user.telegram_id, f"🔗 <b>Ваша ссылка DarkTunnel</b>\n\nОткройте её в приложении:\n<code>{escape(make_access_link(token))}</code>", parse_mode="HTML")
    await c.answer("Отправлено", show_alert=True)


@router.callback_query(F.data == "override:user:request")
async def request_access(c: CallbackQuery) -> None:
    user = await ensure_user(c.from_user.id, c.from_user.username)
    admins = await get_admin_ids()
    username = f"@{c.from_user.username}" if c.from_user.username else "—"
    text = f"<b>🔑 Запрос доступа</b>\n\nUsername: <b>{escape(username)}</b>\nTelegram ID: <code>{c.from_user.id}</code>\nUser ID: <code>{user.id}</code>"
    for admin_id in admins:
        try:
            await c.bot.send_message(admin_id, text, parse_mode="HTML", reply_markup=kb([[b("👤 Открыть", f"override:user:view:{user.id}")]]))
        except Exception:
            pass
    await c.answer("Заявка отправлена", show_alert=True)


@router.callback_query(F.data == "override:user:subscription")
async def user_subscription(c: CallbackQuery) -> None:
    user = await ensure_user(c.from_user.id, c.from_user.username)
    active = user.status == UserStatus.active and (user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)))
    await c.answer()
    if c.message:
        await c.message.edit_text(
            f"<b>💳 Моя подписка</b>\n\nСтатус: <b>{'активна' if active else 'неактивна'}</b>\nДо: <b>{expiry(user)}</b>",
            reply_markup=kb([
                [b("➕ Продлить подписку", "override:user:renew")],
                [b("🔗 Ссылка DarkTunnel", "override:user:link")],
                [b("📱 Мои устройства", "override:user:devices")],
                [b("⬅️ Назад", "override:user:home")],
            ]), parse_mode="HTML")


@router.callback_query(F.data == "override:user:renew")
async def renew(c: CallbackQuery) -> None:
    await c.answer()
    if c.message:
        await c.message.edit_text("<b>➕ Продление подписки</b>\n\nВыберите срок — запрос будет отправлен администратору:", reply_markup=kb([
            [b("7 дней", "override:user:renew:7"), b("30 дней", "override:user:renew:30")],
            [b("90 дней", "override:user:renew:90"), b("365 дней", "override:user:renew:365")],
            [b("⬅️ Назад", "override:user:subscription")],
        ]), parse_mode="HTML")


@router.callback_query(F.data.startswith("override:user:renew:"))
async def renew_request(c: CallbackQuery) -> None:
    days = int(c.data.rsplit(":", 1)[1])
    user = await ensure_user(c.from_user.id, c.from_user.username)
    admins = await get_admin_ids()
    for admin_id in admins:
        try:
            await c.bot.send_message(admin_id, f"<b>➕ Запрос продления</b>\n\nПользователь: <b>{escape(user_label(user))}</b>\nСрок: <b>{days} дней</b>\nTelegram ID: <code>{user.telegram_id}</code>", parse_mode="HTML", reply_markup=kb([[b("👤 Открыть", f"override:user:view:{user.id}")], [b(f"➕ Одобрить +{days}", f"override:user:add:{days}:{user.id}")]]))
        except Exception:
            pass
    await c.answer("Запрос отправлен администратору", show_alert=True)


@router.callback_query(F.data == "override:user:link")
async def user_link(c: CallbackQuery) -> None:
    user = await ensure_user(c.from_user.id, c.from_user.username)
    active = user.status == UserStatus.active and (user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)))
    if not active:
        await c.answer("Активной подписки нет", show_alert=True); return
    async with SessionLocal() as s:
        _, token = await create_subscription_access(s, user, revoke_existing=True)
        await s.commit()
    await c.answer("Ссылка создана")
    if c.message:
        await c.message.answer(f"<b>🔗 Ваша ссылка DarkTunnel</b>\n\n<code>{escape(make_access_link(token))}</code>", parse_mode="HTML")


@router.callback_query(F.data == "override:user:devices")
async def user_devices(c: CallbackQuery) -> None:
    user = await ensure_user(c.from_user.id, c.from_user.username)
    async with SessionLocal() as s:
        devices = (await s.execute(select(Device).where(Device.user_id == user.id, Device.revoked_at.is_(None)).order_by(Device.created_at.asc()))).scalars().all()
    lines = []
    for d in devices:
        platform = (getattr(d, "platform", "") or "unknown").lower()
        name = {"ios": "iOS", "android": "Android"}.get(platform, "Платформа не определена")
        lines.append(f"• <code>{escape(d.installation_id[-8:])}</code> · {name} · app {escape(d.app_version or '—')}")
    await c.answer()
    if c.message:
        await c.message.edit_text("<b>📱 Мои устройства</b>\n\n" + ("\n".join(lines) or "—"), reply_markup=kb([[b("⬅️ Назад", "override:user:subscription")]]), parse_mode="HTML")


@router.callback_query(F.data == "override:user:home")
async def user_home(c: CallbackQuery) -> None:
    await c.answer()
    await start_override(c.message, FSMContext) if False else None
    user = await ensure_user(c.from_user.id, c.from_user.username)
    if c.message:
        await c.message.edit_text(f"<b>DarkTunnel</b>\n\nПодписка до: <b>{expiry(user)}</b>", reply_markup=kb([
            [b("💳 Моя подписка", "override:user:subscription")],
            [b("➕ Продлить подписку", "override:user:renew")],
            [b("🔗 Получить ссылку", "override:user:link")],
            [b("📱 Мои устройства", "override:user:devices")],
        ]), parse_mode="HTML")


@router.callback_query(F.data == "override:broadcast")
async def broadcast_start(c: CallbackQuery, state: FSMContext) -> None:
    if await deny(c): return
    await state.set_state(BroadcastState.text)
    if c.message:
        await c.message.edit_text("<b>📢 Объявление всем пользователям Telegram</b>\n\nОтправьте текст одним сообщением. Перед отправкой будет показано подтверждение.", reply_markup=kb([[b("Отмена", "override:home")]]), parse_mode="HTML")
    await c.answer()


@router.message(BroadcastState.text)
async def broadcast_text(m: Message, state: FSMContext) -> None:
    if not await is_admin(m.from_user.id if m.from_user else None):
        await deny(m); return
    text = (m.text or "").strip()
    if not text or len(text) > 4000:
        await m.answer("Текст должен быть от 1 до 4000 символов."); return
    await state.clear()
    async with SessionLocal() as s:
        count = int(await s.scalar(select(func.count(User.id)).where(User.telegram_id.is_not(None))) or 0)
    await m.answer(f"<b>📢 Готово к отправке</b>\n\nПолучателей: <b>{count}</b>\n\n<pre>{escape(text[:1500])}</pre>", reply_markup=kb([[b("✅ Отправить", "override:broadcast:send")], [b("Отмена", "override:home")]]), parse_mode="HTML")
    await state.update_data(broadcast_text=text)


@router.callback_query(F.data == "override:broadcast:send")
async def broadcast_send(c: CallbackQuery, state: FSMContext, bot: Bot) -> None:
    if not await is_admin(c.from_user.id): return
    data = await state.get_data()
    text = str(data.get("broadcast_text") or "").strip()
    await state.clear()
    if not text:
        await c.answer("Текст рассылки потерян", show_alert=True); return
    async with SessionLocal() as s:
        ids = [int(row[0]) for row in (await s.execute(select(User.telegram_id).where(User.telegram_id.is_not(None)))).all()]
    sent = failed = 0
    for telegram_id in ids:
        try:
            await bot.send_message(telegram_id, f"📢 <b>DarkTunnel</b>\n\n{escape(text)}", parse_mode="HTML")
            sent += 1
        except Exception:
            failed += 1
        await asyncio.sleep(0.04)
    async with SessionLocal() as s:
        s.add(AuditLog(admin_id=c.from_user.id, action="telegram.broadcast", entity_type="users", entity_id="ALL", result="success" if failed == 0 else "partial"))
        await s.commit()
    await c.answer(f"Отправлено: {sent}, ошибок: {failed}", show_alert=True)
    if c.message:
        await c.message.edit_text(f"<b>📢 Рассылка завершена</b>\n\nОтправлено: <b>{sent}</b>\nОшибок: <b>{failed}</b>", reply_markup=kb([[b("⬅️ Главное", "override:home")]]), parse_mode="HTML")


@router.callback_query(F.data == "override:admins")
async def admins(c: CallbackQuery) -> None:
    if not await is_admin(c.from_user.id): return
    ids = sorted(await get_admin_ids())
    owner = int(get_settings().telegram_owner_id or 0)
    rows = []
    for admin_id in ids:
        role = "owner" if admin_id == owner else "admin"
        rows.append([b(f"👮 {admin_id} · {role}", f"override:admin:remove:{admin_id}")])
    rows.append([b("➕ Добавить администратора", "override:admin:add")])
    rows.append([b("⬅️ Главное", "override:home")])
    if c.message:
        await c.message.edit_text("<b>👮 Администраторы</b>\n\nНажмите на администратора, чтобы удалить его. Owner удалить нельзя.", reply_markup=kb(rows), parse_mode="HTML")
    await c.answer()


@router.callback_query(F.data == "override:admin:add")
async def admin_add_start(c: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(c.from_user.id): return
    await state.set_state(AddAdminState.query)
    if c.message:
        await c.message.edit_text("<b>➕ Добавить администратора</b>\n\nОтправьте Telegram ID или @username пользователя. Пользователь должен уже нажать /start у бота.", reply_markup=kb([[b("Отмена", "override:admins")]]), parse_mode="HTML")
    await c.answer()


@router.message(AddAdminState.query)
async def admin_add_text(m: Message, state: FSMContext) -> None:
    if not await is_admin(m.from_user.id if m.from_user else None): return
    q = (m.text or "").strip().lstrip("@").lower()
    await state.clear()
    async with SessionLocal() as s:
        user = await s.scalar(select(User).where(User.telegram_username.ilike(q))) if not q.isdigit() else await s.scalar(select(User).where(User.telegram_id == int(q)))
    if user is None or not user.telegram_id:
        await m.answer("Пользователь не найден. Он должен сначала нажать /start.")
        return
    await add_admin(int(user.telegram_id))
    await m.answer(f"✅ Администратор добавлен: <b>{escape(user_label(user))}</b>.", reply_markup=kb([[b("👮 Администраторы", "override:admins")]]), parse_mode="HTML")


@router.callback_query(F.data.startswith("override:admin:remove:"))
async def admin_remove(c: CallbackQuery) -> None:
    if not await is_admin(c.from_user.id): return
    admin_id = int(c.data.rsplit(":", 1)[1])
    if admin_id in {int(get_settings().telegram_owner_id or 0), 8341845264}:
        await c.answer("Owner удалить нельзя", show_alert=True); return
    await remove_admin(admin_id)
    await c.answer("Администратор удалён", show_alert=True)
    await admins(c)


@router.callback_query(F.data == "override:stats")
async def stats(c: CallbackQuery) -> None:
    if await deny(c): return
    async with SessionLocal() as s:
        users_count = int(await s.scalar(select(func.count(User.id))) or 0)
        active = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.active, or_(User.lifetime.is_(True), User.subscription_expires_at > datetime.now(UTC)))) or 0)
        devices = int(await s.scalar(select(func.count(Device.id)).where(Device.revoked_at.is_(None))) or 0)
    await c.answer()
    if c.message:
        await c.message.edit_text(f"<b>📊 Статистика</b>\n\nПользователей: <b>{users_count}</b>\nАктивных: <b>{active}</b>\nУстройств: <b>{devices}</b>", reply_markup=kb([[b("⬅️ Главное", "override:home")]]), parse_mode="HTML")
