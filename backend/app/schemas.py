from datetime import datetime

from pydantic import BaseModel, Field


class ActivationCreate(BaseModel):
    duration_days: int = Field(ge=1, le=3650)
    max_devices: int = Field(default=1, ge=1, le=20)
    max_uses: int = Field(default=1, ge=1, le=20)
    link_ttl_hours: int = Field(default=72, ge=1, le=24 * 365)
    note: str = Field(default="", max_length=500)
    telegram_id: int | None = None
    created_by: int


class ActivationCreated(BaseModel):
    activation_id: str
    activation_link: str
    link_expires_at: datetime


class ActivationRedeem(BaseModel):
    token: str
    installation_id: str = Field(min_length=8, max_length=128)
    public_key: str = Field(min_length=16, max_length=4096)
    app_version: str = Field(default="", max_length=64)
    ios_version: str = Field(default="", max_length=64)


class ServerProfile(BaseModel):
    host: str
    port: int
    mode: str
    wrap_a_password: str
    connections_balanced: int
    connections_maximum: int
    mtu: int
    dns: str


class ActivationResult(BaseModel):
    user_id: str
    device_id: str
    subscription_expires_at: datetime | None
    lifetime: bool
    user_status: str
    refresh_token: str
    server: ServerProfile


class SubscriptionStatus(BaseModel):
    user_id: str
    device_id: str
    status: str
    active: bool
    lifetime: bool
    subscription_expires_at: datetime | None
    checked_at: datetime


class AnnouncementCreate(BaseModel):
    title: str = Field(min_length=1, max_length=160)
    body: str = Field(min_length=1, max_length=4000)
    placement: str = Field(pattern="^(home|server)$")
    color_hex: str = Field(default="#60758F", pattern=r"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")


class AnnouncementPatch(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=160)
    body: str | None = Field(default=None, min_length=1, max_length=4000)
    placement: str | None = Field(default=None, pattern="^(home|server)$")
    color_hex: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")
    active: bool | None = None
