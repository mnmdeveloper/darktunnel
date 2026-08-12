from __future__ import annotations

from datetime import UTC, datetime
from html import escape

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import String, delete, func, or_, select

from .config import get_settings
from .db import SessionLocal
from .models import Activation, AuditLog, Device, User, UserStatus

router = Router(name="subscription-admin")


class SubscriptionSearch(StatesGroup):
    query = State()


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


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


@router.callback_query(F.data == "subscription:admin")
async def subscription_admin(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    async with SessionLocal() as s:
        total = int(await s.scalar(select(func.count(User.id))) or 0)
        active = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.active, or_(User.lifetime.is_(True), User.subscription_expires_at > datetime.now(UTC)))) or 0)
        blocked = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.blocked)) or 0)
        expired = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.active, User.lifetime.is_(False), User.subscription_expires_at <= datetime.now(UTC))) or 0)
    await edit(c, f"<b>💳 Управление подписками</b>\n\nВсего: <b>{total}</b>\n✅ Активных: <b>{active}</b>\n⌛️ Истёкших: <b>{expired}</b>\n⛔️ Заблокированных: <b>{blocked}</b>\n\nУдаление подписки удаляет пользователя и его устройства. Это действие необратимо.", [
        [b("🔎 Найти подписку", "subscription:search")],
        [b("👥 Пользователи", "users:0")],
        [b("🗑 Удалить истёкшие", "subscription:delete_expired_ask")],
        [b("🗑 Удалить заблокированные", "subscription:delete_blocked_ask")],
        [b("☢️ УДАЛИТЬ ВСЕ ПОДПИСКИ", "subscription:delete_all_ask")],
        [b("⬅️ Главное меню", "home")],
    ])


@router.callback_query(F.data == "subscription:search")
async def subscription_search(c: CallbackQuery, state: FSMContext) -> None:
    if await deny_cb(c):
        return
    await state.set_state(SubscriptionSearch.query)
    await edit(c, "<b>🔎 Найти подписку</b>\n\nОтправьте Telegram ID, User ID, Installation ID или заметку пользователя.", [[b("❌ Отмена", "subscription:admin")]])


@router.message(SubscriptionSearch.query)
async def subscription_search_text(m: Message, state: FSMContext) -> None:
    if await deny_msg(m):
        return
    q = (m.text or "").strip()
    await state.clear()
    conditions = [User.note.ilike(f"%{q}%"), func.cast(User.id, String).ilike(f"%{q}%")]
    if q.isdigit():
        conditions.append(User.telegram_id == int(q))
    async with SessionLocal() as s:
        device_users = select(Device.user_id).where(or_(Device.installation_id.ilike(f"%{q}%"), func.cast(Device.id, String).ilike(f"%{q}%")))
        rows = (await s.execute(select(User).where(or_(*conditions, User.id.in_(device_users))).order_by(User.created_at.desc()).limit(20))).scalars().all()
    buttons = []
    for u in rows:
        status = "⛔️" if u.status == UserStatus.blocked else "∞" if u.lifetime else "⌛️" if not u.subscription_expires_at or u.subscription_expires_at <= datetime.now(UTC) else "✅"
        expiry = "бессрочно" if u.lifetime else (u.subscription_expires_at.strftime("%d.%m.%Y") if u.subscription_expires_at else "—")
        buttons.append([b(f"{status} {(u.note or str(u.id)[:8])[:24]} · {expiry}", f"subscription:view:{u.id}")])
    buttons.append([b("⬅️ Управление подписками", "subscription:admin")])
    await m.answer(f"<b>Результаты</b>\n\nНайдено: <b>{len(rows)}</b>", reply_markup=kb(buttons), parse_mode="HTML")


