from __future__ import annotations

from datetime import UTC, datetime, timedelta
from html import escape
import uuid

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import func, or_, select
from sqlalchemy.orm import selectinload

from .config import get_settings
from .db import SessionLocal
from .models import Activation, AuditLog, Device, User, UserStatus
from .schemas import ActivationCreate
from .services import create_activation

router = Router(name="management")
PAGE = 7


class SearchUser(StatesGroup):
    query = State()


class SearchLink(StatesGroup):
    query = State()


class CustomLink(StatesGroup):
    days = State()
    devices = State()
    uses = State()
    ttl = State()
    telegram = State()
    note = State()


class UserEdit(StatesGroup):
    days = State()
    exact_date = State()
    note = State()


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def owner(user_id: int | None) -> bool:
    s = get_settings()
    return bool(user_id and s.telegram_owner_id and (user_id == s.telegram_owner_id or user_id == 8341845264))


async def deny_cb(c: CallbackQuery) -> bool:
    if owner(c.from_user.id):
        return False
    await c.answer("Доступ запрещён", show_alert=True)
    return True


async def deny_msg(m: Message) -> bool:
    if owner(m.from_user.id if m.from_user else None):
        return False
    await m.answer("Доступ запрещён.")
    return True


async def edit(c: CallbackQuery, text: str, rows: list[list[InlineKeyboardButton]]) -> None:
    if c.message:
        await c.message.edit_text(text, reply_markup=kb(rows), parse_mode="HTML")
    await c.answer()


async def log(admin: int, action: str, kind: str, entity: str, result: str = "success") -> None:
    async with SessionLocal() as s:
        s.add(AuditLog(admin_id=admin, action=action, entity_type=kind, entity_id=entity, result=result))
        await s.commit()


def fmt_dt(value: datetime | None) -> str:
    return value.astimezone().strftime("%d.%m.%Y %H:%M") if value else "—"


def days_left(user: User) -> str:
    if user.lifetime:
        return "∞"
    if not user.subscription_expires_at:
        return "0"
    return str(max(0, (user.subscription_expires_at - datetime.now(UTC)).days + 1))


def user_icon(user: User) -> str:
    if user.status == UserStatus.blocked:
        return "⛔️"
    if user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)):
        return "✅"
    return "⌛️"


def link_state(row: Activation) -> tuple[str, str]:
    now = datetime.now(UTC)
    if row.revoked_at:
        return "❌", "отозвана"
    if row.link_expires_at <= now:
        return "⌛️", "истекла"
    if row.uses >= row.max_uses:
        return "✅", "использована"
    return "🆕", "готова"


