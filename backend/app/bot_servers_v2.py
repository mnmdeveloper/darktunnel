from __future__ import annotations

import asyncio
from html import escape
from uuid import UUID

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import select

from .config import get_settings
from .db import SessionLocal
from .infrastructure_models import OnboardingStatus, ServerOnboardingJob, ServerTransport
from .models import AuditLog, ServerNode
from .server_onboarding_v2 import (
    SSHCredentials,
    ServerDraft,
    inspect_fingerprint,
    install_and_discover,
    parse_ssh_address,
    register_discovery,
)

router = Router(name="servers-v2")


class ServerWizard(StatesGroup):
    name = State()
    country = State()
    city = State()
    address = State()
    username = State()
    password = State()
    confirm = State()


class ServerEditor(StatesGroup):
    value = State()


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id == user_id)


def servers_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [b("➕ Добавить сервер", "srv2:add")],
        [b("📋 Список и редактирование", "srv2:list")],
        [b("🔄 Обновить все", "srv2:update-all"), b("🩺 Проверить все", "srv2:check-all")],
        [b("⬅️ Главное меню", "home")],
    ])


def server_card_keyboard(node: ServerNode) -> InlineKeyboardMarkup:
    publish_text = "🙈 Скрыть из приложения" if node.published else "👁 Опубликовать"
    return InlineKeyboardMarkup(inline_keyboard=[
        [b("✏️ Название", f"srv2:edit:{node.id}:name")],
        [b("🌍 Страна", f"srv2:edit:{node.id}:country_name"), b("🏙 Город", f"srv2:edit:{node.id}:city")],
        [b(publish_text, f"srv2:toggle-published:{node.id}")],
        [b("⬅️ К списку", "srv2:list")],
    ])


async def deny_message(message: Message) -> bool:
    if owner(message.from_user.id if message.from_user else None):
        return False
    await message.answer("Доступ запрещён.")
    return True


async def deny_callback(callback: CallbackQuery) -> bool:
    if owner(callback.from_user.id):
        return False
    await callback.answer("Доступ запрещён", show_alert=True)
    return True


async def get_node(node_id: str) -> ServerNode | None:
    try:
        parsed = UUID(node_id)
    except ValueError:
        return None
    async with SessionLocal() as session:
        return await session.get(ServerNode, parsed)


async def render_server(callback: CallbackQuery, node_id: str) -> None:
    node = await get_node(node_id)
    if node is None or node.archived_at is not None:
        await callback.answer("Сервер не найден", show_alert=True)
        return
    async with SessionLocal() as session:
        transports = (await session.execute(select(ServerTransport).where(ServerTransport.server_id == node.id))).scalars().all()
    transport_lines = [
        f"{'✅' if item.online else '❌'} {item.transport_type.value} · <code>{escape(item.host)}:{item.port}</code>"
        for item in transports if item.enabled
    ]
    text = (
        f"<b>🖥 {escape(node.name)}</b>\n\n"
        f"Страна: <b>{escape(node.country_name or '—')}</b>\n"
        f"Город: <b>{escape(node.city or '—')}</b>\n"
        f"Адрес: <code>{escape(node.host)}</code>\n"
        f"В приложении: <b>{'да' if node.published else 'нет'}</b>\n"
        f"Автовыбор: <b>{'да' if node.auto_select else 'нет'}</b>\n\n"
        + ("\n".join(transport_lines) if transport_lines else "Транспорты не зарегистрированы")
    )
    if callback.message:
        await callback.message.edit_text(text, reply_markup=server_card_keyboard(node), parse_mode="HTML")
    await callback.answer()


@router.callback_query(F.data == "servers")
async def servers(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback):
        return
    await state.clear()
    async with SessionLocal() as session:
        count = len((await session.execute(select(ServerNode).where(ServerNode.archived_at.is_(None)))).scalars().all())
    if callback.message:
        await callback.message.edit_text(
            f"<b>🖥 Серверы</b>\n\nДобавлено серверов: <b>{count}</b>\n"
            "Добавление автоматически ждёт apt/dpkg, сохраняет WDTT-пароль и порты, проверяет AWG2, WDTT и node-agent и не меняет уже работающие VPN-сервисы.",
            reply_markup=servers_menu(),
            parse_mode="HTML",
        )
    await callback.answer()


@router.callback_query(F.data == "srv2:add")
async def add_start(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback): return
    await state.clear(); await state.set_state(ServerWizard.name)
    if callback.message: await callback.message.edit_text("<b>Добавление сервера · 1/6</b>\n\nВведите название сервера:", parse_mode="HTML")
    await callback.answer()


