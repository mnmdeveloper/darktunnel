import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import Activation, AuditLog, Device, User, UserStatus
from .schemas import ActivationCreate, ActivationRedeem, ActivationResult, ServerProfile
from .security import create_activation_token, decode_activation_token, generate_refresh_token, hash_token


def _read_wdtt_password() -> str:
    settings = get_settings()
    path = Path(settings.wdtt_env_path)
    if not path.is_file():
        raise ValueError("WDTT configuration is unavailable")
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() == "WDTT_PASSWORD":
            secret = value.strip().strip('"').strip("'")
            if secret:
                return secret
    raise ValueError("WDTT password is not configured")


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
    session.add(AuditLog(admin_id=data.created_by, action="activation.create", entity_type="activation", entity_id=str(activation.id)))
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

    existing_device = await session.scalar(
        select(Device)
        .where(Device.installation_id == data.installation_id)
        .with_for_update()
    )

    if existing_device is not None:
        user = await session.get(User, existing_device.user_id)
        if user is None:
            raise ValueError("Subscription owner unavailable")

        # A fresh activation link issued by the administrator is an explicit
        # authorization to restore this installation. It defines a new exact
        # subscription term; it must not inherit an old test/expired term and
        # accidentally turn a 3-day activation into a multi-year subscription.
        fresh_activation = activation.user_id is None
        if not fresh_activation and activation.user_id != user.id:
            raise ValueError("Device already belongs to another subscription")

        if not fresh_activation:
            if user.status == UserStatus.blocked:
                raise ValueError("Subscription blocked")
            if not user.lifetime and (user.subscription_expires_at is None or user.subscription_expires_at <= now):
                raise ValueError("Subscription expired")

            existing_device.public_key = data.public_key
            existing_device.app_version = data.app_version
            existing_device.ios_version = data.ios_version
            existing_device.last_seen_at = now
            refresh_token = _issue_device_token(existing_device)
            await session.commit()
            return _result(user, existing_device, refresh_token)

        # A brand-new admin activation replaces the old subscription term with
        # exactly the number of days specified by that activation. Renewals of
        # an already-bound activation are handled by the normal subscription
        # lifecycle and are never allowed to revive a blocked/expired user.
        user.status = UserStatus.active
        user.lifetime = False
        user.subscription_expires_at = now + timedelta(days=activation.duration_days)
        user.activated_at = user.activated_at or now
        activation.user_id = user.id
        activation.uses = max(activation.uses, 0) + 1
        session.add(AuditLog(admin_id=activation.created_by, action="activation.redeem.restore", entity_type="activation", entity_id=str(activation.id)))

        existing_device.public_key = data.public_key
        existing_device.app_version = data.app_version
        existing_device.ios_version = data.ios_version
        existing_device.revoked_at = None
        existing_device.last_seen_at = now
        refresh_token = _issue_device_token(existing_device)
        await session.commit()
        return _result(user, existing_device, refresh_token)

    # One activation creates ONE subscription/user. Additional allowed devices
    # are attached to that same user instead of creating another full subscription.
    user: User | None = None
    if activation.user_id is not None:
        user = await session.get(User, activation.user_id)
        if user is None:
            raise ValueError("Activation owner unavailable")
        if user.status == UserStatus.blocked:
            raise ValueError("Subscription blocked")
        if not user.lifetime and (user.subscription_expires_at is None or user.subscription_expires_at <= now):
            raise ValueError("Subscription expired")
    else:
        user = User(
            telegram_id=activation.telegram_id,
            note=activation.note,
            activated_at=now,
            subscription_expires_at=now + timedelta(days=activation.duration_days),
        )
        session.add(user)
        await session.flush()
        activation.user_id = user.id

    if activation.uses >= activation.max_uses:
        raise ValueError("Activation use limit reached")

    device_count = await session.scalar(
        select(func.count(Device.id)).where(Device.user_id == user.id, Device.revoked_at.is_(None))
    )
    if int(device_count or 0) >= activation.max_devices:
        raise ValueError("Device limit reached")

    device = Device(
        user_id=user.id,
        installation_id=data.installation_id,
        public_key=data.public_key,
        app_version=data.app_version,
        ios_version=data.ios_version,
        last_seen_at=now,
    )
    session.add(device)
    activation.uses = max(activation.uses, 0) + 1
    refresh_token = _issue_device_token(device)
    await session.commit()
    await session.refresh(user)
    await session.refresh(device)
    return _result(user, device, refresh_token)


def _issue_device_token(device: Device) -> str:
    token = generate_refresh_token()
    device.auth_token_hash = hash_token(token)
    return token


def _result(user: User, device: Device, refresh_token: str) -> ActivationResult:
    settings = get_settings()
    return ActivationResult(
        user_id=str(user.id),
        device_id=str(device.id),
        subscription_expires_at=user.subscription_expires_at,
        lifetime=user.lifetime,
        user_status=user.status.value,
        refresh_token=refresh_token,
        server=ServerProfile(
            host=settings.wdtt_public_host,
            port=settings.wdtt_public_port,
            mode=settings.wdtt_mode,
            wrap_a_password=_read_wdtt_password(),
            connections_balanced=settings.wdtt_connections_balanced,
            connections_maximum=settings.wdtt_connections_maximum,
            mtu=settings.wdtt_mtu,
            dns=settings.wdtt_dns,
        ),
    )
