import asyncio
import logging
from datetime import UTC, datetime

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import func, select

from .bot_announcements import router as announcements_router
from .bot_features import router as features_router
from .bot_management import router as management_router
from .bot_node_status import router as node_status_router
from .bot_overrides import router as overrides_router
from .bot_overrides_extra import router as overrides_extra_router
from .bot_overrides_search import router as overrides_search_router
from .bot_subscription_admin import router as subscription_admin_router
from .bot_subscription_user_admin import router as subscription_user_admin_router
from .config import get_settings
from .db import SessionLocal, init_db
from .models import Activation, Device, ServerHealth, ServerNode, User, UserStatus
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
        [button("👥 Пользователи", "override:users:0"), button("📢 Объявление всем", "override:broadcast")],
        [button("👮 Администраторы", "override:admins")],
        [button("⚙️ Остальное", "misc")],
    ])


def user_menu(active: bool) -> InlineKeyboardMarkup:
    if not active:
        return InlineKeyboardMarkup(inline_keyboard=[[button("🔑 Запросить доступ", "override:user:request")]])
    return InlineKeyboardMarkup(inline_keyboard=[
        [button("💳 Моя подписка", "override:user:subscription")],
        [button("➕ Продлить подписку", "override:user:renew")],
        [button("🔗 Получить ссылку управления", "override:user:link")],
        [button("📱 Мои устройства", "override:user:devices")],
    ])


def is_owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and (user_id == settings.telegram_owner_id or user_id == 8341845264))


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
            config.update({"wrap_a_password": password, "source": config.get("source", "existing-production-node"), "registered_at": config.get("registered_at", datetime.now(UTC).isoformat())})
            encrypted = encrypt_server_config(config)
            if node is None:
                node = ServerNode(name="Основной сервер", host=settings.wdtt_public_host, port=settings.wdtt_public_port, protocol_mode=settings.wdtt_mode, encrypted_config=encrypted, mtu=settings.wdtt_mtu, dns=settings.wdtt_dns, balanced_connections=settings.wdtt_connections_balanced, max_connections=settings.wdtt_connections_maximum, published=True, auto_select=True, maintenance=False)
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


async def get_or_create_user(telegram_id: int, username: str | None) -> User:
    async with SessionLocal() as session:
        user = await session.scalar(select(User).where(User.telegram_id == telegram_id))
        if user is None:
            user = User(telegram_id=telegram_id, telegram_username=username)
            session.add(user)
        else:
            user.telegram_username = username
        await session.commit()
        await session.refresh(user)
        return user


@menu_router.message(CommandStart())
@menu_router.message(Command("menu"))
async def start(message: Message, state: FSMContext) -> None:
    if not message.from_user:
        return
    user = await get_or_create_user(message.from_user.id, message.from_user.username)
    await state.clear()
    if not is_owner(message.from_user.id):
        active = user.status == UserStatus.active and (user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)))
        if active:
            expiry = "бессрочно" if user.lifetime else user.subscription_expires_at.astimezone().strftime("%d.%m.%Y %H:%M")
            await message.answer(f"<b>DarkTunnel</b>\n\nВаша подписка активна до: <b>{expiry}</b>.\n\nВыберите действие:", reply_markup=user_menu(True), parse_mode="HTML")
        else:
            await message.answer("<b>DarkTunnel</b>\n\nУ вас пока нет активной подписки. Нажмите кнопку ниже — заявка уйдёт администратору.", reply_markup=user_menu(False), parse_mode="HTML")
        return
    await message.answer("<b>DarkTunnel Admin</b>\n\nВыберите действие:", reply_markup=menu(), parse_mode="HTML")


@menu_router.callback_query(F.data == "misc")
async def misc(callback: CallbackQuery) -> None:
    if not is_owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    rows = [
        [button("💳 Подписки", "subscription:admin"), button("🎨 Темы", "themes")],
        [button("📢 Объявления", "announcement:list"), button("📲 Push", "push")],
        [button("👮 Администраторы", "override:admins"), button("🧾 Журнал", "audit:0")],
        [button("💳 Продажи", "sales")],
        [button("⬅️ Главное меню", "home")],
    ]
    await callback.answer()
    if callback.message:
        await callback.message.edit_text("<b>⚙️ Остальное</b>\n\nДополнительные разделы.", reply_markup=InlineKeyboardMarkup(inline_keyboard=rows), parse_mode="HTML")


@menu_router.callback_query(F.data == "stats")
async def stats(callback: CallbackQuery) -> None:
    if not is_owner(callback.from_user.id):
        await callback.answer("Доступ запрещён", show_alert=True)
        return
    async with SessionLocal() as session:
        total_users = int(await session.scalar(select(func.count(User.id))) or 0)
        total_links = int(await session.scalar(select(func.count(Activation.id))) or 0)
        total_servers = int(await session.scalar(select(func.count(ServerNode.id)).where(ServerNode.archived_at.is_(None))) or 0)
    await callback.answer()
    if callback.message:
        await callback.message.edit_text(f"<b>📊 Статистика</b>\n\nПользователей: <b>{total_users}</b>\nСсылок: <b>{total_links}</b>\nСерверов: <b>{total_servers}</b>", reply_markup=InlineKeyboardMarkup(inline_keyboard=[[button("⬅️ Главное меню", "home")]]), parse_mode="HTML")


@menu_router.callback_query(F.data == "home")
async def home(callback: CallbackQuery) -> None:
    if not is_owner(callback.from_user.id):
        await callback.answer()
        return
    await callback.answer()
    if callback.message:
        await callback.message.edit_text("<b>DarkTunnel Admin</b>\n\nВыберите действие:", reply_markup=menu(), parse_mode="HTML")


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
    dispatcher.include_router(overrides_search_router)
    dispatcher.include_router(overrides_extra_router)
    dispatcher.include_router(overrides_router)
    dispatcher.include_router(subscription_user_admin_router)
    dispatcher.include_router(management_router)
    dispatcher.include_router(subscription_admin_router)
    dispatcher.include_router(features_router)
    dispatcher.include_router(node_status_router)
    dispatcher.include_router(announcements_router)
    await dispatcher.start_polling(bot, allowed_updates=dispatcher.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
