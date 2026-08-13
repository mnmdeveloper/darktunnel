from html import escape
import re

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
    placement = State()
    color = State()


COLORS = {
    "🔵 Синий": "#007AFF",
    "🟢 Зелёный": "#34C759",
    "🟠 Оранжевый": "#FF9500",
    "🔴 Красный": "#FF3B30",
    "🟣 Фиолетовый": "#AF52DE",
    "⚪️ Серый": "#60758F",
}


def owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and (user_id == settings.telegram_owner_id or user_id == 8341845264))


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def button(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


@router.callback_query(F.data == "announcement:list")
async def list_announcements(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    await state.clear()
    async with SessionLocal() as session:
        rows = (
            await session.execute(select(Announcement).order_by(Announcement.created_at.desc()).limit(20))
        ).scalars().all()
    lines = ["<b>📢 Объявления</b>", ""]
    keyboard: list[list[InlineKeyboardButton]] = []
    if not rows:
        lines.append("Объявлений пока нет.")
    for row in rows:
        icon = "🟢" if row.active else "⚪️"
        placement = {"home": "🏠 Главный экран", "servers": "🖥 Серверы", "both": "🏠 + 🖥 Везде"}.get(row.placement, row.placement)
        lines.append(f"{icon} <b>{escape(row.title)}</b> · {escape(placement)} · <code>{escape(row.color_hex or '#60758F')}</code>")
        keyboard.append([
            button("⏹ Выключить" if row.active else "▶️ Включить", f"announcement:toggle:{row.id}"),
            button("🗑 Удалить", f"announcement:delete:{row.id}"),
        ])
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
            "<b>📢 Новое объявление · 1/4</b>\n\nОтправьте короткий заголовок.",
            reply_markup=kb([[button("❌ Отмена", "announcement:list")]]),
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
    await message.answer("<b>📢 Новое объявление · 2/4</b>\n\nОтправьте текст объявления.", parse_mode="HTML")


@router.message(AnnouncementWizard.body)
async def announcement_body(message: Message, state: FSMContext) -> None:
    if not owner(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    body = (message.text or "").strip()
    if not body or len(body) > 4000:
        await message.answer("Текст должен быть от 1 до 4000 символов.")
        return
    await state.update_data(body=body)
    await state.set_state(AnnouncementWizard.placement)
    await message.answer(
        "<b>📢 Новое объявление · 3/4</b>\n\nГде показывать?",
        reply_markup=kb([
            [button("🏠 Главный экран", "announcement:place:home")],
            [button("🖥 Серверы", "announcement:place:servers")],
            [button("🏠 + 🖥 Везде", "announcement:place:both")],
            [button("❌ Отмена", "announcement:list")],
        ]),
        parse_mode="HTML",
    )


@router.callback_query(F.data.startswith("announcement:place:"))
async def announcement_place(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    data = await state.get_data()
    placement = callback.data.rsplit(":", 1)[1]
    if not data.get("title") or not data.get("body"):
        await callback.answer("Данные объявления потеряны", show_alert=True)
        return
    await state.update_data(placement=placement)
    await state.set_state(AnnouncementWizard.color)
    rows = []
    items = list(COLORS.items())
    for index in range(0, len(items), 2):
        rows.append([button(items[index][0], f"announcement:color:{items[index][1]}"), button(items[index + 1][0], f"announcement:color:{items[index + 1][1]}")])
    rows.append([button("🎨 Свой HEX", "announcement:color:custom")])
    rows.append([button("❌ Отмена", "announcement:list")])
    if callback.message:
        await callback.message.edit_text(
            "<b>📢 Новое объявление · 4/4</b>\n\nВыберите цвет акцента.",
            reply_markup=kb(rows),
            parse_mode="HTML",
        )
    await callback.answer()


@router.callback_query(F.data == "announcement:color:custom")
async def custom_color(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    await state.set_state(AnnouncementWizard.color)
    await state.update_data(await_custom_color=True)
    if callback.message:
        await callback.message.edit_text("<b>🎨 Свой цвет</b>\n\nОтправьте HEX, например <code>#FF9500</code>.", parse_mode="HTML")
    await callback.answer()


@router.message(AnnouncementWizard.color)
async def announcement_custom_color(message: Message, state: FSMContext) -> None:
    if not owner(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    data = await state.get_data()
    if not data.get("await_custom_color"):
        await message.answer("Выберите цвет кнопкой выше.")
        return
    color = (message.text or "").strip().upper()
    if not re.fullmatch(r"#[0-9A-F]{6}", color):
        await message.answer("Неверный HEX. Пример: #FF9500")
        return
    await create_announcement(message, state, color)


@router.callback_query(F.data.startswith("announcement:color:"))
async def announcement_color(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    color = callback.data.rsplit(":", 1)[1].upper()
    if color == "CUSTOM":
        await callback.answer()
        return
    await create_announcement(callback.message, state, color, callback.from_user.id)
    await callback.answer("Опубликовано")


async def create_announcement(message_or_callback, state: FSMContext, color: str, created_by: int | None = None) -> None:
    data = await state.get_data()
    if not data.get("title") or not data.get("body") or not data.get("placement"):
        if hasattr(message_or_callback, "answer"):
            await message_or_callback.answer("Данные объявления потеряны")
        return
    creator = created_by
    if creator is None and getattr(message_or_callback, "from_user", None):
        creator = message_or_callback.from_user.id
    async with SessionLocal() as session:
        session.add(Announcement(
            title=str(data["title"]),
            body=str(data["body"]),
            placement=str(data["placement"]),
            color_hex=color,
            active=True,
            created_by=int(creator or 0),
        ))
        await session.commit()
    await state.clear()
    if hasattr(message_or_callback, "edit_text"):
        await message_or_callback.edit_text("<b>📢 Объявление опубликовано</b>", reply_markup=kb([[button("📢 Все объявления", "announcement:list")]]), parse_mode="HTML")
    else:
        await message_or_callback.answer("<b>📢 Объявление опубликовано</b>", parse_mode="HTML")


@router.callback_query(F.data.startswith("announcement:toggle:"))
async def toggle_announcement(callback: CallbackQuery, state: FSMContext) -> None:
    if not owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    announcement_id = callback.data.rsplit(":", 1)[1]
    async with SessionLocal() as session:
        row = await session.get(Announcement, announcement_id)
        if row:
            row.active = not row.active
            await session.commit()
    await callback.answer("Изменено")
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
            await session.delete(row)
            await session.commit()
    await callback.answer("Удалено")
    await list_announcements(callback, state)
