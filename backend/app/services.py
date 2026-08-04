import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import Activation, AuditLog, Device, User, UserStatus
from .schemas import ActivationCreate, ActivationRedeem, ActivationResult, ServerProfile
from .security import create_activation_token, decode_activation_token, generate_refresh_token, hash_token


async def create_activation(session: AsyncSession, data: ActivationCreate) -> tuple[Activation, str]:
    expires_at = datetime.now(UTC) + timedelta(hours=data.link_ttl_hours)
    activation = Activation(
        token_hash="pending",
        duration_days=data.duration_days,
        max_devices=data.max_devices,
        max_uses=data.max_uses,
        link_expires_at=expires_at,
        note=data.note,
        telegram_id=data.telegram_id,
        created_by=data.created_by,
    )
    session.add(activation)
    await session.flush()

    token = create_activation_token(str(activation.id), expires_at)
    activation.token_hash = hash_token(token)
    session.add(
        AuditLog(
            admin_id=data.created_by,
            action="activation.create",
            entity_type="activation",
            entity_id=str(activation.id),
        )
    )
    await session.commit()
    await session.refresh(activation)
    return activation, token


async def redeem_activation(session: AsyncSession, data: ActivationRedeem) -> ActivationResult:
    payload = decode_activation_token(data.token)
    activation_id = uuid.UUID(str(payload["activation_id"]))
    activation = await session.scalar(select(Activation).where(Activation.id == activation_id).with_for_update())
    if activation is None or activation.token_hash != hash_token(data.token):
        raise ValueError("Activation link not found")
    now = datetime.now(UTC)
    if activation.revoked_at is not None or activation.link_expires_at < now:
        raise ValueError("Activation link unavailable")
    if activation.uses >= activation.max_uses:
        raise ValueError("Activation usage limit reached")

    existing_device = await session.scalar(select(Device).where(Device.installation_id == data.installation_id))
    if existing_device is not None:
        user = await session.get(User, existing_device.user_id)
        if user is None or user.status == UserStatus.blocked:
            raise ValueError("User unavailable")
        return _result(user, existing_device)

    user = User(
        telegram_id=activation.telegram_id,
        note=activation.note,
        activated_at=now,
        subscription_expires_at=now + timedelta(days=activation.duration_days),
    )
    session.add(user)
    await session.flush()

    device_count = await session.scalar(select(func.count(Device.id)).where(Device.user_id == user.id))
    if int(device_count or 0) >= activation.max_devices:
        raise ValueError("Device limit reached")

    device = Device(
        user_id=user.id,
        installation_id=data.installation_id,
        public_key=data.public_key,
        app_version=data.app_version,
        ios_version=data.ios_version,
    )
    session.add(device)
    activation.uses += 1
    await session.commit()
    await session.refresh(user)
    await session.refresh(device)
    return _result(user, device)


def _result(user: User, device: Device) -> ActivationResult:
    settings = get_settings()
    if user.subscription_expires_at is None:
        raise ValueError("Subscription missing")
    return ActivationResult(
        user_id=str(user.id),
        device_id=str(device.id),
        subscription_expires_at=user.subscription_expires_at,
        refresh_token=generate_refresh_token(),
        server=ServerProfile(
            host=settings.wdtt_public_host,
            port=settings.wdtt_public_port,
            mode=settings.wdtt_mode,
            connections_balanced=settings.wdtt_connections_balanced,
            connections_maximum=settings.wdtt_connections_maximum,
            mtu=settings.wdtt_mtu,
            dns=settings.wdtt_dns,
        ),
    )
