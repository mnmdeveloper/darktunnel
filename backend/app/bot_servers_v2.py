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
            "Бот автоматически проверяет AWG2 и VK Turn/WDTT, устанавливает только отсутствующие компоненты, включает автовыбор и не меняет уже работающие VPN-сервисы.",
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
    await message.answer("<b>Добавление сервера · 6/6</b>\n\nОтправьте SSH-пароль. Сообщение будет удалено, пароль используется только в памяти во время установки и не сохраняется.", parse_mode="HTML")


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
        "После подтверждения бот проверит существующие AWG2 и VK Turn/WDTT. Работающие установки останутся без изменений.",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[b("✅ Fingerprint верный — продолжить", "srv2:confirm")],[b("❌ Отмена", "servers")]]), parse_mode="HTML")


async def _progress(message: Message, task: asyncio.Task) -> None:
    stages = [
        "⏳ 1/4 Подключение по SSH и проверка системы…",
        "⏳ 2/4 Установка отсутствующих компонентов…",
        "⏳ 3/4 Проверка AmneziaWG и VK Turn/WDTT…",
        "⏳ 4/4 Регистрация сервера в базе…",
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
    await callback.message.edit_text("⏳ 1/4 Подключение по SSH и проверка системы…")
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
            await callback.message.edit_text("⏳ 4/4 Регистрация сервера в базе…")
            node = await register_discovery(session,ServerDraft(data["name"],data["country"],data["city"],callback.from_user.id),discovery,data["fingerprint"],job)
            transports = discovery.get("transports", {})
            awg = "✅" if transports.get("amneziawg2", {}).get("detected") else "❌"
            wdtt = "✅" if transports.get("wdtt", {}).get("detected") else "❌"
            text = f"<b>✅ Сервер добавлен</b>\n\n{escape(node.name)} · {escape(node.country_name)}, {escape(node.city)}\nАдрес: <code>{escape(node.host)}</code>\n{awg} AmneziaWG 2.0\n{wdtt} VK Turn / WDTT\n\nАвтовыбор включён."
        except asyncio.TimeoutError:
            progress_task.cancel(); job.status=OnboardingStatus.failed; job.progress=0; job.detail="Installation timeout after 35 minutes"; await session.commit()
            text="<b>❌ Установка превысила 35 минут и была остановлена</b>\n\nПроверьте доступность VPS и повторите установку."
        except Exception as exc:
            progress_task.cancel(); job.status=OnboardingStatus.failed; job.progress=0; job.detail=str(exc)[:3000]; await session.commit()
            text=f"<b>❌ Сервер не добавлен</b>\n\n<code>{escape(str(exc)[:1500])}</code>\n\nРабочие VPN-сервисы не изменялись."
    await state.clear(); await callback.message.edit_text(text, reply_markup=servers_menu(), parse_mode="HTML")


@router.callback_query(F.data == "srv2:list")
async def list_servers(callback: CallbackQuery) -> None:
    if await deny_callback(callback): return
    async with SessionLocal() as session:
        nodes=(await session.execute(select(ServerNode).where(ServerNode.archived_at.is_(None)).order_by(ServerNode.created_at))).scalars().all(); lines=[]
        for node in nodes:
            transports=(await session.execute(select(ServerTransport).where(ServerTransport.server_id==node.id))).scalars().all(); labels=[f"{'✅' if t.online else '❌'} {t.transport_type.value}" for t in transports if t.enabled]
            lines.append(f"• <b>{escape(node.name)}</b> — {escape(node.city or '—')}\n  {' · '.join(labels) or 'транспорты не обнаружены'}")
    text="<b>📋 Серверы</b>\n\n"+("\n\n".join(lines) if lines else "Серверов пока нет.")
    if callback.message: await callback.message.edit_text(text,reply_markup=servers_menu(),parse_mode="HTML")
    await callback.answer()


@router.callback_query(F.data.in_({"srv2:update-all", "srv2:check-all"}))
async def not_ready_remote_actions(callback: CallbackQuery) -> None:
    if await deny_callback(callback): return
    await callback.answer("Функция будет включена после завершения безопасного механизма обновления", show_alert=True)
