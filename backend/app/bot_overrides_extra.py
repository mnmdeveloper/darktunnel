from __future__ import annotations

from datetime import UTC, datetime, timedelta
from html import escape

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, Message
from sqlalchemy import select

from .bot_overrides import b, kb, render_user
from .bot_admins import is_admin
from .db import SessionLocal
from .models import AuditLog, User

router = Router(name="bot-overrides-extra")


class UserEditState(StatesGroup):
    days = State()
    date = State()


@router.callback_query(F.data.startswith("override:user:custom:"))
async def custom_days_start(c: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(c.from_user.id):
        await c.answer("Доступ запрещён", show_alert=True); return
    user_id = c.data.rsplit(":", 1)[1]
    await state.update_data(user_id=user_id)
    await state.set_state(UserEditState.days)
    if c.message:
        await c.message.edit_text("<b>➕/➖ Свой срок</b>\n\nОтправьте число дней. Например <code>30</code> добавит 30 дней, <code>-7</code> уберёт 7 дней.", reply_markup=kb([[b("Отмена", f"override:user:view:{user_id}")]]), parse_mode="HTML")
    await c.answer()


@router.message(UserEditState.days)
async def custom_days_text(m: Message, state: FSMContext) -> None:
    if not await is_admin(m.from_user.id if m.from_user else None): return
    try:
        delta = int((m.text or "").strip())
    except ValueError:
        delta = 0
    if delta == 0 or abs(delta) > 3650:
        await m.answer("Введите число от -3650 до 3650, кроме нуля.")
        return
    data = await state.get_data(); await state.clear(); user_id = data["user_id"]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await m.answer("Пользователь не найден."); return
        now = datetime.now(UTC)
        base = user.subscription_expires_at if user.subscription_expires_at and user.subscription_expires_at > now else now
        user.status = user.status
        user.lifetime = False
        user.subscription_expires_at = base + timedelta(days=delta)
        s.add(AuditLog(admin_id=m.from_user.id, action=f"user.days.{delta}", entity_type="user", entity_id=user_id))
        await s.commit()
    await m.answer(f"✅ Срок изменён на {delta:+d} дней.", reply_markup=kb([[b("👤 Открыть пользователя", f"override:user:view:{user_id}")]]))


@router.callback_query(F.data.startswith("override:user:date:"))
async def exact_date_start(c: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(c.from_user.id):
        await c.answer("Доступ запрещён", show_alert=True); return
    user_id = c.data.rsplit(":", 1)[1]
    await state.update_data(user_id=user_id)
    await state.set_state(UserEditState.date)
    if c.message:
        await c.message.edit_text("<b>📅 Точная дата</b>\n\nОтправьте дату окончания в формате <code>31.12.2026</code>.", reply_markup=kb([[b("Отмена", f"override:user:view:{user_id}")]]), parse_mode="HTML")
    await c.answer()


@router.message(UserEditState.date)
async def exact_date_text(m: Message, state: FSMContext) -> None:
    if not await is_admin(m.from_user.id if m.from_user else None): return
    try:
        target = datetime.strptime((m.text or "").strip(), "%d.%m.%Y").replace(hour=23, minute=59, tzinfo=UTC)
    except ValueError:
        await m.answer("Формат даты: 31.12.2026")
        return
    data = await state.get_data(); await state.clear(); user_id = data["user_id"]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await m.answer("Пользователь не найден."); return
        user.lifetime = False
        user.subscription_expires_at = target
        s.add(AuditLog(admin_id=m.from_user.id, action="user.set_expiry", entity_type="user", entity_id=user_id))
        await s.commit()
    await m.answer("✅ Дата окончания изменена.", reply_markup=kb([[b("👤 Открыть пользователя", f"override:user:view:{user_id}")]]))
