from __future__ import annotations

from datetime import UTC, datetime

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, Message
from sqlalchemy import String, func, or_, select

from .bot_admins import is_admin
from .bot_overrides import b, kb, status_icon, user_label
from .db import SessionLocal
from .models import Device, User

router = Router(name="bot-overrides-search")


class SearchState(StatesGroup):
    query = State()


@router.callback_query(F.data == "override:user:search")
async def search_start(c: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(c.from_user.id):
        await c.answer("Доступ запрещён", show_alert=True); return
    await state.set_state(SearchState.query)
    if c.message:
        await c.message.edit_text("<b>🔎 Найти пользователя</b>\n\n@username, Telegram ID, User ID, installation ID или заметка:", reply_markup=kb([[b("Отмена", "override:users:0")]]), parse_mode="HTML")
    await c.answer()


@router.message(SearchState.query)
async def search_text(m: Message, state: FSMContext) -> None:
    if not await is_admin(m.from_user.id if m.from_user else None): return
    q = (m.text or "").strip()
    await state.clear()
    username_q = q.lstrip("@").strip()
    conditions = [User.note.ilike(f"%{q}%"), User.telegram_username.ilike(f"%{username_q}%"), func.cast(User.id, String).ilike(f"%{q}%")]
    if q.isdigit():
        conditions.append(User.telegram_id == int(q))
    async with SessionLocal() as s:
        device_users = select(Device.user_id).where(or_(Device.installation_id.ilike(f"%{q}%"), func.cast(Device.id, String).ilike(f"%{q}%")))
        rows = (await s.execute(select(User).where(or_(*conditions, User.id.in_(device_users))).order_by(User.created_at.desc()).limit(20))).scalars().all()
    buttons = []
    for u in rows:
        if u.lifetime:
            left = "∞"
        elif not u.subscription_expires_at:
            left = "0"
        else:
            left = str(max(0, (u.subscription_expires_at - datetime.now(UTC)).days + 1))
        buttons.append([b(f"{status_icon(u)} {user_label(u)} · {left}д", f"override:user:view:{u.id}")])
    buttons.append([b("⬅️ Пользователи", "override:users:0")])
    await m.answer(f"<b>Результаты</b>\n\nНайдено: <b>{len(rows)}</b>", reply_markup=kb(buttons), parse_mode="HTML")
