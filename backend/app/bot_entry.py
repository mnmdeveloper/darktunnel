import asyncio
import logging

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message

from .bot import router as legacy_router
from .bot_features import router as features_router
from .config import get_settings
from .db import init_db

menu_router = Router(name="main-menu")


def button(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [button("📊 Статистика", "stats"), button("👥 Пользователи", "users:0")],
        [button("🔑 Доступ", "access"), button("🖥 Серверы", "servers")],
        [button("🎨 Темы", "themes"), button("📢 Объявления", "announcements")],
        [button("🚨 Техработы", "maintenance"), button("📲 Push", "push")],
        [button("👮 Администраторы", "admins"), button("💳 Продажи", "sales")],
        [button("🧾 Журнал", "audit:0"), button("⚙️ Настройки", "settings")],
    ])


def is_owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


@menu_router.message(CommandStart())
@menu_router.message(Command("menu"))
async def start(message: Message, state: FSMContext) -> None:
    if not is_owner(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    await state.clear()
    await message.answer(
        "<b>DarkTunnel Admin</b>\n\nУправление доступом, серверами, контентом и состоянием приложения.",
        reply_markup=menu(),
        parse_mode="HTML",
    )


@menu_router.callback_query(F.data == "home")
async def home(callback: CallbackQuery, state: FSMContext) -> None:
    if not is_owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    await state.clear()
    if callback.message:
        await callback.message.edit_text("<b>DarkTunnel Admin</b>\n\nВыберите раздел:", reply_markup=menu(), parse_mode="HTML")
    await callback.answer()


async def main() -> None:
    settings = get_settings()
    if not settings.telegram_bot_token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not configured")
    if not settings.telegram_owner_id:
        raise RuntimeError("TELEGRAM_OWNER_ID is not configured")
    if not settings.activation_encryption_key:
        raise RuntimeError("ACTIVATION_ENCRYPTION_KEY is not configured")

    logging.basicConfig(level=logging.INFO)
    await init_db()
    bot = Bot(token=settings.telegram_bot_token)
    dispatcher = Dispatcher()
    dispatcher.include_router(menu_router)
    dispatcher.include_router(features_router)
    dispatcher.include_router(legacy_router)
    await dispatcher.start_polling(bot, allowed_updates=dispatcher.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
