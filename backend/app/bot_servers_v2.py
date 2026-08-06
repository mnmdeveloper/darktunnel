from __future__ import annotations

import asyncio
from html import escape

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import select

from .config import get_settings
from .db import SessionLocal
from .infrastructure_models import OnboardingStatus, ServerOnboardingJob, ServerTransport
from .models import ServerNode
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
    private_key = State()
    confirm = State()


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id == user_id)


def servers_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [b("➕ Добавить сервер", "srv2:add")],
        [b("🔄 Обновить все", "srv2:update-all"), b("🩺 Проверить все", "srv2:check-all")],
        [b("📋 Список серверов", "srv2:list")],
        [b("⬅️ Главное меню", "home")],
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
            "Новый сервер настраивается автоматически: бот обнаружит AWG2 и VK Turn, включит автовыбор и опубликует только рабочие транспорты.",
            reply_markup=servers_menu(),
            parse_mode="HTML",
        )
    await callback.answer()


@router.callback_query(F.data == "srv2:add")
async def add_start(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback):
        return
    await state.clear()
    await state.set_state(ServerWizard.name)
    if callback.message:
        await callback.message.edit_text("<b>Добавление сервера · 1/7</b>\n\nВведите название сервера:", parse_mode="HTML")
    await callback.answer()


