from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "DarkTunnel Backend"
    environment: str = "production"
    public_api_url: str = "https://api.example.com"
    database_url: str = "postgresql+asyncpg://darktunnel:darktunnel@db:5432/darktunnel"
    redis_url: str = "redis://redis:6379/0"

    telegram_bot_token: str = Field(default="", repr=False)
    telegram_owner_id: int = 0
    activation_encryption_key: str = Field(default="", repr=False)
    server_config_encryption_key: str = Field(default="", repr=False)

    wdtt_env_path: str = "/host/etc/wdtt/wdtt.env"
    wdtt_vk_call_link: str = Field(default="", repr=False)
    wdtt_public_host: str = "31.77.148.80"
    wdtt_public_port: int = 56000
    wdtt_mode: str = "srtp-wrap-a"
    wdtt_connections_balanced: int = 3
    wdtt_connections_maximum: int = 10
    wdtt_mtu: int = 1280
    wdtt_dns: str = "1.1.1.1"


@lru_cache
def get_settings() -> Settings:
    return Settings()
