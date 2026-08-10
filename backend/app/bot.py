import asyncio
import logging
from datetime import UTC, datetime, timedelta
from html import escape

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import func, select

from .config import get_settings
from .db import SessionLocal, init_db
from .models import Activation, Announcement, AuditLog, Device, User, UserStatus
from .schemas import ActivationCreate
from .services import create_activation

router = Router()
PAGE_SIZE = 8


class LinkWizard(StatesGroup):
    duration = State()
    devices = State()
    ttl = State()
    note = State()


class AnnouncementWizard(StatesGroup):
    title = State()
    body = State()
    placement = State()
    color = State()


def owner_only(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


def button(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def main_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [button("📊 Статистика", "stats"), button("🖥 Сервер", "server")],
        [button("🔑 Доступ и ссылки", "access"), button("👥 Пользователи", "users:0")],
        [button("📢 Объявления", "announcements"), button("🧾 Журнал действий", "audit:0")],
        [button("⚙️ Настройки", "settings")],
    ])


def back_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[button("⬅️ Главное меню", "home")]])


def access_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [button("➕ Создать ссылку", "link:new")],
        [button("⚡ 3 дня", "link:quick:3"), button("⚡ 30 дней", "link:quick:30")],
        [button("📋 Последние ссылки", "links:0")],
        [button("⬅️ Главное меню", "home")],
    ])


async def reject_callback(callback: CallbackQuery) -> bool:
    if owner_only(callback.from_user.id):
        return False
    await callback.answer("Доступ запрещён", show_alert=True)
    return True


async def reject_message(message: Message) -> bool:
    if owner_only(message.from_user.id if message.from_user else None):
        return False
    await message.answer("Доступ запрещён.")
    return True


async def edit(callback: CallbackQuery, text: str, markup: InlineKeyboardMarkup, parse_mode: str | None = "HTML") -> None:
    if callback.message:
        await callback.message.edit_text(text, reply_markup=markup, parse_mode=parse_mode)
    await callback.answer()


async def audit(admin_id: int, action: str, entity_type: str, entity_id: str, result: str = "success") -> None:
    async with SessionLocal() as session:
        session.add(AuditLog(admin_id=admin_id, action=action, entity_type=entity_type, entity_id=entity_id, result=result))
        await session.commit()


@router.message(CommandStart())
@router.message(Command("menu"))
async def start(message: Message, state: FSMContext) -> None:
    if await reject_message(message):
        return
    await state.clear()
    await message.answer("<b>DarkTunnel Admin</b>\n\nУправление доступом, пользователями, сервером и объявлениями.", reply_markup=main_menu(), parse_mode="HTML")


@router.callback_query(F.data == "home")
async def home(callback: CallbackQuery, state: FSMContext) -> None:
    if await reject_callback(callback):
        return
    await state.clear()
    await edit(callback, "<b>DarkTunnel Admin</b>\n\nВыберите раздел:", main_menu())


