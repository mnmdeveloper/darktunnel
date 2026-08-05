#!/usr/bin/env python3
"""DarkTunnel node agent.

The agent is intentionally read-only in the first rollout. It discovers existing
AmneziaWG/WireGuard and WDTT installations without changing their configuration.
It binds to localhost and requires a bearer token for every management request.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

CONFIG_PATH = Path(os.getenv("DARKTUNNEL_NODE_CONFIG", "/etc/darktunnel-node/node.json"))


def run(*command: str, timeout: int = 5) -> tuple[int, str]:
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
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


def awg_status() -> dict[str, Any]:
    commands = {
        "awg": shutil.which("awg"),
        "awg_quick": shutil.which("awg-quick"),
        "wg": shutil.which("wg"),
        "wg_quick": shutil.which("wg-quick"),
    }
    interfaces = [
        name for name in interface_names()
        if name.startswith(("awg", "wg", "amnezia"))
    ]
    services: dict[str, str] = {}
    for interface in interfaces:
        services[f"awg-quick@{interface}.service"] = systemd_state(f"awg-quick@{interface}.service")
        services[f"wg-quick@{interface}.service"] = systemd_state(f"wg-quick@{interface}.service")

    configs = []
    for root in (Path("/etc/amnezia"), Path("/etc/amneziawg"), Path("/etc/wireguard")):
        if root.is_dir():
            configs.extend(str(path) for path in root.glob("*.conf"))

    return {
        "detected": bool(commands["awg"] or commands["awg_quick"] or interfaces or configs),
        "commands": commands,
        "interfaces": interfaces,
        "services": services,
        "config_paths": sorted(configs),
    }


def wdtt_status() -> dict[str, Any]:
    env_candidates = [
        "/etc/wdtt/wdtt.env",
        "/opt/wdtt/wdtt.env",
    ]
    return {
        "detected": any(Path(path).exists() for path in env_candidates)
        or systemd_state("wdtt.service") == "active",
        "service": systemd_state("wdtt.service"),
        "firewall_service": systemd_state("wdtt-firewall.service"),
        "interface_present": "wdtt0" in interface_names(),
        "env_paths": [path for path in env_candidates if Path(path).exists()],
    }


def snapshot(config: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": "ok",
        "node_id": config.get("node_id", ""),
        "name": config.get("name", ""),
        "country": config.get("country", ""),
        "city": config.get("city", ""),
        "public_host": config.get("public_host", ""),
        "transports": {
            "amneziawg2": awg_status(),
            "wdtt": wdtt_status(),
        },
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "DarkTunnelNode/0.1"

    @property
    def config(self) -> dict[str, Any]:
        return self.server.config  # type: ignore[attr-defined]

    def authorized(self) -> bool:
        expected = str(self.config.get("management_token", ""))
        supplied = self.headers.get("Authorization", "")
        return bool(expected) and supplied == f"Bearer {expected}"

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self.send_json(HTTPStatus.OK, {"status": "ok"})
            return
        if not self.authorized():
            self.send_json(HTTPStatus.UNAUTHORIZED, {"detail": "unauthorized"})
            return
        if self.path == "/v1/status":
            self.send_json(HTTPStatus.OK, snapshot(self.config))
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"detail": "not found"})

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"Missing configuration: {CONFIG_PATH}")
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    host = str(config.get("listen_host", "127.0.0.1"))
    port = int(config.get("listen_port", 8787))
    server = ThreadingHTTPServer((host, port), Handler)
    server.config = config  # type: ignore[attr-defined]
    server.serve_forever()


if __name__ == "__main__":
    main()