@router.callback_query(F.data.startswith("subscription:view:"))
async def subscription_view(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        devices = (await s.execute(select(Device).where(Device.user_id == user_id, Device.revoked_at.is_(None)))).scalars().all()
    if user is None:
        await c.answer("Подписка не найдена", show_alert=True)
        return
    expiry = "бессрочно" if user.lifetime else (user.subscription_expires_at.strftime("%d.%m.%Y %H:%M") if user.subscription_expires_at else "—")
    await edit(c, f"<b>💳 Подписка {str(user.id)[:8]}</b>\n\nСтатус: <b>{user.status.value}</b>\nДо: <b>{expiry}</b>\nTelegram ID: <code>{user.telegram_id or '—'}</code>\nУстройств: <b>{len(devices)}</b>\nЗаметка: {escape(user.note or '—')}\n\nУдаление полностью удалит эту подписку, устройства и связанные использованные activation-ссылки.", [
        [b("🗑 Удалить подписку", f"subscription:delete_ask:{user.id}")],
        [b("⬅️ К управлению", "subscription:admin")],
    ])


@router.callback_query(F.data.startswith("subscription:delete_ask:"))
async def delete_ask(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    user_id = c.data.rsplit(":", 1)[1]
    await edit(c, "<b>⚠️ Удалить подписку?</b>\n\nБудут удалены пользователь, устройства и activation-ссылки, уже привязанные к этой подписке. Действие необратимо.", [
        [b("🗑 ДА, УДАЛИТЬ", f"subscription:delete:{user_id}")],
        [b("Отмена", f"subscription:view:{user_id}")],
    ])


@router.callback_query(F.data.startswith("subscription:delete:"))
async def delete_one(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await c.answer("Подписка уже удалена", show_alert=True)
            return
        await s.execute(delete(Activation).where(Activation.user_id == user.id))
        await s.delete(user)
        s.add(AuditLog(admin_id=c.from_user.id, action="subscription.delete", entity_type="user", entity_id=str(user.id)))
        await s.commit()
    await c.answer("Подписка удалена", show_alert=True)
    c.data = "subscription:admin"
    await subscription_admin(c)


@router.callback_query(F.data == "subscription:delete_expired_ask")
async def delete_expired_ask(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    async with SessionLocal() as s:
        count = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.active, User.lifetime.is_(False), User.subscription_expires_at <= datetime.now(UTC))) or 0)
    await edit(c, f"<b>Удалить истёкшие подписки?</b>\n\nБудет удалено: <b>{count}</b>.", [[b("🗑 Да, удалить", "subscription:delete_expired")], [b("Отмена", "subscription:admin")]])


@router.callback_query(F.data == "subscription:delete_expired")
async def delete_expired(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    now = datetime.now(UTC)
    async with SessionLocal() as s:
        ids = [row[0] for row in (await s.execute(select(User.id).where(User.status == UserStatus.active, User.lifetime.is_(False), User.subscription_expires_at <= now))).all()]
        if ids:
            await s.execute(delete(Activation).where(Activation.user_id.in_(ids)))
            await s.execute(delete(User).where(User.id.in_(ids)))
            s.add(AuditLog(admin_id=c.from_user.id, action="subscription.delete_expired_bulk", entity_type="user", entity_id="bulk"))
        await s.commit()
    await c.answer(f"Удалено подписок: {len(ids)}", show_alert=True)
    await subscription_admin(c)


@router.callback_query(F.data == "subscription:delete_blocked_ask")
async def delete_blocked_ask(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    async with SessionLocal() as s:
        count = int(await s.scalar(select(func.count(User.id)).where(User.status == UserStatus.blocked)) or 0)
    await edit(c, f"<b>Удалить заблокированные подписки?</b>\n\nБудет удалено: <b>{count}</b>.", [[b("🗑 Да, удалить", "subscription:delete_blocked")], [b("Отмена", "subscription:admin")]])


@router.callback_query(F.data == "subscription:delete_blocked")
async def delete_blocked(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    async with SessionLocal() as s:
        ids = [row[0] for row in (await s.execute(select(User.id).where(User.status == UserStatus.blocked))).all()]
        if ids:
            await s.execute(delete(Activation).where(Activation.user_id.in_(ids)))
            await s.execute(delete(User).where(User.id.in_(ids)))
            s.add(AuditLog(admin_id=c.from_user.id, action="subscription.delete_blocked_bulk", entity_type="user", entity_id="bulk"))
        await s.commit()
    await c.answer(f"Удалено подписок: {len(ids)}", show_alert=True)
    await subscription_admin(c)


@router.callback_query(F.data == "subscription:delete_all_ask")
async def delete_all_ask(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    async with SessionLocal() as s:
        count = int(await s.scalar(select(func.count(User.id))) or 0)
    await edit(c, f"<b>☢️ УДАЛИТЬ ВСЕ ПОДПИСКИ?</b>\n\nСейчас подписок: <b>{count}</b>.\n\nБудут удалены все пользователи, их устройства и все activation-ссылки, уже привязанные к пользователям. Неиспользованные ссылки останутся.", [
        [b("☢️ ДА, УДАЛИТЬ ВСЁ", "subscription:delete_all")],
        [b("Отмена", "subscription:admin")],
    ])


@router.callback_query(F.data == "subscription:delete_all")
async def delete_all(c: CallbackQuery) -> None:
    if await deny_cb(c):
        return
    async with SessionLocal() as s:
        ids = [row[0] for row in (await s.execute(select(User.id))).all()]
        if ids:
            await s.execute(delete(Activation).where(Activation.user_id.in_(ids)))
            await s.execute(delete(User).where(User.id.in_(ids)))
            s.add(AuditLog(admin_id=c.from_user.id, action="subscription.delete_all", entity_type="user", entity_id="ALL"))
        await s.commit()
    await c.answer(f"Удалено подписок: {len(ids)}", show_alert=True)
    await subscription_admin(c)
