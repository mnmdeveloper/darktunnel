from html import escape

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import select

from .config import get_settings
from .db import SessionLocal
from .models import Announcement

router = Router(name="announcements")


class AnnouncementWizard(StatesGroup):
    title = State()
    body = State()


def owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def button(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


@router.callback_query(F.data == "announcements")
async def list_announcements(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    await state.clear()
    async with SessionLocal() as session:
        rows = (
            await session.execute(select(Announcement).order_by(Announcement.created_at.desc()).limit(10))
        ).scalars().all()
    lines = ["<b>📢 Объявления</b>", ""]
    keyboard: list[list[InlineKeyboardButton]] = []
    if not rows:
        lines.append("Объявлений пока нет.")
    for row in rows:
        icon = "🟢" if row.active else "⚪️"
        lines.append(f"{icon} <b>{escape(row.title)}</b> · {escape(row.placement)}")
        keyboard.append([button("🗑 Удалить · " + row.title[:24], f"announcement:delete:{row.id}")])
    keyboard.append([button("➕ Новое объявление", "announcement:new")])
    keyboard.append([button("⬅️ Остальное", "misc")])
    if callback.message:
        await callback.message.edit_text("\n".join(lines), reply_markup=kb(keyboard), parse_mode="HTML")
    await callback.answer()


@router.callback_query(F.data == "announcement:new")
async def new_announcement(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    await state.clear()
    await state.set_state(AnnouncementWizard.title)
    if callback.message:
        await callback.message.edit_text(
            "<b>📢 Новое объявление · 1/2</b>\n\nОтправьте короткий заголовок.",
            reply_markup=kb([[button("❌ Отмена", "announcements")]]),
            parse_mode="HTML",
        )
    await callback.answer()


@router.message(AnnouncementWizard.title)
async def announcement_title(message: Message, state: FSMContext) -> None:
    if not owner(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    title = (message.text or "").strip()
    if not title or len(title) > 160:
        await message.answer("Заголовок должен быть от 1 до 160 символов.")
        return
    await state.update_data(title=title)
    await state.set_state(AnnouncementWizard.body)
    await message.answer("<b>📢 Новое объявление · 2/2</b>\n\nОтправьте текст объявления.", parse_mode="HTML")


@router.message(AnnouncementWizard.body)
async def announcement_body(message: Message, state: FSMContext) -> None:
    if not owner(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    body = (message.text or "").strip()
    if not body or len(body) > 4000:
        await message.answer("Текст должен быть от 1 до 4000 символов.")
        return
    data = await state.get_data()
    await state.update_data(body=body)
    await state.clear()
    await message.answer(
        f"<b>Куда показать?</b>\n\n<b>{escape(data['title'])}</b>\n{escape(body)}",
        reply_markup=kb([
            [button("🏠 Главный экран", "announcement:place:home")],
            [button("🖥 Серверы", "announcement:place:servers")],
            [button("🏠 + 🖥 Везде", "announcement:place:both")],
            [button("❌ Отмена", "announcements")],
        ]),
        parse_mode="HTML",
    )
    await state.update_data(title=data["title"], body=body)


@router.callback_query(F.data.startswith("announcement:place:"))
async def announcement_place(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    data = await state.get_data()
    placement = callback.data.rsplit(":", 1)[1]
    if placement == "both":
        placement = "both"
    if not data.get("title") or not data.get("body"):
        await callback.answer("Данные объявления потеряны", show_alert=True)
        return
    async with SessionLocal() as session:
        session.add(Announcement(
            title=str(data["title"]),
            body=str(data["body"]),
            placement=placement,
            active=True,
            created_by=callback.from_user.id,
        ))
        await session.commit()
    await state.clear()
    await callback.answer("Опубликовано")
    await list_announcements(callback, state)


@router.callback_query(F.data.startswith("announcement:delete:"))
async def delete_announcement(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    announcement_id = callback.data.rsplit(":", 1)[1]
    async with SessionLocal() as session:
        row = await session.get(Announcement, announcement_id)
        if row:
            row.active = False
            await session.commit()
    await callback.answer("Скрыто")
    await list_announcements(callback, state)
