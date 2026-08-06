from __future__ import annotations

from html import escape

from aiogram import F, Router
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup
from sqlalchemy import select

from .activation_links import public_activation_link
from .config import get_settings
from .db import SessionLocal
from .models import Activation
from .schemas import ActivationCreate
from .services import create_activation

router = Router(name="access-v2")


def b(text: str, data: str) -> InlineKeyboardButton:
    return InlineKeyboardButton(text=text, callback_data=data)


def owner(user_id: int | None) -> bool:
    settings = get_settings()
    return bool(user_id and settings.telegram_owner_id == user_id)


async def deny(callback: CallbackQuery) -> bool:
    if owner(callback.from_user.id):
        return False
    await callback.answer("Доступ запрещён", show_alert=True)
    return True


def menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [b("3 дня", "access2:create:3"), b("7 дней", "access2:create:7")],
        [b("30 дней", "access2:create:30"), b("90 дней", "access2:create:90")],
        [b("📋 Последние ссылки", "access2:list")],
        [b("⬅️ Главное меню", "home")],
    ])


@router.callback_query(F.data == "access")
async def access(callback: CallbackQuery) -> None:
    if await deny(callback):
        return
    if callback.message:
        await callback.message.edit_text(
            "<b>🔑 Доступ</b>\n\nВыбери срок. Бот создаст одну обычную HTTPS-ссылку. Пользователь нажимает её — приложение открывается и загружает настройки автоматически.",
            reply_markup=menu(),
            parse_mode="HTML",
        )
    await callback.answer()


@router.callback_query(F.data.startswith("access2:create:"))
async def create_link(callback: CallbackQuery) -> None:
    if await deny(callback):
        return
    days = int((callback.data or "").rsplit(":", 1)[1])
    async with SessionLocal() as session:
        activation, token = await create_activation(
            session,
            ActivationCreate(
                duration_days=days,
                max_devices=1,
                max_uses=1,
                link_ttl_hours=72,
                note="",
                created_by=callback.from_user.id,
            ),
        )
    link = public_activation_link(token)
    if callback.message:
        await callback.message.answer(
            "<b>✅ Готово</b>\n\n"
            f"Срок: <b>{days} дней</b>\n"
            "Пользователю нужно только нажать ссылку:\n\n"
            f"{escape(link)}",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [b("❌ Отозвать", f"access2:revoke:{activation.id}")],
                [b("🔑 Создать ещё", "access")],
            ]),
            parse_mode="HTML",
            disable_web_page_preview=True,
        )
    await callback.answer("Ссылка создана")


@router.callback_query(F.data == "access2:list")
async def list_links(callback: CallbackQuery) -> None:
    if await deny(callback):
        return
    async with SessionLocal() as session:
        rows = (
            await session.execute(select(Activation).order_by(Activation.created_at.desc()).limit(20))
        ).scalars().all()
    keyboard: list[list[InlineKeyboardButton]] = []
    for row in rows:
        icon = "❌" if row.revoked_at else ("✅" if row.uses >= row.max_uses else "🆕")
        keyboard.append([b(f"{icon} {row.duration_days} дн. · {str(row.id)[:8]}", f"access2:view:{row.id}")])
    keyboard.append([b("⬅️ Назад", "access")])
    if callback.message:
        await callback.message.edit_text(
            "<b>📋 Последние ссылки</b>",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=keyboard),
            parse_mode="HTML",
        )
    await callback.answer()


@router.callback_query(F.data.startswith("access2:view:"))
async def view_link(callback: CallbackQuery) -> None:
    if await deny(callback):
        return
    activation_id = (callback.data or "").rsplit(":", 1)[1]
    async with SessionLocal() as session:
        row = await session.get(Activation, activation_id)
    if row is None:
        await callback.answer("Ссылка не найдена", show_alert=True)
        return
    status = "отозвана" if row.revoked_at else ("использована" if row.uses >= row.max_uses else "активна")
    text = (
        f"<b>Ссылка {str(row.id)[:8]}</b>\n\n"
        f"Статус: <b>{status}</b>\n"
        f"Срок подписки: <b>{row.duration_days} дней</b>\n"
        f"Использовано: <b>{row.uses}/{row.max_uses}</b>\n"
        f"Истекает: <b>{row.link_expires_at:%d.%m.%Y %H:%M}</b>"
    )
    keyboard = []
    if row.revoked_at is None:
        keyboard.append([b("❌ Отозвать", f"access2:revoke:{row.id}")])
    keyboard.append([b("⬅️ К списку", "access2:list")])
    if callback.message:
        await callback.message.edit_text(text, reply_markup=InlineKeyboardMarkup(inline_keyboard=keyboard), parse_mode="HTML")
    await callback.answer()


@router.callback_query(F.data.startswith("access2:revoke:"))
async def revoke(callback: CallbackQuery) -> None:
    if await deny(callback):
        return
    from datetime import UTC, datetime

    activation_id = (callback.data or "").rsplit(":", 1)[1]
    async with SessionLocal() as session:
        row = await session.get(Activation, activation_id)
        if row is None:
            await callback.answer("Ссылка не найдена", show_alert=True)
            return
        row.revoked_at = datetime.now(UTC)
        await session.commit()
    await callback.answer("Ссылка отозвана", show_alert=True)
    if callback.message:
        await callback.message.edit_reply_markup(reply_markup=InlineKeyboardMarkup(inline_keyboard=[[b("🔑 К доступу", "access")]]))
