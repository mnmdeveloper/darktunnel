import asyncio
from .db import Base, engine

async def run():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    print("OK — все таблицы созданы/обновлены")

if __name__ == "__main__":
    asyncio.run(run())
