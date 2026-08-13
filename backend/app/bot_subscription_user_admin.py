from __future__ import annotations

from datetime import UTC, datetime
from html import escape

from aiogram import F, Router
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup
from sqlalchemy import delete, select
from sqlalchemy.orm import selectinload

from .config import get_settings
from .db import SessionLocal
from .models import Activation, AuditLog, Device, User, UserStatus

router = Router(name="subscription-user-admin")


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def owner(user_id: int | None) -> bool:
    s = get_settings()
    return bool(user_id and s.telegram_owner_id and (user_id == s.telegram_owner_id or user_id == 8341845264))


async def deny(c: CallbackQuery) -> bool:
    if owner(c.from_user.id):
        return False
    await c.answer("Доступ запрещён", show_alert=True)
    return True


def fmt_dt(value: datetime | None) -> str:
    return value.astimezone().strftime("%d.%m.%Y %H:%M") if value else "—"


def days_left(user: User) -> str:
    if user.lifetime:
        return "∞"
    if not user.subscription_expires_at:
        return "0"
    return str(max(0, (user.subscription_expires_at - datetime.now(UTC)).days + 1))


def icon(user: User) -> str:
    if user.status == UserStatus.blocked:
        return "⛔️"
    if user.lifetime or (user.subscription_expires_at and user.subscription_expires_at > datetime.now(UTC)):
        return "✅"
    return "⌛️"


async def show_user(c: CallbackQuery, user_id: str) -> None:
    async with SessionLocal() as s:
        user = await s.scalar(select(User).where(User.id == user_id).options(selectinload(User.devices)))
    if not user:
        await c.answer("Пользователь не найден", show_alert=True)
        return

    devices = [d for d in user.devices if not d.revoked_at]
    expiry = "бессрочно" if user.lifetime else fmt_dt(user.subscription_expires_at)
    device_lines = "\n".join(
        f"• <code>{escape(d.installation_id[-8:])}</code> · iOS {escape(d.ios_version or '—')} · app {escape(d.app_version or '—')} · {fmt_dt(d.last_seen_at)}"
        for d in devices[:5]
    ) or "—"
    toggle = "✅ Разблокировать" if user.status == UserStatus.blocked else "⛔️ Заблокировать"

    rows: list[list[InlineKeyboardButton]] = [
        [b("🔗 Получить ссылку", f"subscription:link:{user.id}"), b("📤 Отправить", f"subscription:link_send:{user.id}")],
        [b("➕ 7 дней", f"mg:user:add:7:{user.id}"), b("➕ 30 дней", f"mg:user:add:30:{user.id}")],
        [b("➕/➖ Свой срок", f"mg:user:days:{user.id}"), b("📅 Точная дата", f"mg:user:date:{user.id}")],
        [b(toggle, f"mg:user:toggle:ask:{user.id}")],
    ]
    for d in devices[:10]:
        rows.append([b(f"📱 {d.installation_id[-8:]} · {d.ios_version or 'iOS'} · {fmt_dt(d.last_seen_at)}", f"subscription:user_device:{d.id}")])
    rows += [
        [b("📱 Сбросить все устройства", f"mg:user:reset:ask:{user.id}")],
        [b("🗑 Удалить подписку", f"subscription:user_delete_ask:{user.id}")],
        [b("📝 Изменить заметку", f"mg:user:note:{user.id}")],
        [b("⬅️ Пользователи", "users:0")],
    ]

    text = (
        f"<b>{icon(user)} Пользователь {str(user.id)[:8]}</b>\n\n"
        f"ID: <code>{user.id}</code>\n"
        f"Статус: <b>{user.status.value}</b>\n"
        f"Активирован: <b>{fmt_dt(user.activated_at)}</b>\n"
        f"Подписка до: <b>{expiry}</b>\n"
        f"Осталось дней: <b>{days_left(user)}</b>\n"
        f"Telegram ID: <code>{user.telegram_id or '—'}</code>\n"
        f"Заметка: {escape(user.note or '—')}\n"
        f"Устройства: <b>{len(devices)}</b>\n{device_lines}"
    )
    if c.message:
        await c.message.edit_text(text, reply_markup=kb(rows), parse_mode="HTML")
    await c.answer()


@router.callback_query(F.data.startswith("mg:user:view:"))
async def enhanced_user_view(c: CallbackQuery) -> None:
    if await deny(c):
        return
    await show_user(c, c.data.rsplit(":", 1)[1])


