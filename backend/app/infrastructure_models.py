from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, Enum, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base


class TransportType(str, enum.Enum):
    amneziawg2 = "amneziawg2"
    wdtt = "wdtt"


class OnboardingStatus(str, enum.Enum):
    pending = "pending"
    connecting = "connecting"
    installing = "installing"
    discovering = "discovering"
    completed = "completed"
    failed = "failed"


class ServerTransport(Base):
    __tablename__ = "server_transports"
    __table_args__ = (UniqueConstraint("server_id", "transport_type", name="uq_server_transport_type"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    server_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("servers.id", ondelete="CASCADE"), index=True)
    transport_type: Mapped[TransportType] = mapped_column(Enum(TransportType))
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    published: Mapped[bool] = mapped_column(Boolean, default=False)
    auto_select: Mapped[bool] = mapped_column(Boolean, default=True)
    host: Mapped[str] = mapped_column(String(253), default="")
    port: Mapped[int] = mapped_column(Integer, default=0)
    mtu: Mapped[int] = mapped_column(Integer, default=1280)
    dns: Mapped[str] = mapped_column(String(128), default="1.1.1.1")
    encrypted_config: Mapped[str] = mapped_column(Text, default="")
    detected_version: Mapped[str] = mapped_column(String(128), default="")
    online: Mapped[bool] = mapped_column(Boolean, default=False)
    status_detail: Mapped[str] = mapped_column(Text, default="")
    last_checked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class ServerOnboardingJob(Base):
    __tablename__ = "server_onboarding_jobs"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    admin_id: Mapped[int] = mapped_column(BigInteger, index=True)
    name: Mapped[str] = mapped_column(String(128))
    country: Mapped[str] = mapped_column(String(128))
    city: Mapped[str] = mapped_column(String(128))
    ssh_host: Mapped[str] = mapped_column(String(253))
    ssh_port: Mapped[int] = mapped_column(Integer, default=22)
    ssh_user: Mapped[str] = mapped_column(String(128))
    host_key_fingerprint: Mapped[str] = mapped_column(String(256), default="")
    status: Mapped[OnboardingStatus] = mapped_column(Enum(OnboardingStatus), default=OnboardingStatus.pending)
    progress: Mapped[int] = mapped_column(Integer, default=0)
    detail: Mapped[str] = mapped_column(Text, default="")
    server_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("servers.id", ondelete="SET NULL"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class DevicePeer(Base):
    __tablename__ = "device_peers"
    __table_args__ = (UniqueConstraint("device_id", "transport_id", name="uq_device_transport_peer"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    device_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("devices.id", ondelete="CASCADE"), index=True)
    transport_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("server_transports.id", ondelete="CASCADE"), index=True)
    public_key: Mapped[str] = mapped_column(Text)
    assigned_ip: Mapped[str] = mapped_column(String(64))
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    encrypted_client_config: Mapped[str] = mapped_column(Text, default="")
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
