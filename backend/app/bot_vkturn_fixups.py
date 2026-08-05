from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message
from sqlalchemy import select

from .bot_vkturn_v2 import SetLink, b, edit, kb, owner
from .db import SessionLocal
from .models import VkTurnSetting

router = Router(name="vkturn-fixups")

@router.callback_query(F.data == "vk2:set-link")
async def set_start(c: CallbackQuery, state: FSMContext) -> None:
    if not owner(c.from_user.id):
        await c.answer("Доступ запрещён", show_alert=True)
        return
    await state.set_state(SetLink.value)
    await edit(c, "Отправьте полную ссылку VK-звонка.", [[b("❌ Отмена", "vkturn")]])

@router.message(SetLink.value)
async def set_finish(m: Message, state: FSMContext) -> None:
    if not owner(m.from_user.id if m.from_user else None):
        await m.answer("Доступ запрещён.")
        return
    value = (m.text or "").strip()
    if not value.startswith("http") or not ("/call/" in value or "vk.me/join/" in value):
        await m.answer("Это не похоже на ссылку VK-звонка.")
        return
    async with SessionLocal() as s:
        row = await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key == "vk_link"))
        if row is None:
            s.add(VkTurnSetting(key="vk_link", value=value))
        else:
            row.value = value
        await s.commit()
    await state.clear()
    await m.answer("✅ Ссылка сохранена.", reply_markup=kb([[b("📡 VK Turn", "vkturn")]]))