@router.message(ServerWizard.name)
async def add_name(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value: await message.answer("Название не может быть пустым."); return
    await state.update_data(name=value); await state.set_state(ServerWizard.country)
    await message.answer("<b>Добавление сервера · 2/6</b>\n\nВведите страну:", parse_mode="HTML")


@router.message(ServerWizard.country)
async def add_country(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value: await message.answer("Страна не может быть пустой."); return
    await state.update_data(country=value); await state.set_state(ServerWizard.city)
    await message.answer("<b>Добавление сервера · 3/6</b>\n\nВведите город:", parse_mode="HTML")


@router.message(ServerWizard.city)
async def add_city(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value: await message.answer("Город не может быть пустым."); return
    await state.update_data(city=value); await state.set_state(ServerWizard.address)
    await message.answer("<b>Добавление сервера · 4/6</b>\n\nВведите SSH-адрес: <code>IP</code> или <code>IP:порт</code>.", parse_mode="HTML")


@router.message(ServerWizard.address)
async def add_address(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    try: host, port = parse_ssh_address(message.text or "")
    except (ValueError, TypeError): await message.answer("Некорректный SSH-адрес."); return
    await state.update_data(host=host, port=port); await state.set_state(ServerWizard.username)
    await message.answer("<b>Добавление сервера · 5/6</b>\n\nВведите SSH-пользователя, например <code>root</code>:", parse_mode="HTML")


@router.message(ServerWizard.username)
async def add_username(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value: await message.answer("Имя пользователя не может быть пустым."); return
    await state.update_data(username=value); await state.set_state(ServerWizard.password)
    await message.answer("<b>Добавление сервера · 6/6</b>\n\nОтправьте SSH-пароль. Сообщение будет удалено, пароль используется только в памяти и не сохраняется.", parse_mode="HTML")


@router.message(ServerWizard.password)
async def add_password(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    password = message.text or ""
    try: await message.delete()
    except Exception: pass
    if not password: await message.answer("SSH-пароль не может быть пустым."); return
    await state.update_data(password=password); data = await state.get_data()
    credentials = SSHCredentials(host=data["host"], port=data["port"], username=data["username"], password=password)
    status = await message.answer("🔐 Подключаюсь и получаю fingerprint SSH-сервера…")
    try: fingerprint = await asyncio.wait_for(inspect_fingerprint(credentials), timeout=40)
    except Exception as exc:
        await state.clear(); await status.edit_text(f"❌ SSH-подключение не удалось:\n<code>{escape(str(exc)[:1000])}</code>", parse_mode="HTML"); return
    await state.update_data(fingerprint=fingerprint); await state.set_state(ServerWizard.confirm)
    await status.edit_text(
        "<b>Подтвердите сервер</b>\n\n"
        f"Название: <b>{escape(data['name'])}</b>\nМесто: <b>{escape(data['country'])}, {escape(data['city'])}</b>\n"
        f"SSH: <code>{escape(data['username'])}@{escape(data['host'])}:{data['port']}</code>\nFingerprint: <code>{escape(fingerprint)}</code>\n\n"
        "Бот дождётся системных обновлений, восстановит незавершённый dpkg, установит только отсутствующие компоненты и проверит готовность всех сервисов.",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[b("✅ Продолжить", "srv2:confirm")],[b("❌ Отмена", "servers")]]), parse_mode="HTML")


async def _progress(message: Message, task: asyncio.Task) -> None:
    stages = [
        "⏳ 1/4 Подключение и ожидание apt/dpkg…",
        "⏳ 2/4 Проверка и установка отсутствующих компонентов…",
        "⏳ 3/4 Проверка AWG2, WDTT и node-agent…",
        "⏳ 4/4 Сохранение защищённой конфигурации…",
    ]
    index = 0
    while not task.done():
        try: await message.edit_text(stages[min(index, len(stages)-1)])
        except Exception: pass
        index += 1
        await asyncio.sleep(30)


@router.callback_query(ServerWizard.confirm, F.data == "srv2:confirm")
async def confirm(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback): return
    data = await state.get_data(); await callback.answer("Установка запущена")
    if not callback.message: return
    await callback.message.edit_text("⏳ 1/4 Подключение и ожидание apt/dpkg…")
    async with SessionLocal() as session:
        job = ServerOnboardingJob(admin_id=callback.from_user.id,name=data["name"],country=data["country"],city=data["city"],ssh_host=data["host"],ssh_port=data["port"],ssh_user=data["username"],host_key_fingerprint=data["fingerprint"],status=OnboardingStatus.installing,progress=20)
        session.add(job); await session.commit(); await session.refresh(job)
        install_task = asyncio.create_task(install_and_discover(SSHCredentials(data["host"],data["port"],data["username"],data["password"]),ServerDraft(data["name"],data["country"],data["city"],callback.from_user.id),data["fingerprint"]))
        progress_task = asyncio.create_task(_progress(callback.message, install_task))
        try:
            discovery = await asyncio.wait_for(install_task, timeout=2100)
            progress_task.cancel()
            try: await progress_task
            except asyncio.CancelledError: pass
            await callback.message.edit_text("⏳ 4/4 Сохранение защищённой конфигурации…")
            node = await register_discovery(session,ServerDraft(data["name"],data["country"],data["city"],callback.from_user.id),discovery,data["fingerprint"],job)
            transports = discovery.get("transports", {})
            awg = "✅" if transports.get("amneziawg2", {}).get("online") else "❌"
            wdtt = "✅" if transports.get("wdtt", {}).get("online") else "❌"
            text = f"<b>✅ Сервер добавлен</b>\n\n{escape(node.name)} · {escape(node.country_name)}, {escape(node.city)}\nАдрес: <code>{escape(node.host)}</code>\n{awg} AmneziaWG 2.0\n{wdtt} VK Turn / WDTT\n\nСервер опубликован и доступен приложению."
        except asyncio.TimeoutError:
            progress_task.cancel(); job.status=OnboardingStatus.failed; job.progress=0; job.detail="Installation timeout after 35 minutes"; await session.commit()
            text="<b>❌ Установка превысила 35 минут</b>\n\nПроверьте доступность VPS и повторите установку."
        except Exception as exc:
            progress_task.cancel(); job.status=OnboardingStatus.failed; job.progress=0; job.detail=str(exc)[:3000]; await session.commit()
            text=f"<b>❌ Сервер не добавлен</b>\n\n<code>{escape(str(exc)[:1500])}</code>\n\nРабочие VPN-сервисы не изменялись."
    await state.clear(); await callback.message.edit_text(text, reply_markup=servers_menu(), parse_mode="HTML")


@router.callback_query(F.data == "srv2:list")
async def list_servers(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback): return
    await state.clear()
    async with SessionLocal() as session:
        nodes = (await session.execute(select(ServerNode).where(ServerNode.archived_at.is_(None)).order_by(ServerNode.created_at))).scalars().all()
    rows = [[b(f"{'🟢' if node.published else '⚪️'} {node.name} · {node.city or '—'}", f"srv2:view:{node.id}")] for node in nodes]
    rows.append([b("➕ Добавить сервер", "srv2:add")])
    rows.append([b("⬅️ Назад", "servers")])
    text = "<b>📋 Серверы</b>\n\nНажмите на сервер для просмотра и редактирования."
    if not nodes:
        text += "\n\nСерверов пока нет."
    if callback.message: await callback.message.edit_text(text, reply_markup=InlineKeyboardMarkup(inline_keyboard=rows), parse_mode="HTML")
    await callback.answer()


@router.callback_query(F.data.startswith("srv2:view:"))
async def view_server(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback): return
    await state.clear()
    await render_server(callback, callback.data.rsplit(":", 1)[1])


@router.callback_query(F.data.startswith("srv2:edit:"))
async def edit_server(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback): return
    _, _, node_id, field = callback.data.split(":", 3)
    labels = {"name": "новое название", "country_name": "новую страну", "city": "новый город"}
    if field not in labels or await get_node(node_id) is None:
        await callback.answer("Сервер или поле не найдены", show_alert=True); return
    await state.set_state(ServerEditor.value)
    await state.update_data(edit_node_id=node_id, edit_field=field)
    if callback.message:
        await callback.message.edit_text(f"Введите {labels[field]} сервера:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[[b("❌ Отмена", f"srv2:view:{node_id}")]]))
    await callback.answer()


@router.message(ServerEditor.value)
async def save_server_edit(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value:
        await message.answer("Значение не может быть пустым."); return
    data = await state.get_data()
    try: node_id = UUID(data["edit_node_id"])
    except (KeyError, ValueError):
        await state.clear(); await message.answer("Сессия редактирования устарела."); return
    field = data.get("edit_field")
    if field not in {"name", "country_name", "city"}:
        await state.clear(); await message.answer("Недопустимое поле."); return
    async with SessionLocal() as session:
        node = await session.get(ServerNode, node_id)
        if node is None:
            await state.clear(); await message.answer("Сервер не найден."); return
        old_value = getattr(node, field)
        setattr(node, field, value)
        session.add(AuditLog(admin_id=message.from_user.id, action=f"server.edit.{field}", entity_type="server", entity_id=str(node.id), result="success"))
        await session.commit()
    await state.clear()
    await message.answer(
        f"✅ Изменено: <b>{escape(str(old_value or '—'))}</b> → <b>{escape(value)}</b>",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[b("🖥 Открыть сервер", f"srv2:view:{node_id}")],[b("📋 К списку", "srv2:list")]]),
        parse_mode="HTML",
    )


@router.callback_query(F.data.startswith("srv2:toggle-published:"))
async def toggle_published(callback: CallbackQuery) -> None:
    if await deny_callback(callback): return
    try: node_id = UUID(callback.data.rsplit(":", 1)[1])
    except ValueError:
        await callback.answer("Некорректный сервер", show_alert=True); return
    async with SessionLocal() as session:
        node = await session.get(ServerNode, node_id)
        if node is None:
            await callback.answer("Сервер не найден", show_alert=True); return
        node.published = not node.published
        session.add(AuditLog(admin_id=callback.from_user.id, action="server.publish" if node.published else "server.unpublish", entity_type="server", entity_id=str(node.id), result="success"))
        await session.commit()
    await render_server(callback, str(node_id))


@router.callback_query(F.data.in_({"srv2:update-all", "srv2:check-all"}))
async def not_ready_remote_actions(callback: CallbackQuery) -> None:
    if await deny_callback(callback): return
    await callback.answer("Безопасное массовое обновление будет добавлено отдельно", show_alert=True)
