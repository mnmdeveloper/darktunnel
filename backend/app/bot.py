import asyncio
import logging

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import CommandStart
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message

from .config import get_settings

router = Router()


def owner_only(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


def main_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="📊 Статус", callback_data="status")],
            [InlineKeyboardButton(text="🔑 Доступ и ссылки", callback_data="access")],
            [InlineKeyboardButton(text="👥 Пользователи", callback_data="users")],
            [InlineKeyboardButton(text="🖥 Серверы", callback_data="servers")],
        ]
    )


@router.message(CommandStart())
async def start(message: Message) -> None:
    if not owner_only(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    await message.answer("DarkTunnel Admin", reply_markup=main_menu())


@router.callback_query(F.data == "status")
async def status(callback: CallbackQuery) -> None:
    if not owner_only(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    settings = get_settings()
    await callback.message.edit_text(
        f"Backend: готов к запуску\nWDTT: {settings.wdtt_public_host}:{settings.wdtt_public_port}",
        reply_markup=main_menu(),
    )
    await callback.answer()


@router.callback_query(F.data.in_({"access", "users", "servers"}))
async def placeholder(callback: CallbackQuery) -> None:
    if not owner_only(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    await callback.answer("Раздел подключается к backend на следующем шаге", show_alert=True)


async def main() -> None:
    settings = get_settings()
    if not settings.telegram_bot_token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not configured")
    if not settings.telegram_owner_id:
        raise RuntimeError("TELEGRAM_OWNER_ID is not configured")

    logging.basicConfig(level=logging.INFO)
    bot = Bot(token=settings.telegram_bot_token)
    dispatcher = Dispatcher()
    dispatcher.include_router(router)
    await dispatcher.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
