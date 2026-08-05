import asyncio
from datetime import UTC, datetime
from html import escape

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import func, select

from .config import get_settings
from .db import SessionLocal
from .models import AuditLog, ServerHealth, ServerNode
from .server_crypto import encrypt_server_config
from .server_onboarding import install_wdtt_node, probe_server, validate_host

router = Router(name="admin-features")


class ServerInstallWizard(StatesGroup):
    host = State()
    username = State()
    password = State()


def btn(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def home_button() -> list[InlineKeyboardButton]:
    return [btn("⬅️ Главное меню", "home")]


def owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id and user_id == settings.telegram_owner_id)


async def reject_callback(callback: CallbackQuery) -> bool:
    if owner(callback.from_user.id):
        return False
    await callback.answer("Доступ запрещён", show_alert=True)
    return True


async def reject_message(message: Message) -> bool:
    if owner(message.from_user.id if message.from_user else None):
        return False
    await message.answer("Доступ запрещён.")
    return True


async def edit(callback: CallbackQuery, text: str, keyboard: list[list[InlineKeyboardButton]]) -> None:
    if callback.message:
        await callback.message.edit_text(text, reply_markup=InlineKeyboardMarkup(inline_keyboard=keyboard), parse_mode="HTML")
    await callback.answer()


@router.callback_query(F.data == "servers")
async def servers(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    async with SessionLocal() as session:
        total = int(await session.scalar(select(func.count(ServerNode.id)).where(ServerNode.archived_at.is_(None))) or 0)
        published = int(await session.scalar(select(func.count(ServerNode.id)).where(ServerNode.published.is_(True), ServerNode.archived_at.is_(None))) or 0)
    await edit(
        callback,
        f"<b>🖥 Серверы</b>\n\nВсего: <b>{total}</b>\nОпубликовано: <b>{published}</b>\n\nДля установки нужны только IP, SSH-пользователь и пароль.",
        [[btn("➕ Установить на сервер", "server:install")], [btn("📋 Список серверов", "server:list")], home_button()],
    )


@router.callback_query(F.data == "server:install")
async def server_install_start(callback: CallbackQuery, state: FSMContext) -> None:
    if await reject_callback(callback):
        return
    settings = get_settings()
    if not settings.wdtt_vk_call_link:
        await callback.answer("На backend не настроен WDTT_VK_CALL_LINK", show_alert=True)
        return
    if not settings.server_config_encryption_key:
        await callback.answer("На backend не настроен SERVER_CONFIG_ENCRYPTION_KEY", show_alert=True)
        return
    await state.clear()
    await state.set_state(ServerInstallWizard.host)
    await edit(callback, "<b>Установка сервера · 1/3</b>\n\nОтправьте IP или hostname нового VPS.", [[btn("❌ Отмена", "servers")]])


@router.message(ServerInstallWizard.host)
async def server_install_host(message: Message, state: FSMContext) -> None:
    if await reject_message(message):
        return
    try:
        host = validate_host(message.text or "")
    except ValueError as error:
        await message.answer(f"❌ {escape(str(error))}. Отправьте IP ещё раз.", parse_mode="HTML")
        return
    await state.update_data(host=host)
    await state.set_state(ServerInstallWizard.username)
    await message.answer("<b>Установка сервера · 2/3</b>\n\nОтправьте SSH-пользователя, обычно <code>root</code>.", parse_mode="HTML")


@router.message(ServerInstallWizard.username)
async def server_install_username(message: Message, state: FSMContext) -> None:
    if await reject_message(message):
        return
    username = (message.text or "").strip()
    if not username or len(username) > 64 or any(ch.isspace() for ch in username):
        await message.answer("❌ Некорректное имя пользователя. Отправьте ещё раз.")
        return
    await state.update_data(username=username)
    await state.set_state(ServerInstallWizard.password)
    await message.answer("<b>Установка сервера · 3/3</b>\n\nОтправьте SSH-пароль. Сообщение будет сразу удалено, пароль не сохранится.", parse_mode="HTML")


@router.message(ServerInstallWizard.password)
async def server_install_password(message: Message, state: FSMContext) -> None:
    if await reject_message(message):
        return
    password = message.text or ""
    try:
        await message.delete()
    except Exception:
        pass
    data = await state.get_data()
    await state.clear()
    host = data["host"]
    username = data["username"]
    progress = await message.answer(
        f"⏳ <b>Устанавливаю DarkTunnel на {escape(host)}</b>\n\nПодключение по SSH → установка WDTT → настройка сети → проверки → регистрация. Это может занять несколько минут.",
        parse_mode="HTML",
    )
    try:
        probe = await probe_server(host=host, port=22, username=username, password=password)
        result = await install_wdtt_node(
            host=host,
            port=22,
            username=username,
            password=password,
            expected_host_key_sha256=probe.host_key_sha256,
            public_host=host,
            vk_call_link=get_settings().wdtt_vk_call_link,
            public_port=56000,
        )
        encrypted = encrypt_server_config({
            "wrap_a_password": result.generated_secret,
            "ssh_host_key_sha256": probe.host_key_sha256,
            "installed_at": datetime.now(UTC).isoformat(),
        })
        async with SessionLocal() as session:
            existing = await session.scalar(select(ServerNode).where(ServerNode.host == host, ServerNode.archived_at.is_(None)))
            if existing is None:
                node = ServerNode(
                    name=f"Server {host}",
                    host=host,
                    port=result.public_port,
                    protocol_mode="srtp-wrap-a",
                    encrypted_config=encrypted,
                    mtu=1280,
                    dns="1.1.1.1",
                    balanced_connections=3,
                    max_connections=10,
                    published=True,
                    auto_select=True,
                )
                session.add(node)
                await session.flush()
            else:
                node = existing
                node.encrypted_config = encrypted
                node.port = result.public_port
                node.published = True
                node.auto_select = True
                node.maintenance = False
            session.add(ServerHealth(
                server_id=node.id,
                online=result.service_active and result.interface_ready and result.udp_listening,
                error_code="" if result.service_active else "install_health_failed",
            ))
            session.add(AuditLog(admin_id=message.from_user.id, action="server.install", entity_type="server", entity_id=str(node.id)))
            await session.commit()
        await progress.edit_text(
            f"✅ <b>Сервер установлен и добавлен</b>\n\nАдрес: <code>{escape(host)}:{result.public_port}</code>\nWDTT: работает\nСеть: настроена\nАвтовыбор: включён\nПубликация: включена\n\nSSH-пароль не сохранён.",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[btn("🖥 К серверам", "servers")], home_button()]),
            parse_mode="HTML",
        )
    except Exception as error:
        async with SessionLocal() as session:
            session.add(AuditLog(admin_id=message.from_user.id, action="server.install", entity_type="server", entity_id=host, result="error"))
            await session.commit()
        await progress.edit_text(
            f"❌ <b>Установка не завершена</b>\n\n{escape(str(error))}\n\nПароль не сохранён. Исправьте доступ к VPS и повторите установку.",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[btn("🔁 Повторить", "server:install")], [btn("🖥 К серверам", "servers")]]),
            parse_mode="HTML",
        )
    finally:
        password = ""


