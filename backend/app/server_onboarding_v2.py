from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import shlex
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import asyncssh
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .infrastructure_models import OnboardingStatus, ServerOnboardingJob, ServerTransport, TransportType
from .models import AuditLog, ServerHealth, ServerNode
from .server_crypto import encrypt_server_config

INSTALL_URL = "https://raw.githubusercontent.com/mnmdeveloper/darktunnel/{branch}/deploy/node-installer/install.sh"


@dataclass(slots=True)
class SSHCredentials:
    host: str
    port: int
    username: str
    password: str | None = None
    private_key: str | None = None


@dataclass(slots=True)
class ServerDraft:
    name: str
    country: str
    city: str
    admin_id: int


def parse_ssh_address(value: str) -> tuple[str, int]:
    value = value.strip()
    if not value:
        raise ValueError("SSH-адрес не указан")
    if value.startswith("[") and "]:" in value:
        host, port = value[1:].rsplit("]:", 1)
        return host, int(port)
    if value.count(":") == 1:
        host, maybe_port = value.rsplit(":", 1)
        if maybe_port.isdigit():
            return host, int(maybe_port)
    return value, 22


def _fingerprint(key: asyncssh.SSHKey) -> str:
    raw = key.export_public_key("openssh")
    digest = hashlib.sha256(raw).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


async def connect(credentials: SSHCredentials) -> asyncssh.SSHClientConnection:
    return await asyncssh.connect(
        credentials.host,
        port=credentials.port,
        username=credentials.username,
        password=credentials.password,
        client_keys=None,
        known_hosts=None,
        login_timeout=20,
        keepalive_interval=15,
        keepalive_count_max=2,
    )


async def inspect_fingerprint(credentials: SSHCredentials) -> str:
    async with await connect(credentials) as connection:
        return _fingerprint(connection.get_server_host_key())


async def _run(connection: asyncssh.SSHClientConnection, command: str, password: str | None, timeout: int = 240) -> str:
    username = str(connection.get_extra_info("username") or "")
    if username == "root":
        result = await asyncio.wait_for(connection.run(f"bash -lc {shlex.quote(command)}", check=False), timeout=timeout)
    elif password:
        result = await asyncio.wait_for(connection.run(f"sudo -S -p '' bash -lc {shlex.quote(command)}", input=password + "\n", check=False), timeout=timeout)
    else:
        result = await asyncio.wait_for(connection.run(f"sudo -n bash -lc {shlex.quote(command)}", check=False), timeout=timeout)
    if result.exit_status != 0:
        raise RuntimeError((result.stderr or result.stdout or "remote command failed").strip()[-3000:])
    return result.stdout.strip()


async def install_and_discover(credentials: SSHCredentials, draft: ServerDraft, expected_fingerprint: str, branch: str = "server-onboarding-v2") -> dict[str, Any]:
    async with await connect(credentials) as connection:
        if _fingerprint(connection.get_server_host_key()) != expected_fingerprint:
            raise RuntimeError("SSH fingerprint изменился. Установка остановлена")
        env = " ".join([
            f"DARKTUNNEL_BRANCH={shlex.quote(branch)}",
            f"DARKTUNNEL_NODE_NAME={shlex.quote(draft.name)}",
            f"DARKTUNNEL_COUNTRY={shlex.quote(draft.country)}",
            f"DARKTUNNEL_CITY={shlex.quote(draft.city)}",
            "DARKTUNNEL_AWG_PORT=585",
        ])
        await _run(connection, f"curl -fsSL {shlex.quote(INSTALL_URL.format(branch=branch))} | {env} bash -s -- install-all", credentials.password, timeout=1800)
        token = await _run(connection, "python3 -c 'import json; print(json.load(open(\"/etc/darktunnel-node/node.json\"))[\"management_token\"])'", credentials.password)
        status = await _run(connection, f"curl -fsS -H {shlex.quote('Authorization: Bearer ' + token)} http://127.0.0.1:8787/v1/status", credentials.password)
        discovery = json.loads(status)
        discovery["_management_token"] = token
        return discovery


async def register_discovery(session: AsyncSession, draft: ServerDraft, discovery: dict[str, Any], fingerprint: str, job: ServerOnboardingJob) -> ServerNode:
    host = str(discovery.get("public_host") or "")
    if not host:
        raise ValueError("Узел не определил публичный адрес")
    node = await session.scalar(select(ServerNode).where(ServerNode.host == host, ServerNode.archived_at.is_(None)))
    safe_node_config = {"node_id": discovery.get("node_id", ""), "management_token": discovery.get("_management_token", ""), "ssh_host_key_fingerprint": fingerprint, "managed": True}
    if node is None:
        node = ServerNode(name=draft.name, country_name=draft.country, city=draft.city, host=host, port=0, protocol_mode="multi", encrypted_config=encrypt_server_config(safe_node_config), published=False, auto_select=True, maintenance=False)
        session.add(node)
        await session.flush()
    else:
        node.name = draft.name
        node.country_name = draft.country
        node.city = draft.city
        node.protocol_mode = "multi"
        node.auto_select = True
        node.maintenance = False
        node.encrypted_config = encrypt_server_config(safe_node_config)

    transports = discovery.get("transports", {})
    any_online = False
    for transport_type in (TransportType.amneziawg2, TransportType.wdtt):
        info = transports.get(transport_type.value, {}) if isinstance(transports, dict) else {}
        detected = bool(info.get("detected"))
        online = bool(info.get("online", detected))
        row = await session.scalar(select(ServerTransport).where(ServerTransport.server_id == node.id, ServerTransport.transport_type == transport_type))
        if row is None:
            row = ServerTransport(server_id=node.id, transport_type=transport_type)
            session.add(row)
        row.host = host
        row.enabled = detected
        row.auto_select = detected
        row.online = online
        row.published = online
        row.status_detail = json.dumps(info, ensure_ascii=False)[:8000]
        row.last_checked_at = datetime.now(UTC)
        row.port = int(info.get("port") or (56000 if transport_type == TransportType.wdtt else 0))
        row.detected_version = str(info.get("version") or "")[:128]
        any_online = any_online or online

    node.published = any_online
    session.add(ServerHealth(server_id=node.id, online=any_online))
    job.server_id = node.id
    job.status = OnboardingStatus.completed
    job.progress = 100
    job.detail = "Server installed, discovered and registered"
    session.add(AuditLog(admin_id=draft.admin_id, action="server.onboard", entity_type="server", entity_id=str(node.id), result="success"))
    await session.commit()
    return node
