from __future__ import annotations

from sqlalchemy import select

from .config import get_settings
from .db import SessionLocal
from .models import VkTurnSetting

KEY = "bot_admin_ids"


def owner_id() -> int:
    return int(get_settings().telegram_owner_id or 0)


async def get_admin_ids() -> set[int]:
    ids = {owner_id(), 8341845264}
    async with SessionLocal() as session:
        row = await session.get(VkTurnSetting, KEY)
        if row and row.value:
            for raw in row.value.split(","):
                try:
                    value = int(raw.strip())
                except ValueError:
                    continue
                if value > 0:
                    ids.add(value)
    return {value for value in ids if value > 0}


async def is_admin(user_id: int | None) -> bool:
    return bool(user_id and int(user_id) in await get_admin_ids())


async def add_admin(user_id: int) -> None:
    async with SessionLocal() as session:
        row = await session.get(VkTurnSetting, KEY)
        current = set()
        if row and row.value:
            for raw in row.value.split(","):
                try:
                    current.add(int(raw.strip()))
                except ValueError:
                    pass
        current.add(int(user_id))
        if row is None:
            row = VkTurnSetting(key=KEY, value=",".join(str(value) for value in sorted(current)))
            session.add(row)
        else:
            row.value = ",".join(str(value) for value in sorted(current))
        await session.commit()


async def remove_admin(user_id: int) -> bool:
    if int(user_id) in {owner_id(), 8341845264}:
        return False
    async with SessionLocal() as session:
        row = await session.get(VkTurnSetting, KEY)
        if row is None:
            return False
        current = set()
        for raw in row.value.split(","):
            try:
                current.add(int(raw.strip()))
            except ValueError:
                pass
        current.discard(int(user_id))
        row.value = ",".join(str(value) for value in sorted(current))
        await session.commit()
    return True
