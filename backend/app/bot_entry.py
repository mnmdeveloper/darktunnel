import asyncio
import logging
from datetime import UTC, datetime

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import select

from .bot import router as legacy_router
from .bot_access_v2 import router as access_v2_router
from .bot_features import router as features_router
from .bot_management import router as management_router
from .bot_servers_v2 import router as servers_v2_router
from .config import get_settings
from .db import SessionLocal, init_db
from .models import ServerHealth, ServerNode
from .server_crypto import encrypt_server_config
from .services import _read_wdtt_password

menu_router = Router(name="main-menu")


def button(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [button("🔑 Создать ссылку", "access")],
        [button("👥 Пользователи", "users:0"), button("🖥 Серверы", "servers")],
        [button("📊 Статистика", "stats")],
        [button("⚙️ Остальное", "settings")],
    ])


def is_owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


async def ensure_primary_server() -> None:
    settings = get_settings()
    if not settings.server_config_encryption_key:
        logging.warning("Primary server was not registered: SERVER_CONFIG_ENCRYPTION_KEY is missing")
        return
    try:
        password = _read_wdtt_password()
        encrypted = encrypt_server_config({
            "wrap_a_password": password,
            "source": "existing-production-node",
            "registered_at": datetime.now(UTC).isoformat(),
        })
        async with SessionLocal() as session:
            node = await session.scalar(select(ServerNode).where(ServerNode.host == settings.wdtt_public_host, ServerNode.archived_at.is_(None)))
            if node is None:
                node = ServerNode(
                    name="Основной сервер",
                    host=settings.wdtt_public_host,
                    port=settings.wdtt_public_port,
                    protocol_mode=settings.wdtt_mode,
                    encrypted_config=encrypted,
                    mtu=settings.wdtt_mtu,
                    dns=settings.wdtt_dns,
                    balanced_connections=settings.wdtt_connections_balanced,
                    max_connections=settings.wdtt_connections_maximum,
                    published=True,
                    auto_select=True,
                    maintenance=False,
                )
                session.add(node)
                await session.flush()
                session.add(ServerHealth(server_id=node.id, online=True))
            else:
                node.name = node.name or "Основной сервер"
                node.port = settings.wdtt_public_port
                node.protocol_mode = settings.wdtt_mode
                node.encrypted_config = encrypted
                node.published = True
                node.auto_select = True
                node.maintenance = False
            await session.commit()
    except Exception:
        logging.exception("Failed to auto-register primary WDTT server")


@menu_router.message(CommandStart())
@menu_router.message(Command("menu"))
async def start(message: Message, state: FSMContext) -> None:
    if not is_owner(message.from_user.id if message.from_user else None):
        await message.answer("Доступ запрещён.")
        return
    await state.clear()
    await message.answer(
        "<b>DarkTunnel Admin</b>\n\nГлавное действие — создать одну ссылку для пользователя.",
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
        await callback.message.edit_text(
            "<b>DarkTunnel Admin</b>\n\nВыберите действие:",
            reply_markup=menu(),
            parse_mode="HTML",
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
    await ensure_primary_server()
    bot = Bot(token=settings.telegram_bot_token)
    dispatcher = Dispatcher()
    dispatcher.include_router(menu_router)
    dispatcher.include_router(access_v2_router)
    dispatcher.include_router(servers_v2_router)
    dispatcher.include_router(management_router)
    dispatcher.include_router(features_router)
    dispatcher.include_router(legacy_router)
    await dispatcher.start_polling(bot, allowed_updates=dispatcher.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
