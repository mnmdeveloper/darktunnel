#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

CONFIG_PATH = Path(os.getenv("DARKTUNNEL_NODE_CONFIG", "/etc/darktunnel-node/node.json"))
AGENT_VERSION = "0.3.0"
SCHEMA_VERSION = 1


def run(*command: str, timeout: int = 5) -> tuple[int, str]:
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=timeout)
        return result.returncode, (result.stdout or result.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, str(exc)


def systemd_state(unit: str) -> str:
    code, output = run("systemctl", "is-active", unit)
    return output if code == 0 else "inactive"


def interface_names() -> list[str]:
    code, output = run("ip", "-j", "link", "show")
    if code != 0:
        return []
    try:
        return [str(item.get("ifname", "")) for item in json.loads(output) if item.get("ifname")]
    except json.JSONDecodeError:
        return []


def listen_ports() -> set[int]:
    code, output = run("ss", "-H", "-lntu", timeout=5)
    if code != 0:
        return set()
    ports: set[int] = set()
    for match in re.finditer(r":(\d+)\s", output):
        try:
            ports.add(int(match.group(1)))
        except ValueError:
            pass
    return ports


def command_version(path: str | None) -> str:
    if not path:
        return ""
    for args in ((path, "--version"), (path, "version")):
        code, output = run(*args)
        if code == 0 and output:
            return output.splitlines()[0][:128]
    return ""


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def find_first(paths: list[Path]) -> str:
    for path in paths:
        if path.is_file():
            return str(path)
    return ""


def awg_status() -> dict[str, Any]:
    awg = shutil.which("awg")
    awg_quick = shutil.which("awg-quick")
    interfaces = [name for name in interface_names() if name.startswith(("awg", "wg", "amnezia"))]
    metadata = read_json(Path("/etc/darktunnel-node/awg2.json"))
    interface = str(metadata.get("interface") or (interfaces[0] if interfaces else ""))
    port = int(metadata.get("port") or 0)
    public_key = str(metadata.get("public_key") or "")
    peer_count = 0
    latest_handshake = 0
    if awg and interface:
        code, value = run(awg, "show", interface, "listen-port")
        if code == 0 and value.isdigit():
            port = int(value)
        code, value = run(awg, "show", interface, "public-key")
        if code == 0 and value:
            public_key = value.strip()
        code, value = run(awg, "show", interface, "peers")
        if code == 0 and value:
            peer_count = len(value.splitlines())
        code, value = run(awg, "show", interface, "latest-handshakes")
        if code == 0:
            for line in value.splitlines():
                parts = line.split()
                if len(parts) == 2 and parts[1].isdigit():
                    latest_handshake = max(latest_handshake, int(parts[1]))
    service = systemd_state(f"awg-quick@{interface}.service") if interface else "inactive"
    config_path = str(metadata.get("config_path") or "")
    if not config_path:
        config_path = find_first([
            Path("/etc/amnezia/awg/awg0.conf"),
            Path("/etc/amnezia/amneziawg/awg0.conf"),
            Path("/etc/wireguard/awg0.conf"),
            Path("/etc/wireguard/wg0.conf"),
        ])
    detected = bool(awg or awg_quick or interface or metadata or config_path)
    online = detected and bool(interface) and service == "active" and port > 0
    return {
        "detected": detected,
        "online": online,
        "interface": interface,
        "interfaces": interfaces,
        "service": service,
        "port": port,
        "public_key": public_key,
        "peer_count": peer_count,
        "latest_handshake": latest_handshake,
        "address": metadata.get("address", ""),
        "network": metadata.get("network", ""),
        "version": command_version(awg),
        "config_path": config_path,
    }


def parse_env_port(path: Path) -> int:
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            if key.strip() in {"WDTT_PUBLIC_PORT", "WDTT_WG_PORT", "WDTT_PORT", "PORT"}:
                match = re.search(r"\d+", value)
                if match:
                    return int(match.group())
    except OSError:
        pass
    return 0


def wdtt_status() -> dict[str, Any]:
    candidates = [Path("/etc/wdtt/wdtt.env"), Path("/opt/wdtt/wdtt.env")]
    paths = [path for path in candidates if path.exists()]
    service = systemd_state("wdtt.service")
    firewall = systemd_state("wdtt-firewall.service")
    interfaces = interface_names()
    port = next((parse_env_port(path) for path in paths if parse_env_port(path)), 0)
    detected = bool(paths) or service == "active" or "wdtt0" in interfaces
    online = detected and service == "active" and "wdtt0" in interfaces
    return {
        "detected": detected,
        "online": online,
        "service": service,
        "firewall_service": firewall,
        "interface_present": "wdtt0" in interfaces,
        "env_paths": [str(path) for path in paths],
        "port": port or 56000,
    }


def vkturn_status() -> dict[str, Any]:
    process_code, process_output = run("pgrep", "-af", "vk-turn-proxy", timeout=5)
    docker_code, docker_output = (127, "")
    if shutil.which("docker"):
        docker_code, docker_output = run("docker", "ps", "--format", "{{.Names}}\\t{{.Status}}", timeout=5)
    containers: list[str] = []
    if docker_code == 0:
        containers = [line.split("\t", 1)[0] for line in docker_output.splitlines() if line.strip()]
    container = next((name for name in containers if "vkturn" in name.lower() or "vk-turn" in name.lower()), "")
    process = process_code == 0 and bool(process_output)
    listening = 56100 in listen_ports()
    detected = bool(container or process or listening)
    online = detected and (bool(container) or process or listening)
    return {
        "detected": detected,
        "online": online,
        "container": container,
        "process": process,
        "port": 56100,
        "listening": listening,
    }


def snapshot(config: dict[str, Any]) -> dict[str, Any]:
    transports = {
        "amneziawg2": awg_status(),
        "wdtt": wdtt_status(),
        "vkturn": vkturn_status(),
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "node_id": config.get("node_id", ""),
        "name": config.get("name", ""),
        "country": config.get("country", ""),
        "city": config.get("city", ""),
        "public_host": config.get("public_host", ""),
        "agent": {"version": AGENT_VERSION},
        "transports": transports,
        "relations": {
            "vkturn_wraps_wdtt": bool(transports["vkturn"]["online"] and transports["wdtt"]["online"]),
            "amneziawg_present": bool(transports["amneziawg2"]["detected"]),
        },
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "DarkTunnelNode/0.3"

    @property
    def config(self) -> dict[str, Any]:
        return self.server.config  # type: ignore[attr-defined]

    def authorized(self) -> bool:
        expected = str(self.config.get("management_token", ""))
        return bool(expected) and self.headers.get("Authorization", "") == f"Bearer {expected}"

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self.send_json(HTTPStatus.OK, {"status": "ok", "schema_version": SCHEMA_VERSION, "agent_version": AGENT_VERSION})
        elif not self.authorized():
            self.send_json(HTTPStatus.UNAUTHORIZED, {"detail": "unauthorized"})
        elif self.path == "/v1/status":
            self.send_json(HTTPStatus.OK, snapshot(self.config))
        elif self.path == "/v1/transports":
            payload = snapshot(self.config)
            self.send_json(HTTPStatus.OK, {"schema_version": SCHEMA_VERSION, "transports": payload["transports"], "relations": payload["relations"]})
        else:
            self.send_json(HTTPStatus.NOT_FOUND, {"detail": "not found"})

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"Missing configuration: {CONFIG_PATH}")
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    server = ThreadingHTTPServer((str(config.get("listen_host", "127.0.0.1")), int(config.get("listen_port", 8787))), Handler)
    server.config = config  # type: ignore[attr-defined]
    server.serve_forever()


if __name__ == "__main__":
    main()
