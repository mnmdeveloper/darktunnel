import asyncio
import logging

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import CommandStart
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import func, select

from .config import get_settings
from .db import SessionLocal, init_db
from .models import Activation, User
from .schemas import ActivationCreate
from .services import create_activation

router = Router()


def owner_only(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


def main_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="📊 Статус", callback_data="status")],
            [InlineKeyboardButton(text="🔑 Ссылка на 3 дня", callback_data="create:3")],
            [InlineKeyboardButton(text="🔑 Ссылка на 30 дней", callback_data="create:30")],
            [InlineKeyboardButton(text="👥 Пользователи", callback_data="users")],
            [InlineKeyboardButton(text="🖥 Сервер", callback_data="server")],
        ]
    )


async def reject(callback: CallbackQuery) -> bool:
    if owner_only(callback.from_user.id):
        return False
    await callback.answer("Доступ запрещён", show_alert=True)
    return True


@router.message(CommandStart())
async def start(message: Message) -> None:
    if not owner_only(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    await message.answer("DarkTunnel Admin", reply_markup=main_menu())


@router.callback_query(F.data == "status")
async def status(callback: CallbackQuery) -> None:
    if await reject(callback):
        return
    settings = get_settings()
    async with SessionLocal() as session:
        users = int(await session.scalar(select(func.count(User.id))) or 0)
        links = int(await session.scalar(select(func.count(Activation.id))) or 0)
    await callback.message.edit_text(
        f"Backend: работает\nПользователей: {users}\nСсылок: {links}\nWDTT: {settings.wdtt_public_host}:{settings.wdtt_public_port}",
        reply_markup=main_menu(),
    )
    await callback.answer()


@router.callback_query(F.data.startswith("create:"))
async def create_link(callback: CallbackQuery) -> None:
    if await reject(callback):
        return
    days = int(callback.data.split(":", 1)[1])
    async with SessionLocal() as session:
        activation, token = await create_activation(
            session,
            ActivationCreate(
                duration_days=days,
                max_devices=1,
                max_uses=1,
                link_ttl_hours=72,
                created_by=callback.from_user.id,
            ),
        )
    await callback.message.answer(
        f"Ссылка на {days} дней, действует 72 часа:\n\n<code>darktunnel://activate?d={token}</code>",
        parse_mode="HTML",
    )
    await callback.answer("Ссылка создана")


@router.callback_query(F.data == "users")
async def users(callback: CallbackQuery) -> None:
    if await reject(callback):
        return
    async with SessionLocal() as session:
        rows = (await session.execute(select(User).order_by(User.created_at.desc()).limit(10))).scalars().all()
    if not rows:
        text = "Пользователей пока нет."
    else:
        text = "Последние пользователи:\n" + "\n".join(
            f"• {str(row.id)[:8]} — {row.status.value} — до {row.subscription_expires_at:%d.%m.%Y}"
            for row in rows
            if row.subscription_expires_at is not None
        )
    await callback.message.edit_text(text, reply_markup=main_menu())
    await callback.answer()


@router.callback_query(F.data == "server")
async def server(callback: CallbackQuery) -> None:
    if await reject(callback):
        return
    settings = get_settings()
    await callback.message.edit_text(
        f"WDTT сервер\n{settings.wdtt_public_host}:{settings.wdtt_public_port}\nРежим: {settings.wdtt_mode}\nСоединения: {settings.wdtt_connections_balanced}/{settings.wdtt_connections_maximum}",
        reply_markup=main_menu(),
    )
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
    dispatcher.include_router(router)
    await dispatcher.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