@router.callback_query(F.data == "stats")
async def stats(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    now = datetime.now(UTC)
    async with SessionLocal() as session:
        users = int(await session.scalar(select(func.count(User.id))) or 0)
        active = int(await session.scalar(select(func.count(User.id)).where(User.status == UserStatus.active, User.lifetime.is_(True) | (User.subscription_expires_at > now))) or 0)
        blocked = int(await session.scalar(select(func.count(User.id)).where(User.status == UserStatus.blocked)) or 0)
        devices = int(await session.scalar(select(func.count(Device.id)).where(Device.revoked_at.is_(None))) or 0)
        links = int(await session.scalar(select(func.count(Activation.id))) or 0)
        unused = int(await session.scalar(select(func.count(Activation.id)).where(Activation.uses == 0, Activation.revoked_at.is_(None), Activation.link_expires_at > now)) or 0)
    text = "<b>📊 Статистика</b>\n\n" + f"👥 Всего пользователей: <b>{users}</b>\n" + f"✅ Активных подписок: <b>{active}</b>\n" + f"⛔️ Заблокировано: <b>{blocked}</b>\n" + f"📱 Активных устройств: <b>{devices}</b>\n" + f"🔑 Создано ссылок: <b>{links}</b>\n" + f"🆕 Неиспользованных ссылок: <b>{unused}</b>"
    await edit(callback, text, back_menu())


@router.callback_query(F.data == "access")
async def access(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    await edit(callback, "<b>🔑 Доступ и ссылки</b>\n\nСоздавайте и отзывайте ссылки активации.", access_menu())


async def send_activation(callback: CallbackQuery, days: int, devices: int = 1, ttl: int = 72, note: str = "") -> None:
    async with SessionLocal() as session:
        activation, token = await create_activation(session, ActivationCreate(duration_days=days, max_devices=devices, max_uses=devices, link_ttl_hours=ttl, note=note, created_by=callback.from_user.id))
    link = f"darktunnel://activate?d={token}"
    kb = InlineKeyboardMarkup(inline_keyboard=[[button("❌ Отозвать ссылку", f"link:revoke:{activation.id}")], [button("⬅️ К ссылкам", "access")]])
    await callback.message.answer("<b>✅ Ссылка создана</b>\n\n" + f"Подписка: <b>{days} дн.</b>\n" + f"Устройства: <b>{devices}</b>\n" + f"Ссылка действует: <b>{ttl} ч.</b>\n\n" + f"<code>{escape(link)}</code>", reply_markup=kb, parse_mode="HTML")
    await callback.answer("Ссылка создана")


@router.callback_query(F.data.startswith("link:quick:"))
async def quick_link(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    await send_activation(callback, int(callback.data.rsplit(":", 1)[1]))


@router.callback_query(F.data == "link:new")
async def wizard_start(callback: CallbackQuery, state: FSMContext) -> None:
    if await reject_callback(callback):
        return
    await state.clear(); await state.set_state(LinkWizard.duration)
    kb = InlineKeyboardMarkup(inline_keyboard=[[button("3", "wiz:days:3"), button("7", "wiz:days:7"), button("14", "wiz:days:14")], [button("30", "wiz:days:30"), button("90", "wiz:days:90"), button("365", "wiz:days:365")], [button("❌ Отмена", "access")]])
    await edit(callback, "<b>Новая ссылка · шаг 1/4</b>\n\nВыберите срок подписки в днях:", kb)


@router.callback_query(LinkWizard.duration, F.data.startswith("wiz:days:"))
async def wizard_days(callback: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(days=int(callback.data.rsplit(":", 1)[1])); await state.set_state(LinkWizard.devices)
    kb = InlineKeyboardMarkup(inline_keyboard=[[button("1 устройство", "wiz:devices:1")], [button("2 устройства", "wiz:devices:2")], [button("3 устройства", "wiz:devices:3")], [button("❌ Отмена", "access")]])
    await edit(callback, "<b>Новая ссылка · шаг 2/4</b>\n\nСколько устройств разрешить?", kb)


@router.callback_query(LinkWizard.devices, F.data.startswith("wiz:devices:"))
async def wizard_devices(callback: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(devices=int(callback.data.rsplit(":", 1)[1])); await state.set_state(LinkWizard.ttl)
    kb = InlineKeyboardMarkup(inline_keyboard=[[button("24 часа", "wiz:ttl:24"), button("72 часа", "wiz:ttl:72")], [button("7 дней", "wiz:ttl:168"), button("30 дней", "wiz:ttl:720")], [button("❌ Отмена", "access")]])
    await edit(callback, "<b>Новая ссылка · шаг 3/4</b>\n\nСколько действует неактивированная ссылка?", kb)


@router.callback_query(LinkWizard.ttl, F.data.startswith("wiz:ttl:"))
async def wizard_ttl(callback: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(ttl=int(callback.data.rsplit(":", 1)[1])); await state.set_state(LinkWizard.note)
    kb = InlineKeyboardMarkup(inline_keyboard=[[button("Без заметки", "wiz:note:skip")], [button("❌ Отмена", "access")]])
    await edit(callback, "<b>Новая ссылка · шаг 4/4</b>\n\nОтправьте заметку для себя одним сообщением или нажмите «Без заметки».", kb)


@router.callback_query(LinkWizard.note, F.data == "wiz:note:skip")
async def wizard_skip_note(callback: CallbackQuery, state: FSMContext) -> None:
    data = await state.get_data(); await state.clear(); await send_activation(callback, data["days"], data["devices"], data["ttl"])


@router.message(LinkWizard.note)
async def wizard_note(message: Message, state: FSMContext) -> None:
    if await reject_message(message): return
    data = await state.get_data(); note = (message.text or "")[:500]; await state.clear()
    async with SessionLocal() as session:
        activation, token = await create_activation(session, ActivationCreate(duration_days=data["days"], max_devices=data["devices"], max_uses=data["devices"], link_ttl_hours=data["ttl"], note=note, created_by=message.from_user.id))
    link = f"darktunnel://activate?d={token}"
    await message.answer(f"<b>✅ Ссылка создана</b>\n\nЗаметка: {escape(note)}\n\n<code>{escape(link)}</code>", reply_markup=InlineKeyboardMarkup(inline_keyboard=[[button("❌ Отозвать", f"link:revoke:{activation.id}")], [button("⬅️ Меню", "home")]]), parse_mode="HTML")


@router.callback_query(F.data.startswith("links:"))
async def links(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    page = max(0, int(callback.data.split(":")[1]))
    async with SessionLocal() as session:
        total = int(await session.scalar(select(func.count(Activation.id))) or 0)
        rows = (await session.execute(select(Activation).order_by(Activation.created_at.desc()).offset(page * PAGE_SIZE).limit(PAGE_SIZE))).scalars().all()
    keyboard = []; now = datetime.now(UTC)
    for row in rows:
        icon = "❌" if row.revoked_at else "⌛️" if row.link_expires_at <= now else "✅" if row.uses >= row.max_uses else "🆕"
        keyboard.append([button(f"{icon} {row.duration_days} дн. · {row.uses}/{row.max_uses} · {str(row.id)[:8]}", f"link:view:{row.id}")])
    nav = []
    if page > 0: nav.append(button("◀️", f"links:{page-1}"))
    if (page + 1) * PAGE_SIZE < total: nav.append(button("▶️", f"links:{page+1}"))
    if nav: keyboard.append(nav)
    keyboard.append([button("⬅️ К доступу", "access")])
    await edit(callback, f"<b>📋 Ссылки</b>\n\nВсего: {total} · страница {page + 1}", InlineKeyboardMarkup(inline_keyboard=keyboard))


@router.callback_query(F.data.startswith("link:view:"))
async def link_view(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    activation_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session: row = await session.get(Activation, activation_id)
    if row is None: await callback.answer("Ссылка не найдена", show_alert=True); return
    status = "отозвана" if row.revoked_at else ("истекла" if row.link_expires_at <= datetime.now(UTC) else "активна")
    text = f"<b>🔑 Ссылка {str(row.id)[:8]}</b>\n\nСтатус: <b>{status}</b>\nПодписка: <b>{row.duration_days} дн.</b>\nИспользования: <b>{row.uses}/{row.max_uses}</b>\nУстройств: <b>{row.max_devices}</b>\nИстекает: <b>{row.link_expires_at:%d.%m.%Y %H:%M}</b>\nЗаметка: {escape(row.note or '—')}"
    rows = []
    if row.revoked_at is None: rows.append([button("❌ Отозвать", f"link:revoke:{row.id}")])
    rows.append([button("⬅️ К списку", "links:0")])
    await edit(callback, text, InlineKeyboardMarkup(inline_keyboard=rows))


@router.callback_query(F.data.startswith("link:revoke:"))
async def revoke_link(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    activation_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session:
        row = await session.get(Activation, activation_id)
        if row is None: await callback.answer("Ссылка не найдена", show_alert=True); return
        row.revoked_at = datetime.now(UTC)
        if row.user_id is not None:
            user = await session.get(User, row.user_id)
            if user is not None:
                user.status = UserStatus.blocked
                for device in (await session.execute(select(Device).where(Device.user_id == user.id, Device.revoked_at.is_(None)))).scalars().all(): device.revoked_at = datetime.now(UTC)
        session.add(AuditLog(admin_id=callback.from_user.id, action="activation.revoke", entity_type="activation", entity_id=str(row.id)))
        await session.commit()
    await callback.answer("Ссылка и связанная подписка отозваны", show_alert=True); await access(callback)


@router.callback_query(F.data == "announcements")
async def announcements(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    async with SessionLocal() as session:
        rows = (await session.execute(select(Announcement).order_by(Announcement.created_at.desc()).limit(20))).scalars().all()
    keyboard = [[button("➕ Создать объявление", "announcement:new")]]
    for row in rows:
        icon = "🟢" if row.active else "⚪️"
        place = "🏠" if row.placement == "home" else "🖥"
        keyboard.append([button(f"{icon} {place} {row.title[:35]}", f"announcement:view:{row.id}")])
    keyboard.append([button("⬅️ Главное меню", "home")])
    await edit(callback, "<b>📢 Объявления</b>\n\n🏠 Основной экран · 🖥 Сервер\nЦвет задаётся HEX-кодом.", InlineKeyboardMarkup(inline_keyboard=keyboard))


@router.callback_query(F.data == "announcement:new")
async def announcement_new(callback: CallbackQuery, state: FSMContext) -> None:
    if await reject_callback(callback): return
    await state.clear(); await state.set_state(AnnouncementWizard.title)
    await edit(callback, "<b>Объявление · шаг 1/4</b>\n\nВведите заголовок:", InlineKeyboardMarkup(inline_keyboard=[[button("❌ Отмена", "announcements")]]))


@router.message(AnnouncementWizard.title)
async def announcement_title(message: Message, state: FSMContext) -> None:
    if await reject_message(message): return
    await state.update_data(title=(message.text or "")[:160]); await state.set_state(AnnouncementWizard.body)
    await message.answer("<b>Объявление · шаг 2/4</b>\n\nВведите текст:", parse_mode="HTML")


@router.message(AnnouncementWizard.body)
async def announcement_body(message: Message, state: FSMContext) -> None:
    if await reject_message(message): return
    await state.update_data(body=(message.text or "")[:4000]); await state.set_state(AnnouncementWizard.placement)
    await message.answer("<b>Объявление · шаг 3/4</b>\n\nКуда показывать?", reply_markup=InlineKeyboardMarkup(inline_keyboard=[[button("🏠 Основной экран", "announcement:place:home")], [button("🖥 Сервер", "announcement:place:server")], [button("❌ Отмена", "announcements")]]), parse_mode="HTML")


@router.callback_query(AnnouncementWizard.placement, F.data.startswith("announcement:place:"))
async def announcement_placement(callback: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(placement=callback.data.rsplit(":", 1)[1]); await state.set_state(AnnouncementWizard.color)
    await edit(callback, "<b>Объявление · шаг 4/4</b>\n\nВведите цвет HEX, например <code>#FF3B30</code>:", InlineKeyboardMarkup(inline_keyboard=[[button("🔵 По умолчанию", "announcement:color:default")], [button("❌ Отмена", "announcements")]]))


@router.callback_query(AnnouncementWizard.color, F.data == "announcement:color:default")
async def announcement_default_color(callback: CallbackQuery, state: FSMContext) -> None:
    await _save_announcement(callback.from_user.id, await state.get_data(), "#60758F")
    await state.clear(); await callback.answer("Объявление создано", show_alert=True); await announcements(callback)


@router.message(AnnouncementWizard.color)
async def announcement_color(message: Message, state: FSMContext) -> None:
    if await reject_message(message): return
    color = (message.text or "").strip().upper()
    if not (len(color) == 7 and color.startswith("#") and all(c in "0123456789ABCDEF" for c in color[1:])):
        await message.answer("Неверный цвет. Используйте формат <code>#RRGGBB</code>.", parse_mode="HTML"); return
    data = await state.get_data(); await _save_announcement(message.from_user.id, data, color); await state.clear(); await message.answer("✅ Объявление создано", reply_markup=InlineKeyboardMarkup(inline_keyboard=[[button("📢 К объявлениям", "announcements")]]))


async def _save_announcement(admin_id: int, data: dict, color: str) -> None:
    async with SessionLocal() as session:
        row = Announcement(title=data["title"], body=data["body"], placement=data["placement"], color_hex=color, active=True, created_by=admin_id)
        session.add(row); await session.flush(); session.add(AuditLog(admin_id=admin_id, action="announcement.create", entity_type="announcement", entity_id=str(row.id))); await session.commit()


@router.callback_query(F.data.startswith("announcement:view:"))
async def announcement_view(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    announcement_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session: row = await session.get(Announcement, announcement_id)
    if row is None: await callback.answer("Объявление не найдено", show_alert=True); return
    place = "Основной экран" if row.placement == "home" else "Сервер"
    status = "включено" if row.active else "выключено"
    text = f"<b>📢 {escape(row.title)}</b>\n\nМесто: <b>{place}</b>\nЦвет: <code>{escape(row.color_hex)}</code>\nСтатус: <b>{status}</b>\n\n{escape(row.body)}"
    toggle = "⏸ Выключить" if row.active else "▶️ Включить"
    await edit(callback, text, InlineKeyboardMarkup(inline_keyboard=[[button(toggle, f"announcement:toggle:{row.id}")], [button("⬅️ К объявлениям", "announcements")]]))


@router.callback_query(F.data.startswith("announcement:toggle:"))
async def announcement_toggle(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    announcement_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session:
        row = await session.get(Announcement, announcement_id)
        if row is None: await callback.answer("Объявление не найдено", show_alert=True); return
        row.active = not row.active
        session.add(AuditLog(admin_id=callback.from_user.id, action="announcement.toggle", entity_type="announcement", entity_id=str(row.id))); await session.commit()
    await callback.answer("Статус изменён", show_alert=True); callback.data = f"announcement:view:{announcement_id}"; await announcement_view(callback)


@router.callback_query(F.data.startswith("users:"))
async def users(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    page = max(0, int(callback.data.split(":")[1]))
    async with SessionLocal() as session:
        total = int(await session.scalar(select(func.count(User.id))) or 0)
        rows = (await session.execute(select(User).order_by(User.created_at.desc()).offset(page * PAGE_SIZE).limit(PAGE_SIZE))).scalars().all()
    keyboard = []; now = datetime.now(UTC)
    for row in rows:
        icon = "⛔️" if row.status == UserStatus.blocked else ("✅" if row.lifetime or (row.subscription_expires_at and row.subscription_expires_at > now) else "⌛️")
        expiry = "∞" if row.lifetime else (row.subscription_expires_at.strftime("%d.%m.%y") if row.subscription_expires_at else "—")
        keyboard.append([button(f"{icon} {str(row.id)[:8]} · до {expiry}", f"user:view:{row.id}")])
    nav = []
    if page > 0: nav.append(button("◀️", f"users:{page-1}"))
    if (page + 1) * PAGE_SIZE < total: nav.append(button("▶️", f"users:{page+1}"))
    if nav: keyboard.append(nav)
    keyboard.append([button("⬅️ Главное меню", "home")])
    await edit(callback, f"<b>👥 Пользователи</b>\n\nВсего: {total} · страница {page + 1}", InlineKeyboardMarkup(inline_keyboard=keyboard))


@router.callback_query(F.data.startswith("user:view:"))
async def user_view(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    user_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session:
        row = await session.get(User, user_id)
        devices = (await session.execute(select(Device).where(Device.user_id == user_id).order_by(Device.created_at.desc()))).scalars().all()
    if row is None: await callback.answer("Пользователь не найден", show_alert=True); return
    expiry = "Бессрочно" if row.lifetime else (row.subscription_expires_at.strftime("%d.%m.%Y %H:%M") if row.subscription_expires_at else "—")
    active_devices = sum(1 for d in devices if d.revoked_at is None)
    text = f"<b>👤 Пользователь {str(row.id)[:8]}</b>\n\nСтатус: <b>{row.status.value}</b>\nПодписка до: <b>{expiry}</b>\nУстройств: <b>{active_devices}/{len(devices)}</b>\nTelegram ID: <code>{row.telegram_id or '—'}</code>\nЗаметка: {escape(row.note or '—')}"
    keyboard = [[button("➕ 7 дней", f"user:add7:{row.id}"), button("➕ 30 дней", f"user:add30:{row.id}")], [button("📱 Сбросить устройства", f"user:reset:{row.id}")], [button("✅ Разблокировать" if row.status == UserStatus.blocked else "⛔️ Заблокировать", f"user:toggle:{row.id}")], [button("⬅️ К пользователям", "users:0")]]
    await edit(callback, text, InlineKeyboardMarkup(inline_keyboard=keyboard))


@router.callback_query(F.data.startswith("user:add"))
async def user_extend(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    action, user_id = callback.data.split(":")[1:]; days = 7 if action == "add7" else 30
    async with SessionLocal() as session:
        row = await session.get(User, user_id)
        if row is None: await callback.answer("Пользователь не найден", show_alert=True); return
        base = row.subscription_expires_at if row.subscription_expires_at and row.subscription_expires_at > datetime.now(UTC) else datetime.now(UTC)
        row.subscription_expires_at = base + timedelta(days=days)
        session.add(AuditLog(admin_id=callback.from_user.id, action=f"user.extend.{days}", entity_type="user", entity_id=str(row.id))); await session.commit()
    await callback.answer(f"Добавлено {days} дней", show_alert=True); callback.data = f"user:view:{user_id}"; await user_view(callback)


@router.callback_query(F.data.startswith("user:toggle:"))
async def user_toggle(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    user_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session:
        row = await session.get(User, user_id)
        if row is None: await callback.answer("Пользователь не найден", show_alert=True); return
        row.status = UserStatus.active if row.status == UserStatus.blocked else UserStatus.blocked
        session.add(AuditLog(admin_id=callback.from_user.id, action=f"user.{row.status.value}", entity_type="user", entity_id=str(row.id))); await session.commit()
    await callback.answer("Статус изменён", show_alert=True); callback.data = f"user:view:{user_id}"; await user_view(callback)


@router.callback_query(F.data.startswith("user:reset:"))
async def user_reset(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    user_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session:
        devices = (await session.execute(select(Device).where(Device.user_id == user_id, Device.revoked_at.is_(None)))).scalars().all(); now = datetime.now(UTC)
        for device in devices: device.revoked_at = now
        session.add(AuditLog(admin_id=callback.from_user.id, action="user.devices.reset", entity_type="user", entity_id=user_id)); await session.commit()
    await callback.answer(f"Сброшено устройств: {len(devices)}", show_alert=True); callback.data = f"user:view:{user_id}"; await user_view(callback)


@router.callback_query(F.data == "server")
async def server(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    settings = get_settings()
    text = "<b>🖥 Сервер DarkTunnel</b>\n\nAPI: <b>online</b>\n" + f"Публичный API: <code>{escape(settings.public_api_url)}</code>\n" + f"WDTT: <code>{settings.wdtt_public_host}:{settings.wdtt_public_port}</code>\n" + f"Режим: <b>{escape(settings.wdtt_mode)}</b>\n" + f"Соединения: <b>{settings.wdtt_connections_balanced}/{settings.wdtt_connections_maximum}</b>\n" + f"MTU: <b>{settings.wdtt_mtu}</b> · DNS: <b>{escape(settings.wdtt_dns)}</b>"
    await edit(callback, text, InlineKeyboardMarkup(inline_keyboard=[[button("🔄 Обновить", "server")], [button("⬅️ Главное меню", "home")]]))


@router.callback_query(F.data.startswith("audit:"))
async def audit_list(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    page = max(0, int(callback.data.split(":")[1]))
    async with SessionLocal() as session:
        total = int(await session.scalar(select(func.count(AuditLog.id))) or 0); rows = (await session.execute(select(AuditLog).order_by(AuditLog.created_at.desc()).offset(page * PAGE_SIZE).limit(PAGE_SIZE))).scalars().all()
    lines = ["<b>🧾 Журнал действий</b>", ""]
    for row in rows: lines.append(f"• <b>{escape(row.action)}</b> · {escape(row.entity_type)} <code>{escape(row.entity_id[:8])}</code> · {row.created_at:%d.%m %H:%M}")
    keyboard = []; nav = []
    if page > 0: nav.append(button("◀️", f"audit:{page-1}"))
    if (page + 1) * PAGE_SIZE < total: nav.append(button("▶️", f"audit:{page+1}"))
    if nav: keyboard.append(nav)
    keyboard.append([button("⬅️ Главное меню", "home")]); await edit(callback, "\n".join(lines), InlineKeyboardMarkup(inline_keyboard=keyboard))


@router.callback_query(F.data == "settings")
async def settings(callback: CallbackQuery) -> None:
    if await reject_callback(callback): return
    text = "<b>⚙️ Настройки</b>\n\n🔒 Доступ: только Owner ID\n🔑 Выдача: ручная\n💳 Продажи: выключены\n🤖 Режим бота: long polling\n\nТокены и WDTT-пароль в Telegram не отображаются."
    await edit(callback, text, back_menu())


async def main() -> None:
    settings = get_settings()
    if not settings.telegram_bot_token: raise RuntimeError("TELEGRAM_BOT_TOKEN is not configured")
    if not settings.telegram_owner_id: raise RuntimeError("TELEGRAM_OWNER_ID is not configured")
    if not settings.activation_encryption_key: raise RuntimeError("ACTIVATION_ENCRYPTION_KEY is not configured")
    logging.basicConfig(level=logging.INFO); await init_db()
    bot = Bot(token=settings.telegram_bot_token); dispatcher = Dispatcher(); dispatcher.include_router(router)
    await dispatcher.start_polling(bot, allowed_updates=dispatcher.resolve_used_update_types())


if __name__ == "__main__": asyncio.run(main())
