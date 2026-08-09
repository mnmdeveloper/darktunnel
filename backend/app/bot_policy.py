from __future__ import annotations

from aiogram import F, Router
from aiogram.types import CallbackQuery

from .config import get_settings
from .db import SessionLocal
from .models import ServerNode

router = Router(name="admin-policy")


async def _block_primary_awg(callback: CallbackQuery) -> bool:
    node_id = callback.data.rsplit(":", 1)[-1]
    async with SessionLocal() as session:
        node = await session.get(ServerNode, node_id)
    if node is None:
        return False
    if node.host != get_settings().wdtt_public_host:
        return False
    await callback.answer("AmneziaWG пока не устанавливаем на основной сервер. VK TURN + WDTT оставляем без изменений.", show_alert=True)
    return True


@router.callback_query(F.data.startswith("server:awg:install:ask:"))
async def block_primary_awg_ask(callback: CallbackQuery) -> None:
    await _block_primary_awg(callback)


@router.callback_query(F.data.startswith("server:awg:install:confirm:"))
async def block_primary_awg_confirm(callback: CallbackQuery) -> None:
    await _block_primary_awg(callback)