@router.callback_query(F.data == "server:list")
async def server_list(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    async with SessionLocal() as session:
        rows = (await session.execute(select(ServerNode).where(ServerNode.archived_at.is_(None)).order_by(ServerNode.created_at.desc()).limit(30))).scalars().all()
    keyboard: list[list[InlineKeyboardButton]] = []
    for row in rows:
        icon = "🛠" if row.maintenance else ("🟢" if row.published else "⚪️")
        keyboard.append([btn(f"{icon} {row.name} · {row.host}", f"server:view:{row.id}")])
    if not rows:
        keyboard.append([btn("➕ Установить первый сервер", "server:install")])
    keyboard.append([btn("⬅️ Серверы", "servers")])
    await edit(callback, "<b>📋 Серверы</b>\n\n🟢 опубликован · ⚪️ скрыт · 🛠 техработы", keyboard)


@router.callback_query(F.data.startswith("server:view:"))
async def server_view(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    node_id = callback.data.split(":", 2)[2]
    async with SessionLocal() as session:
        node = await session.get(ServerNode, node_id)
        health = await session.scalar(select(ServerHealth).where(ServerHealth.server_id == node_id).order_by(ServerHealth.timestamp.desc()).limit(1))
    if node is None:
        await callback.answer("Сервер не найден", show_alert=True)
        return
    online = "online" if health and health.online else "нет свежей проверки"
    keyboard = [
        [btn("🙈 Скрыть" if node.published else "📢 Опубликовать", f"server:publish:{node.id}")],
        [btn("✅ Завершить техработы" if node.maintenance else "🛠 Техработы", f"server:maintenance:{node.id}")],
        [btn("🎯 Убрать из автовыбора" if node.auto_select else "🎯 Вернуть в автовыбор", f"server:auto:{node.id}")],
        [btn("🗄 Архивировать", f"server:archive:confirm:{node.id}")],
        [btn("⬅️ К списку", "server:list")],
    ]
    await edit(callback, f"<b>🖥 {escape(node.name)}</b>\n\nАдрес: <code>{escape(node.host)}:{node.port}</code>\nСтатус: <b>{online}</b>\nОпубликован: <b>{'да' if node.published else 'нет'}</b>\nАвтовыбор: <b>{'да' if node.auto_select else 'нет'}</b>\nТехработы: <b>{'да' if node.maintenance else 'нет'}</b>", keyboard)


async def toggle_node(callback: CallbackQuery, field: str, action: str) -> None:
    node_id = callback.data.rsplit(":", 1)[1]
    async with SessionLocal() as session:
        node = await session.get(ServerNode, node_id)
        if node is None:
            await callback.answer("Сервер не найден", show_alert=True)
            return
        setattr(node, field, not bool(getattr(node, field)))
        session.add(AuditLog(admin_id=callback.from_user.id, action=action, entity_type="server", entity_id=str(node.id)))
        await session.commit()
    callback.data = f"server:view:{node_id}"
    await server_view(callback)


@router.callback_query(F.data.startswith("server:publish:"))
async def server_publish(callback: CallbackQuery) -> None:
    if not await reject_callback(callback):
        await toggle_node(callback, "published", "server.publish.toggle")


@router.callback_query(F.data.startswith("server:maintenance:"))
async def server_maintenance(callback: CallbackQuery) -> None:
    if not await reject_callback(callback):
        await toggle_node(callback, "maintenance", "server.maintenance.toggle")


@router.callback_query(F.data.startswith("server:auto:"))
async def server_auto(callback: CallbackQuery) -> None:
    if not await reject_callback(callback):
        await toggle_node(callback, "auto_select", "server.auto_select.toggle")


@router.callback_query(F.data.startswith("server:archive:confirm:"))
async def server_archive_confirm(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    node_id = callback.data.rsplit(":", 1)[1]
    await edit(callback, "<b>Архивировать сервер?</b>\n\nОн исчезнет из приложения и автовыбора. Данные останутся в журнале.", [[btn("🗄 Да, архивировать", f"server:archive:{node_id}")], [btn("Отмена", f"server:view:{node_id}")]])


@router.callback_query(F.data.startswith("server:archive:"))
async def server_archive(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    node_id = callback.data.rsplit(":", 1)[1]
    async with SessionLocal() as session:
        node = await session.get(ServerNode, node_id)
        if node is None:
            await callback.answer("Сервер не найден", show_alert=True)
            return
        node.archived_at = datetime.now(UTC)
        node.published = False
        node.auto_select = False
        session.add(AuditLog(admin_id=callback.from_user.id, action="server.archive", entity_type="server", entity_id=str(node.id)))
        await session.commit()
    await callback.answer("Сервер архивирован", show_alert=True)
    callback.data = "server:list"
    await server_list(callback)


FEATURE_TEXTS = {
    "themes": ("🎨 Темы", "Загрузка OFF/ON-фонов, предпросмотр, публикация, скрытие и порядок изображений."),
    "announcements": ("📢 Объявления", "Баннеры в приложении: info, warning, critical, subscription; сроки, аудитория и состояния VPN."),
    "maintenance": ("🚨 Технические работы", "Информирование, блокировка новых подключений, полная остановка или обслуживание отдельного сервера."),
    "push": ("📲 Push", "Рассылки и уведомления пользователям. Модуль будет активирован после подключения APNs."),
    "admins": ("👮 Администраторы", "Owner, Administrator, Support, Content Manager и Viewer с раздельными правами."),
    "sales": ("💳 Продажи", "Архитектура предусмотрена, но продажи выключены до выбора платёжного провайдера."),
}


@router.callback_query(F.data.in_(set(FEATURE_TEXTS)))
async def feature_page(callback: CallbackQuery) -> None:
    if await reject_callback(callback):
        return
    title, description = FEATURE_TEXTS[callback.data]
    await edit(callback, f"<b>{title}</b>\n\n{description}", [home_button()])