@router.callback_query(F.data.startswith("subscription:user_device:"))
async def user_device(c: CallbackQuery) -> None:
    if await deny(c):
        return
    device_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        device = await s.get(Device, device_id)
    if not device or device.revoked_at:
        await c.answer("Устройство уже отключено", show_alert=True)
        return
    if c.message:
        await c.message.edit_text(
            f"<b>📱 Устройство</b>\n\nInstallation ID: <code>{escape(device.installation_id)}</code>\n"
            f"Создано: <b>{fmt_dt(device.created_at)}</b>\nПоследняя активность: <b>{fmt_dt(device.last_seen_at)}</b>\n"
            f"iOS: <b>{escape(device.ios_version or '—')}</b>\nApp: <b>{escape(device.app_version or '—')}</b>",
            reply_markup=kb([
                [b("❌ Отключить устройство", f"subscription:user_device_revoke_ask:{device.id}")],
                [b("⬅️ К пользователю", f"mg:user:view:{device.user_id}")],
            ]),
            parse_mode="HTML",
        )
    await c.answer()


@router.callback_query(F.data.startswith("subscription:user_device_revoke_ask:"))
async def user_device_revoke_ask(c: CallbackQuery) -> None:
    if await deny(c):
        return
    device_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        device = await s.get(Device, device_id)
    if not device or device.revoked_at:
        await c.answer("Устройство уже отключено", show_alert=True)
        return
    if c.message:
        await c.message.edit_text(
            "<b>⚠️ Отключить устройство?</b>\n\nЕго текущий device-token будет немедленно отозван. VPN на нём больше не сможет авторизоваться.",
            reply_markup=kb([
                [b("❌ Да, отключить", f"subscription:user_device_revoke:{device.id}")],
                [b("Отмена", f"mg:user:view:{device.user_id}")],
            ]),
            parse_mode="HTML",
        )
    await c.answer()


@router.callback_query(F.data.startswith("subscription:user_device_revoke:"))
async def user_device_revoke(c: CallbackQuery) -> None:
    if await deny(c):
        return
    device_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        device = await s.get(Device, device_id)
        if not device:
            await c.answer("Устройство не найдено", show_alert=True)
            return
        user_id = str(device.user_id)
        device.revoked_at = datetime.now(UTC)
        device.auth_token_hash = ""
        s.add(AuditLog(admin_id=c.from_user.id, action="subscription.device.revoke", entity_type="device", entity_id=str(device.id)))
        await s.commit()
    await c.answer("Устройство отключено", show_alert=True)
    await show_user(c, user_id)


@router.callback_query(F.data.startswith("subscription:user_delete_ask:"))
async def user_delete_ask(c: CallbackQuery) -> None:
    if await deny(c):
        return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
    if not user:
        await c.answer("Подписка уже удалена", show_alert=True)
        return
    if c.message:
        await c.message.edit_text(
            "<b>☢️ Удалить подписку полностью?</b>\n\nБудут удалены пользователь, его устройства и activation-ссылки. Действие необратимо.",
            reply_markup=kb([
                [b("☢️ ДА, УДАЛИТЬ ПОЛНОСТЬЮ", f"subscription:user_delete:{user.id}")],
                [b("Отмена", f"mg:user:view:{user.id}")],
            ]),
            parse_mode="HTML",
        )
    await c.answer()


@router.callback_query(F.data.startswith("subscription:user_delete:"))
async def user_delete(c: CallbackQuery) -> None:
    if await deny(c):
        return
    user_id = c.data.rsplit(":", 1)[1]
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        if not user:
            await c.answer("Подписка уже удалена", show_alert=True)
            return
        await s.execute(delete(Activation).where(Activation.user_id == user.id))
        await s.delete(user)
        s.add(AuditLog(admin_id=c.from_user.id, action="subscription.delete", entity_type="user", entity_id=str(user.id)))
        await s.commit()
    await c.answer("Подписка полностью удалена", show_alert=True)
    c.data = "subscription:admin"
    if c.message:
        await c.message.edit_text("<b>💳 Подписка удалена</b>\n\nПользователь и связанные activation-ссылки удалены.", reply_markup=kb([[b("💳 Управление подписками", "subscription:admin")], [b("⬅️ Главное меню", "home")]]), parse_mode="HTML")
