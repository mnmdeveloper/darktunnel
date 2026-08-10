from collections.abc import AsyncIterator

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from .config import get_settings


class Base(DeclarativeBase):
    pass


settings = get_settings()
engine = create_async_engine(settings.database_url, pool_pre_ping=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session


async def init_db() -> None:
    from . import models  # noqa: F401

    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
        # The project historically used create_all without migrations. Keep startup
        # backward-compatible by applying the two additive columns explicitly.
        await connection.execute(text("ALTER TABLE activations ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL"))
        await connection.execute(text("CREATE INDEX IF NOT EXISTS ix_activations_user_id ON activations(user_id)"))
        await connection.execute(text("ALTER TABLE announcements ADD COLUMN IF NOT EXISTS color_hex VARCHAR(9) NOT NULL DEFAULT '#60758F'"))