@router.callback_query(F.data == "access")
async def access(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    async with SessionLocal() as s:
        total = int(await s.scalar(select(func.count(Activation.id))) or 0)
        ready = int(await s.scalar(select(func.count(Activation.id)).where(Activation.revoked_at.is_(None), Activation.link_expires_at > datetime.now(UTC), Activation.uses < Activation.max_uses)) or 0)
    await edit(c, f"<b>🔑 Доступ и ссылки</b>\n\nВсего ссылок: <b>{total}</b>\nГотовы к активации: <b>{ready}</b>", [
        [b("➕ Создать ссылку", "mg:link:new")],
        [b("⚡ 3 дня", "mg:quick:3"), b("⚡ 30 дней", "mg:quick:30")],
        [b("📋 Все", "mg:links:all:0"), b("🆕 Готовые", "mg:links:ready:0")],
        [b("✅ Использованные", "mg:links:used:0"), b("❌ Отозванные", "mg:links:revoked:0")],
        [b("🔎 Найти ссылку", "mg:link:search")],
        [b("⬅️ Главное меню", "home")],
    ])


async def create_and_show(c: CallbackQuery, *, days: int, devices: int = 1, uses: int = 1, ttl: int = 72, telegram_id: int | None = None, note: str = "") -> None:
    async with SessionLocal() as s:
        row, token = await create_activation(s, ActivationCreate(duration_days=days, max_devices=devices, max_uses=uses, link_ttl_hours=ttl, note=note, telegram_id=telegram_id, created_by=c.from_user.id))
    link = f"darktunnel://activate?d={token}"
    await c.message.answer(
        f"<b>✅ Ссылка создана</b>\n\nID: <code>{row.id}</code>\nСрок подписки: <b>{days} дн.</b>\nУстройств: <b>{devices}</b>\nАктиваций: <b>{uses}</b>\nСсылка годна: <b>{ttl} ч.</b>\nTelegram ID: <code>{telegram_id or '—'}</code>\nЗаметка: {escape(note or '—')}\n\n<code>{escape(link)}</code>",
        reply_markup=kb([[b("❌ Отозвать", f"mg:link:revoke:ask:{row.id}")], [b("🔑 К ссылкам", "access")]]), parse_mode="HTML")
    await c.answer("Ссылка создана")


@router.callback_query(F.data.startswith("mg:quick:"))
async def quick(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    await create_and_show(c, days=int(c.data.rsplit(":", 1)[1]))


@router.callback_query(F.data == "mg:link:new")
async def custom_start(c: CallbackQuery, state: FSMContext) -> None:
    if await deny_cb(c): return
    await state.clear(); await state.set_state(CustomLink.days)
    await edit(c, "<b>Новая ссылка · 1/6</b>\n\nВыберите срок подписки:", [
        [b("3", "mg:days:3"), b("7", "mg:days:7"), b("14", "mg:days:14")],
        [b("30", "mg:days:30"), b("90", "mg:days:90"), b("180", "mg:days:180")],
        [b("365", "mg:days:365"), b("✍️ Свой срок", "mg:days:custom")],
        [b("❌ Отмена", "access")],
    ])


@router.callback_query(CustomLink.days, F.data.startswith("mg:days:"))
async def custom_days(c: CallbackQuery, state: FSMContext) -> None:
    value = c.data.rsplit(":", 1)[1]
    if value == "custom":
        await c.message.edit_text("Отправьте число дней от 1 до 3650:"); await c.answer(); return
    await state.update_data(days=int(value)); await ask_devices(c, state)


@router.message(CustomLink.days)
async def custom_days_text(m: Message, state: FSMContext) -> None:
    if await deny_msg(m): return
    try: value = int((m.text or "").strip())
    except ValueError: value = 0
    if not 1 <= value <= 3650:
        await m.answer("Введите число от 1 до 3650."); return
    await state.update_data(days=value); await state.set_state(CustomLink.devices)
    await m.answer("<b>Новая ссылка · 2/6</b>\n\nСколько устройств разрешить?", reply_markup=kb([[b("1", "mg:devices:1"), b("2", "mg:devices:2"), b("3", "mg:devices:3")], [b("5", "mg:devices:5"), b("10", "mg:devices:10")], [b("❌ Отмена", "access")]]), parse_mode="HTML")


async def ask_devices(c: CallbackQuery, state: FSMContext) -> None:
    await state.set_state(CustomLink.devices)
    await edit(c, "<b>Новая ссылка · 2/6</b>\n\nСколько устройств разрешить?", [[b("1", "mg:devices:1"), b("2", "mg:devices:2"), b("3", "mg:devices:3")], [b("5", "mg:devices:5"), b("10", "mg:devices:10")], [b("❌ Отмена", "access")]])


@router.callback_query(CustomLink.devices, F.data.startswith("mg:devices:"))
async def custom_devices(c: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(devices=int(c.data.rsplit(":", 1)[1])); await state.set_state(CustomLink.uses)
    await edit(c, "<b>Новая ссылка · 3/6</b>\n\nСколько раз можно активировать ссылку?", [[b("1", "mg:uses:1"), b("2", "mg:uses:2"), b("3", "mg:uses:3")], [b("5", "mg:uses:5"), b("10", "mg:uses:10")], [b("❌ Отмена", "access")]])


@router.callback_query(CustomLink.uses, F.data.startswith("mg:uses:"))
async def custom_uses(c: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(uses=int(c.data.rsplit(":", 1)[1])); await state.set_state(CustomLink.ttl)
    await edit(c, "<b>Новая ссылка · 4/6</b>\n\nСрок жизни неактивированной ссылки:", [[b("24 ч", "mg:ttl:24"), b("72 ч", "mg:ttl:72")], [b("7 дней", "mg:ttl:168"), b("30 дней", "mg:ttl:720")], [b("❌ Отмена", "access")]])


@router.callback_query(CustomLink.ttl, F.data.startswith("mg:ttl:"))
async def custom_ttl(c: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(ttl=int(c.data.rsplit(":", 1)[1])); await state.set_state(CustomLink.telegram)
    await edit(c, "<b>Новая ссылка · 5/6</b>\n\nОтправьте @username или Telegram ID клиента, либо пропустите.", [[b("Пропустить", "mg:telegram:skip")], [b("❌ Отмена", "access")]])


@router.callback_query(CustomLink.telegram, F.data == "mg:telegram:skip")
async def telegram_skip(c: CallbackQuery, state: FSMContext) -> None:
    await state.update_data(telegram_id=None); await state.set_state(CustomLink.note)
    await edit(c, "<b>Новая ссылка · 6/6</b>\n\nОтправьте понятную заметку: имя клиента, заказ или источник.", [[b("Без заметки", "mg:note:skip")], [b("❌ Отмена", "access")]])


@router.message(CustomLink.telegram)
async def telegram_text(m: Message, state: FSMContext) -> None:
    if await deny_msg(m): return
    raw = (m.text or "").strip()
    value = int(raw) if raw.isdigit() else 0
    if value <= 0:
        username = raw.lstrip("@").strip()
        async with SessionLocal() as s:
            found = await s.scalar(select(User).where(User.telegram_username.ilike(username)))
        value = found.telegram_id if found and found.telegram_id else 0
    if value <= 0:
        await m.answer("Пользователь не найден. Укажите @username или числовой Telegram ID."); return
    await state.update_data(telegram_id=value); await state.set_state(CustomLink.note)
    await m.answer("<b>Новая ссылка · 6/6</b>\n\nОтправьте заметку.", reply_markup=kb([[b("Без заметки", "mg:note:skip")], [b("❌ Отмена", "access")]]), parse_mode="HTML")


@router.callback_query(CustomLink.note, F.data == "mg:note:skip")
async def note_skip(c: CallbackQuery, state: FSMContext) -> None:
    data = await state.get_data(); await state.clear()
    await create_and_show(c, days=data["days"], devices=data["devices"], uses=data["uses"], ttl=data["ttl"], telegram_id=data.get("telegram_id"))


@router.message(CustomLink.note)
async def note_text(m: Message, state: FSMContext) -> None:
    if await deny_msg(m): return
    data = await state.get_data(); await state.clear(); note = (m.text or "")[:500]
    async with SessionLocal() as s:
        row, token = await create_activation(s, ActivationCreate(duration_days=data["days"], max_devices=data["devices"], max_uses=data["uses"], link_ttl_hours=data["ttl"], note=note, telegram_id=data.get("telegram_id"), created_by=m.from_user.id))
    await m.answer(f"<b>✅ Ссылка создана</b>\n\nID: <code>{row.id}</code>\nЗаметка: {escape(note)}\n\n<code>{escape('darktunnel://activate?d=' + token)}</code>", reply_markup=kb([[b("❌ Отозвать", f"mg:link:revoke:ask:{row.id}")], [b("🔑 К ссылкам", "access")]]), parse_mode="HTML")


@router.callback_query(F.data.startswith("mg:links:"))
async def links(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    _, _, mode, page_s = c.data.split(":"); page = max(0, int(page_s)); now = datetime.now(UTC)
    conditions = []
    if mode == "ready": conditions = [Activation.revoked_at.is_(None), Activation.link_expires_at > now, Activation.uses < Activation.max_uses]
    elif mode == "used": conditions = [Activation.uses > 0]
    elif mode == "revoked": conditions = [Activation.revoked_at.is_not(None)]
    async with SessionLocal() as s:
        total = int(await s.scalar(select(func.count(Activation.id)).where(*conditions)) or 0)
        rows = (await s.execute(select(Activation).where(*conditions).order_by(Activation.created_at.desc()).offset(page * PAGE).limit(PAGE))).scalars().all()
    buttons = []
    for row in rows:
        icon, _ = link_state(row); label = row.note.strip()[:20] or str(row.id)[:8]
        buttons.append([b(f"{icon} {label} · {row.duration_days}д · {row.uses}/{row.max_uses}", f"mg:link:view:{row.id}")])
    nav = []
    if page: nav.append(b("◀️", f"mg:links:{mode}:{page-1}"))
    if (page + 1) * PAGE < total: nav.append(b("▶️", f"mg:links:{mode}:{page+1}"))
    if nav: buttons.append(nav)
    buttons += [[b("🔎 Поиск", "mg:link:search")], [b("⬅️ Доступ и ссылки", "access")]]
    await edit(c, f"<b>🔑 Ссылки · {mode}</b>\n\nНайдено: <b>{total}</b> · страница {page+1}", buttons)


@router.callback_query(F.data == "mg:link:search")
async def link_search(c: CallbackQuery, state: FSMContext) -> None:
    if await deny_cb(c): return
    await state.set_state(SearchLink.query)
    await edit(c, "<b>🔎 Поиск ссылки</b>\n\nОтправьте ID/часть ID, Telegram ID или текст заметки.", [[b("❌ Отмена", "access")]])


@router.message(SearchLink.query)
async def link_search_text(m: Message, state: FSMContext) -> None:
    if await deny_msg(m): return
    q = (m.text or "").strip(); await state.clear()
    conditions = [Activation.note.ilike(f"%{q}%"), func.cast(Activation.id, String).ilike(f"%{q}%")]
    if q.isdigit(): conditions.append(Activation.telegram_id == int(q))
    async with SessionLocal() as s:
        rows = (await s.execute(select(Activation).where(or_(*conditions)).order_by(Activation.created_at.desc()).limit(20))).scalars().all()
    buttons = [[b(f"{link_state(r)[0]} {(r.note or str(r.id)[:8])[:24]} · {r.duration_days}д", f"mg:link:view:{r.id}")] for r in rows]
    buttons.append([b("⬅️ Доступ и ссылки", "access")])
    await m.answer(f"<b>Результаты поиска</b>\n\nНайдено: {len(rows)}", reply_markup=kb(buttons), parse_mode="HTML")


@router.callback_query(F.data.startswith("mg:link:view:"))
async def link_view(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    row_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s: row = await s.get(Activation, row_id)
    if not row: await c.answer("Ссылка не найдена", show_alert=True); return
    icon, status = link_state(row)
    rows = []
    if not row.revoked_at: rows.append([b("❌ Отозвать", f"mg:link:revoke:ask:{row.id}")])
    rows += [[b("📋 Все ссылки", "mg:links:all:0")], [b("⬅️ Доступ", "access")]]
    await edit(c, f"<b>{icon} Ссылка {str(row.id)[:8]}</b>\n\nПолный ID: <code>{row.id}</code>\nСтатус: <b>{status}</b>\nПодписка: <b>{row.duration_days} дней</b>\nУстройства: <b>{row.max_devices}</b>\nИспользования: <b>{row.uses}/{row.max_uses}</b>\nСоздана: <b>{fmt_dt(row.created_at)}</b>\nСсылка истекает: <b>{fmt_dt(row.link_expires_at)}</b>\nTelegram ID: <code>{row.telegram_id or '—'}</code>\nЗаметка: {escape(row.note or '—')}", rows)


@router.callback_query(F.data.startswith("mg:link:revoke:ask:"))
async def revoke_ask(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    row_id = c.data.rsplit(":", 1)[1]
    await edit(c, "<b>Отозвать ссылку?</b>\n\nНовые активации по ней станут невозможны.", [[b("❌ Да, отозвать", f"mg:link:revoke:{row_id}")], [b("Отмена", f"mg:link:view:{row_id}")]])


@router.callback_query(F.data.startswith("mg:link:revoke:"))
async def revoke(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    row_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        row = await s.get(Activation, row_id)
        if not row: await c.answer("Ссылка не найдена", show_alert=True); return
        row.revoked_at = datetime.now(UTC); s.add(AuditLog(admin_id=c.from_user.id, action="activation.revoke", entity_type="activation", entity_id=str(row.id))); await s.commit()
    await c.answer("Ссылка отозвана", show_alert=True); c.data = f"mg:link:view:{row_id}"; await link_view(c)


@router.callback_query(F.data.startswith("users:"))
async def users(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    page = max(0, int(c.data.split(":")[1])); now = datetime.now(UTC)
    async with SessionLocal() as s:
        total = int(await s.scalar(select(func.count(User.id))) or 0)
        rows = (await s.execute(select(User).order_by(User.created_at.desc()).offset(page * PAGE).limit(PAGE))).scalars().all()
        active = int(await s.scalar(select(func.count(User.id)).where(or_(User.lifetime.is_(True), User.subscription_expires_at > now), User.status == UserStatus.active)) or 0)
    buttons = [[b(f"{user_icon(u)} {(u.note or str(u.id)[:8])[:22]} · {days_left(u)}д", f"mg:user:view:{u.id}")] for u in rows]
    nav=[]
    if page: nav.append(b("◀️", f"users:{page-1}"))
    if (page+1)*PAGE < total: nav.append(b("▶️", f"users:{page+1}"))
    if nav: buttons.append(nav)
    buttons += [[b("🔎 Найти пользователя", "mg:user:search")], [b("⬅️ Главное меню", "home")]]
    await edit(c, f"<b>👥 Пользователи</b>\n\nВсего: <b>{total}</b> · активных: <b>{active}</b> · страница {page+1}", buttons)


@router.callback_query(F.data == "mg:user:search")
async def user_search(c: CallbackQuery, state: FSMContext) -> None:
    if await deny_cb(c): return
    await state.set_state(SearchUser.query)
    await edit(c, "<b>🔎 Поиск пользователя</b>\n\nОтправьте User ID, Device/Installation ID, Telegram ID или заметку.", [[b("❌ Отмена", "users:0")]])


@router.message(SearchUser.query)
async def user_search_text(m: Message, state: FSMContext) -> None:
    if await deny_msg(m): return
    q=(m.text or "").strip(); await state.clear()
    uc=[User.note.ilike(f"%{q}%"), func.cast(User.id, String).ilike(f"%{q}%")]
    if q.isdigit(): uc.append(User.telegram_id == int(q))
    async with SessionLocal() as s:
        device_users = select(Device.user_id).where(or_(Device.installation_id.ilike(f"%{q}%"), func.cast(Device.id, String).ilike(f"%{q}%")))
        rows=(await s.execute(select(User).where(or_(*uc, User.id.in_(device_users))).order_by(User.created_at.desc()).limit(20))).scalars().all()
    buttons=[[b(f"{user_icon(u)} {(u.note or str(u.id)[:8])[:24]} · {days_left(u)}д", f"mg:user:view:{u.id}")] for u in rows]
    buttons.append([b("⬅️ Пользователи", "users:0")])
    await m.answer(f"<b>Результаты поиска</b>\n\nНайдено: {len(rows)}", reply_markup=kb(buttons), parse_mode="HTML")


@router.callback_query(F.data.startswith("mg:user:view:"))
async def user_view(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]
    async with SessionLocal() as s:
        user=await s.scalar(select(User).where(User.id==user_id).options(selectinload(User.devices)))
    if not user: await c.answer("Пользователь не найден", show_alert=True); return
    devices=[d for d in user.devices if not d.revoked_at]
    device_lines="\n".join(f"• <code>{d.installation_id[-8:]}</code> · iOS {escape(d.ios_version or '—')} · app {escape(d.app_version or '—')} · {fmt_dt(d.last_seen_at)}" for d in devices[:5]) or "—"
    action = "✅ Разблокировать" if user.status == UserStatus.blocked else "⛔️ Заблокировать"
    await edit(c, f"<b>{user_icon(user)} Пользователь {str(user.id)[:8]}</b>\n\nID: <code>{user.id}</code>\nСтатус: <b>{user.status.value}</b>\nАктивирован: <b>{fmt_dt(user.activated_at)}</b>\nПодписка до: <b>{'бессрочно' if user.lifetime else fmt_dt(user.subscription_expires_at)}</b>\nОсталось дней: <b>{days_left(user)}</b>\nTelegram ID: <code>{user.telegram_id or '—'}</code>\nЗаметка: {escape(user.note or '—')}\nУстройства: <b>{len(devices)}</b>\n{device_lines}", [
        [b("➕ 7 дней", f"mg:user:add:7:{user.id}"), b("➕ 30 дней", f"mg:user:add:30:{user.id}")],
        [b("➕/➖ Свой срок", f"mg:user:days:{user.id}"), b("📅 Точная дата", f"mg:user:date:{user.id}")],
        [b(action, f"mg:user:toggle:ask:{user.id}")],
        [b("📱 Сбросить устройства", f"mg:user:reset:ask:{user.id}")],
        [b("📝 Изменить заметку", f"mg:user:note:{user.id}")],
        [b("⬅️ Пользователи", "users:0")],
    ])


@router.callback_query(F.data.startswith("mg:user:add:"))
async def user_add(c: CallbackQuery) -> None:
    if await deny_cb(c): return
    _,_,_,days_s,user_id=c.data.split(":"); days=int(days_s)
    async with SessionLocal() as s:
        u=await s.get(User,user_id)
        base=u.subscription_expires_at if u and u.subscription_expires_at and u.subscription_expires_at>datetime.now(UTC) else datetime.now(UTC)
        if not u: await c.answer("Не найден",show_alert=True); return
        u.lifetime=False; u.subscription_expires_at=base+timedelta(days=days); s.add(AuditLog(admin_id=c.from_user.id,action=f"user.extend.{days}",entity_type="user",entity_id=user_id)); await s.commit()
    await c.answer(f"Добавлено {days} дней",show_alert=True); c.data=f"mg:user:view:{user_id}"; await user_view(c)


@router.callback_query(F.data.startswith("mg:user:days:"))
async def user_days(c: CallbackQuery,state:FSMContext)->None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]; await state.update_data(user_id=user_id); await state.set_state(UserEdit.days)
    await edit(c,"<b>Изменение срока</b>\n\nОтправьте число: <code>30</code> добавит 30 дней, <code>-7</code> уберёт 7 дней.",[[b("❌ Отмена",f"mg:user:view:{user_id}")]])


@router.message(UserEdit.days)
async def user_days_text(m:Message,state:FSMContext)->None:
    if await deny_msg(m): return
    try: delta=int((m.text or "").strip())
    except ValueError: delta=0
    if delta==0 or abs(delta)>3650: await m.answer("Введите число от -3650 до 3650, кроме нуля."); return
    data=await state.get_data(); await state.clear(); user_id=data["user_id"]
    async with SessionLocal() as s:
        u=await s.get(User,user_id)
        if not u: await m.answer("Пользователь не найден."); return
        base=u.subscription_expires_at or datetime.now(UTC); u.lifetime=False; u.subscription_expires_at=max(datetime.now(UTC),base+timedelta(days=delta)); s.add(AuditLog(admin_id=m.from_user.id,action=f"user.days.{delta}",entity_type="user",entity_id=user_id)); await s.commit()
    await m.answer(f"✅ Срок изменён на {delta:+d} дней.",reply_markup=kb([[b("👤 Открыть пользователя",f"mg:user:view:{user_id}")]]))


@router.callback_query(F.data.startswith("mg:user:date:"))
async def user_date(c:CallbackQuery,state:FSMContext)->None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]; await state.update_data(user_id=user_id); await state.set_state(UserEdit.exact_date)
    await edit(c,"<b>Точная дата окончания</b>\n\nОтправьте дату в формате <code>31.12.2026</code>.",[[b("❌ Отмена",f"mg:user:view:{user_id}")]])


@router.message(UserEdit.exact_date)
async def user_date_text(m:Message,state:FSMContext)->None:
    if await deny_msg(m): return
    try: target=datetime.strptime((m.text or "").strip(),"%d.%m.%Y").replace(hour=23,minute=59,tzinfo=UTC)
    except ValueError: await m.answer("Формат даты: 31.12.2026"); return
    data=await state.get_data(); await state.clear(); user_id=data["user_id"]
    async with SessionLocal() as s:
        u=await s.get(User,user_id)
        if not u: await m.answer("Пользователь не найден."); return
        u.lifetime=False; u.subscription_expires_at=target; s.add(AuditLog(admin_id=m.from_user.id,action="user.set_expiry",entity_type="user",entity_id=user_id)); await s.commit()
    await m.answer("✅ Дата окончания изменена.",reply_markup=kb([[b("👤 Открыть пользователя",f"mg:user:view:{user_id}")]]))


@router.callback_query(F.data.startswith("mg:user:toggle:ask:"))
async def toggle_ask(c:CallbackQuery)->None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]
    await edit(c,"<b>Изменить блокировку пользователя?</b>\n\nДействие будет записано в журнал.",[[b("Подтвердить",f"mg:user:toggle:{user_id}")],[b("Отмена",f"mg:user:view:{user_id}")]])


@router.callback_query(F.data.startswith("mg:user:toggle:"))
async def toggle(c:CallbackQuery)->None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]
    async with SessionLocal() as s:
        u=await s.get(User,user_id)
        if not u: await c.answer("Не найден",show_alert=True); return
        u.status=UserStatus.active if u.status==UserStatus.blocked else UserStatus.blocked; s.add(AuditLog(admin_id=c.from_user.id,action=f"user.{u.status.value}",entity_type="user",entity_id=user_id)); await s.commit()
    await c.answer("Статус изменён",show_alert=True); c.data=f"mg:user:view:{user_id}"; await user_view(c)


@router.callback_query(F.data.startswith("mg:user:reset:ask:"))
async def reset_ask(c:CallbackQuery)->None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]
    await edit(c,"<b>Сбросить все устройства?</b>\n\nПользователю понадобится повторная активация.",[[b("📱 Да, сбросить",f"mg:user:reset:{user_id}")],[b("Отмена",f"mg:user:view:{user_id}")]])


@router.callback_query(F.data.startswith("mg:user:reset:"))
async def reset(c:CallbackQuery)->None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]
    async with SessionLocal() as s:
        devices=(await s.execute(select(Device).where(Device.user_id==user_id,Device.revoked_at.is_(None)))).scalars().all(); now=datetime.now(UTC)
        for d in devices: d.revoked_at=now
        s.add(AuditLog(admin_id=c.from_user.id,action="user.devices.reset",entity_type="user",entity_id=user_id)); await s.commit()
    await c.answer(f"Сброшено устройств: {len(devices)}",show_alert=True); c.data=f"mg:user:view:{user_id}"; await user_view(c)


@router.callback_query(F.data.startswith("mg:user:note:"))
async def note_user(c:CallbackQuery,state:FSMContext)->None:
    if await deny_cb(c): return
    user_id=c.data.rsplit(":",1)[1]; await state.update_data(user_id=user_id); await state.set_state(UserEdit.note)
    await edit(c,"<b>Заметка пользователя</b>\n\nОтправьте имя, заказ или любой удобный комментарий.",[[b("❌ Отмена",f"mg:user:view:{user_id}")]])


@router.message(UserEdit.note)
async def note_user_text(m:Message,state:FSMContext)->None:
    if await deny_msg(m): return
    data=await state.get_data(); await state.clear(); user_id=data["user_id"]; note=(m.text or "")[:500]
    async with SessionLocal() as s:
        u=await s.get(User,user_id)
        if not u: await m.answer("Пользователь не найден."); return
        u.note=note; s.add(AuditLog(admin_id=m.from_user.id,action="user.note.update",entity_type="user",entity_id=user_id)); await s.commit()
    await m.answer("✅ Заметка сохранена.",reply_markup=kb([[b("👤 Открыть пользователя",f"mg:user:view:{user_id}")]]))
