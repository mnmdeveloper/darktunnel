import asyncio
import logging
from datetime import UTC, datetime

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import select

from .bot_announcements import router as announcements_router
from .bot_features import router as features_router
from .bot_management import router as management_router
from .bot_node_status import router as node_status_router
from .bot_subscription_admin import router as subscription_admin_router
from .bot_subscription_user_admin import router as subscription_user_admin_router
from .config import get_settings
from .db import SessionLocal, init_db
from .models import ServerHealth, ServerNode
from .server_crypto import decrypt_server_config, encrypt_server_config
from .services import _read_wdtt_password

menu_router = Router(name="main-menu")


def button(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [button("🔑 Создать ссылку", "mg:link:new")],
        [button("💳 Управление подписками", "subscription:admin"), button("🖥 Серверы", "servers")],
        [button("📡 Состояние нод", "node:status")],
        [button("📊 Статистика", "stats")],
        [button("⚙️ Остальное", "misc")],
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
        async with SessionLocal() as session:
            node = await session.scalar(select(ServerNode).where(ServerNode.host == settings.wdtt_public_host, ServerNode.archived_at.is_(None)))
            config: dict[str, object] = {}
            if node is not None:
                try:
                    config = decrypt_server_config(node.encrypted_config)
                except Exception:
                    config = {}
            config.update({
                "wrap_a_password": password,
                "source": config.get("source", "existing-production-node"),
                "registered_at": config.get("registered_at", datetime.now(UTC).isoformat()),
            })
            encrypted = encrypt_server_config(config)

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
    await message.answer("<b>DarkTunnel Admin</b>\n\nВыберите действие:", reply_markup=menu(), parse_mode="HTML")


@menu_router.callback_query(F.data == "home")
async def home(callback: CallbackQuery, state: FSMContext) -> None:
    if not is_owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    await state.clear()
    if callback.message:
        await callback.message.edit_text("<b>DarkTunnel Admin</b>\n\nВыберите действие:", reply_markup=menu(), parse_mode="HTML")
    await callback.answer()


@menu_router.callback_query(F.data == "misc")
async def misc(callback: CallbackQuery) -> None:
    if not is_owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    rows = [
        [button("💳 Подписки", "subscription:admin"), button("🎨 Темы", "themes")],
        [button("📢 Объявления", "announcement:list"), button("📲 Push", "push")],
        [button("👮 Администраторы", "admins"), button("🧾 Журнал", "audit:0")],
        [button("💳 Продажи", "sales")],
        [button("⬅️ Главное меню", "home")],
    ]
    if callback.message:
        await callback.message.edit_text("<b>⚙️ Остальное</b>\n\nДополнительные разделы.", reply_markup=InlineKeyboardMarkup(inline_keyboard=rows), parse_mode="HTML")
    await callback.answer()


@menu_router.callback_query(F.data == "stats")
async def stats(callback: CallbackQuery) -> None:
    if not is_owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    from .models import Activation, User
    from sqlalchemy import func
    async with SessionLocal() as session:
        total_users = int(await session.scalar(select(func.count(User.id))) or 0)
        total_links = int(await session.scalar(select(func.count(Activation.id))) or 0)
        total_servers = int(await session.scalar(select(func.count(ServerNode.id)).where(ServerNode.archived_at.is_(None))) or 0)
    text = f"<b>📊 Статистика</b>\n\nПользователей: <b>{total_users}</b>\nСсылок: <b>{total_links}</b>\nСерверов: <b>{total_servers}</b>"
    if callback.message:
        await callback.message.edit_text(text, reply_markup=InlineKeyboardMarkup(inline_keyboard=[[button("⬅️ Главное меню", "home")]]), parse_mode="HTML")
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
    # This router must precede the legacy user-management router because both
    # use mg:user:view:* callbacks. It provides the complete subscription UI.
    dispatcher.include_router(subscription_user_admin_router)
    dispatcher.include_router(management_router)
    dispatcher.include_router(subscription_admin_router)
    dispatcher.include_router(features_router)
    dispatcher.include_router(node_status_router)
    dispatcher.include_router(announcements_router)
    await dispatcher.start_polling(bot, allowed_updates=dispatcher.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
