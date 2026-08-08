import asyncio
import hashlib
import ipaddress
import secrets
from dataclasses import dataclass

import asyncssh


@dataclass(slots=True)
class ServerProbeResult:
    host: str
    ssh_port: int
    username: str
    host_key_sha256: str
    hostname: str
    os_release: str
    architecture: str
    has_systemd: bool
    has_curl: bool
    has_wdtt: bool


@dataclass(slots=True)
class ServerInstallResult:
    host: str
    public_port: int
    service_active: bool
    interface_ready: bool
    udp_listening: bool
    generated_secret: str
    output: str


def validate_host(value: str) -> str:
    value = value.strip()
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        if not value or len(value) > 253 or any(part == "" for part in value.split(".")):
            raise ValueError("Некорректный IP или hostname")
        allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        if any(ch not in allowed for ch in value):
            raise ValueError("Некорректный IP или hostname")
        return value.lower()


async def probe_server(*, host: str, port: int, username: str, password: str) -> ServerProbeResult:
    host = validate_host(host)
    if not 1 <= port <= 65535:
        raise ValueError("Некорректный SSH-порт")
    if not username or len(username) > 64:
        raise ValueError("Некорректное имя пользователя")
    if not password:
        raise ValueError("SSH-пароль пуст")

    async with asyncssh.connect(
        host,
        port=port,
        username=username,
        password=password,
        known_hosts=None,
        login_timeout=20,
        keepalive_interval=10,
    ) as connection:
        key = connection.get_server_host_key().export_public_key("openssh")
        fingerprint = hashlib.sha256(key).hexdigest()
        command = r'''set -eu
printf 'HOSTNAME='; hostname
printf 'OS='; . /etc/os-release 2>/dev/null && printf '%s %s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" || echo unknown
printf 'ARCH='; uname -m
printf 'SYSTEMD='; command -v systemctl >/dev/null && echo 1 || echo 0
printf 'CURL='; command -v curl >/dev/null && echo 1 || echo 0
printf 'WDTT='; systemctl is-active wdtt >/dev/null 2>&1 && echo 1 || echo 0
'''
        result = await asyncio.wait_for(connection.run(command, check=True), timeout=30)

    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key_name, value = line.split("=", 1)
            values[key_name] = value.strip()

    return ServerProbeResult(
        host=host,
        ssh_port=port,
        username=username,
        host_key_sha256=fingerprint,
        hostname=values.get("HOSTNAME", "unknown"),
        os_release=values.get("OS", "unknown"),
        architecture=values.get("ARCH", "unknown"),
        has_systemd=values.get("SYSTEMD") == "1",
        has_curl=values.get("CURL") == "1",
        has_wdtt=values.get("WDTT") == "1",
    )


async def install_wdtt_node(
    *,
    host: str,
    port: int,
    username: str,
    password: str,
    expected_host_key_sha256: str,
    public_host: str,
    public_port: int = 56000,
) -> ServerInstallResult:
    host = validate_host(host)
    public_host = validate_host(public_host)
    if not 1 <= public_port <= 65535:
        raise ValueError("Некорректный публичный порт")

    generated_secret = secrets.token_urlsafe(36)

    async with asyncssh.connect(
        host,
        port=port,
        username=username,
        password=password,
        known_hosts=None,
        login_timeout=20,
        keepalive_interval=10,
    ) as connection:
        actual_key = connection.get_server_host_key().export_public_key("openssh")
        actual_fingerprint = hashlib.sha256(actual_key).hexdigest()
        if not secrets.compare_digest(actual_fingerprint, expected_host_key_sha256):
            raise RuntimeError("SSH host key изменился. Установка отменена")

        # Password is passed only to this process over the encrypted SSH channel.
        # It is never persisted by the control plane or returned in bot messages.
        command = r'''set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo -n true 2>/dev/null || true
RUN=""
if [ "$(id -u)" -ne 0 ]; then RUN="sudo"; fi
$RUN apt-get update
$RUN apt-get install -y curl ca-certificates openssl
TMP=$(mktemp)
curl -fsSL -o "$TMP" https://raw.githubusercontent.com/XXcipherX/vkturn-vps-setup/main/install.sh
chmod 700 "$TMP"
$RUN "$TMP" install --password "$DT_SECRET" --host "$DT_PUBLIC_HOST"
rm -f "$TMP"
$RUN systemctl is-active --quiet wdtt
$RUN ip link show wdtt0 >/dev/null
$RUN ss -lun | grep -q ":$DT_PUBLIC_PORT "
printf 'SERVICE=1\nINTERFACE=1\nUDP=1\n'
'''
        result = await asyncio.wait_for(
            connection.run(
                command,
                check=True,
                env={
                    "DT_SECRET": generated_secret,
                    "DT_PUBLIC_HOST": public_host,
                    "DT_PUBLIC_PORT": str(public_port),
                },
            ),
            timeout=900,
        )

    values = {line.split("=", 1)[0]: line.split("=", 1)[1] for line in result.stdout.splitlines() if "=" in line}
    return ServerInstallResult(
        host=public_host,
        public_port=public_port,
        service_active=values.get("SERVICE") == "1",
        interface_ready=values.get("INTERFACE") == "1",
        udp_listening=values.get("UDP") == "1",
        generated_secret=generated_secret,
        output=result.stdout[-4000:],
    )