@router.message(ServerWizard.name)
async def add_name(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value:
        await message.answer("Название не может быть пустым."); return
    await state.update_data(name=value)
    await state.set_state(ServerWizard.country)
    await message.answer("<b>Добавление сервера · 2/7</b>\n\nВведите страну:", parse_mode="HTML")


@router.message(ServerWizard.country)
async def add_country(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value:
        await message.answer("Страна не может быть пустой."); return
    await state.update_data(country=value)
    await state.set_state(ServerWizard.city)
    await message.answer("<b>Добавление сервера · 3/7</b>\n\nВведите город:", parse_mode="HTML")


@router.message(ServerWizard.city)
async def add_city(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value:
        await message.answer("Город не может быть пустым."); return
    await state.update_data(city=value)
    await state.set_state(ServerWizard.address)
    await message.answer("<b>Добавление сервера · 4/7</b>\n\nВведите SSH-адрес: <code>IP</code> или <code>IP:порт</code>.", parse_mode="HTML")


@router.message(ServerWizard.address)
async def add_address(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    try:
        host, port = parse_ssh_address(message.text or "")
    except (ValueError, TypeError):
        await message.answer("Некорректный SSH-адрес."); return
    await state.update_data(host=host, port=port)
    await state.set_state(ServerWizard.username)
    await message.answer("<b>Добавление сервера · 5/7</b>\n\nВведите SSH-пользователя, например <code>root</code>:", parse_mode="HTML")


@router.message(ServerWizard.username)
async def add_username(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = (message.text or "").strip()[:128]
    if not value:
        await message.answer("Имя пользователя не может быть пустым."); return
    await state.update_data(username=value)
    await state.set_state(ServerWizard.password)
    await message.answer(
        "<b>Добавление сервера · 6/7</b>\n\nОтправьте SSH-пароль. Он используется только в памяти во время подключения и не сохраняется.\n\n"
        "Если вход только по ключу, отправьте <code>-</code>.", parse_mode="HTML"
    )


@router.message(ServerWizard.password)
async def add_password(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    value = message.text or ""
    try:
        await message.delete()
    except Exception:
        pass
    await state.update_data(password=None if value.strip() == "-" else value)
    await state.set_state(ServerWizard.private_key)
    await message.answer(
        "<b>Добавление сервера · 7/7</b>\n\nОтправьте приватный SSH-ключ текстом или файлом. Если используете пароль, отправьте <code>-</code>.",
        parse_mode="HTML",
    )


@router.message(ServerWizard.private_key)
async def add_key(message: Message, state: FSMContext) -> None:
    if await deny_message(message): return
    key: str | None = None
    if message.document:
        if not message.bot:
            await message.answer("Не удалось прочитать файл."); return
        file = await message.bot.get_file(message.document.file_id)
        buffer = await message.bot.download_file(file.file_path)
        key = buffer.read().decode("utf-8") if buffer else None
    elif (message.text or "").strip() != "-":
        key = message.text or None
    try:
        await message.delete()
    except Exception:
        pass
    data = await state.get_data()
    if not data.get("password") and not key:
        await message.answer("Нужен пароль или приватный SSH-ключ."); return
    await state.update_data(private_key=key)
    credentials = SSHCredentials(
        host=data["host"], port=data["port"], username=data["username"],
        password=data.get("password"), private_key=key,
    )
    status = await message.answer("🔐 Подключаюсь и получаю fingerprint SSH-сервера…")
    try:
        fingerprint = await inspect_fingerprint(credentials)
    except Exception as exc:
        await state.clear()
        await status.edit_text(f"❌ SSH-подключение не удалось:\n<code>{escape(str(exc)[:1000])}</code>", parse_mode="HTML")
        return
    await state.update_data(fingerprint=fingerprint)
    await state.set_state(ServerWizard.confirm)
    await status.edit_text(
        "<b>Подтвердите сервер</b>\n\n"
        f"Название: <b>{escape(data['name'])}</b>\n"
        f"Место: <b>{escape(data['country'])}, {escape(data['city'])}</b>\n"
        f"SSH: <code>{escape(data['username'])}@{escape(data['host'])}:{data['port']}</code>\n"
        f"Fingerprint: <code>{escape(fingerprint)}</code>\n\n"
        "После подтверждения бот установит только управляющий агент, обнаружит существующие AWG2/WDTT и не перезапустит рабочие VPN-сервисы.",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [b("✅ Fingerprint верный — продолжить", "srv2:confirm")],
            [b("❌ Отмена", "servers")],
        ]), parse_mode="HTML"
    )


@router.callback_query(ServerWizard.confirm, F.data == "srv2:confirm")
async def confirm(callback: CallbackQuery, state: FSMContext) -> None:
    if await deny_callback(callback): return
    data = await state.get_data()
    await callback.answer("Установка запущена")
    if callback.message:
        await callback.message.edit_text("⏳ Устанавливаю агент, обнаруживаю транспорты и регистрирую сервер…")
    async with SessionLocal() as session:
        job = ServerOnboardingJob(
            admin_id=callback.from_user.id,
            name=data["name"], country=data["country"], city=data["city"],
            ssh_host=data["host"], ssh_port=data["port"], ssh_user=data["username"],
            host_key_fingerprint=data["fingerprint"], status=OnboardingStatus.installing, progress=20,
        )
        session.add(job); await session.commit(); await session.refresh(job)
        try:
            discovery = await install_and_discover(
                SSHCredentials(data["host"], data["port"], data["username"], data.get("password"), data.get("private_key")),
                ServerDraft(data["name"], data["country"], data["city"], callback.from_user.id),
                data["fingerprint"],
            )
            node = await register_discovery(
                session,
                ServerDraft(data["name"], data["country"], data["city"], callback.from_user.id),
                discovery, data["fingerprint"], job,
            )
            transports = discovery.get("transports", {})
            awg = "✅" if transports.get("amneziawg2", {}).get("detected") else "⚪️"
            wdtt = "✅" if transports.get("wdtt", {}).get("detected") else "⚪️"
            text = (
                f"<b>✅ Сервер добавлен</b>\n\n"
                f"{escape(node.name)} · {escape(node.country_name)}, {escape(node.city)}\n"
                f"Адрес: <code>{escape(node.host)}</code>\n"
                f"{awg} AmneziaWG 2.0\n{wdtt} VK Turn / WDTT\n\n"
                f"Автовыбор включён. Опубликованы только обнаруженные транспорты."
            )
        except Exception as exc:
            job.status = OnboardingStatus.failed; job.progress = 0; job.detail = str(exc)[:3000]
            await session.commit()
            text = f"<b>❌ Сервер не добавлен</b>\n\n<code>{escape(str(exc)[:1500])}</code>\n\nРабочие VPN-сервисы не изменялись."
    await state.clear()
    if callback.message:
        await callback.message.edit_text(text, reply_markup=servers_menu(), parse_mode="HTML")


@router.callback_query(F.data == "srv2:list")
async def list_servers(callback: CallbackQuery) -> None:
    if await deny_callback(callback): return
    async with SessionLocal() as session:
        nodes = (await session.execute(select(ServerNode).where(ServerNode.archived_at.is_(None)).order_by(ServerNode.created_at))).scalars().all()
        lines = []
        for node in nodes:
            transports = (await session.execute(select(ServerTransport).where(ServerTransport.server_id == node.id))).scalars().all()
            labels = [f"{'✅' if t.online else '❌'} {t.transport_type.value}" for t in transports if t.enabled]
            lines.append(f"• <b>{escape(node.name)}</b> — {escape(node.city or '—')}\n  {' · '.join(labels) or 'транспорты не обнаружены'}")
    text = "<b>📋 Серверы</b>\n\n" + ("\n\n".join(lines) if lines else "Серверов пока нет.")
    if callback.message:
        await callback.message.edit_text(text, reply_markup=servers_menu(), parse_mode="HTML")
    await callback.answer()


@router.callback_query(F.data.in_({"srv2:update-all", "srv2:check-all"}))
async def not_ready_remote_actions(callback: CallbackQuery) -> None:
    if await deny_callback(callback): return
    await callback.answer("Функция появится после безопасного хранения deployment credentials", show_alert=True)
