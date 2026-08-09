# DarkTunnel Server Onboarding v2

## Goal

Adding a VPN server from Telegram must require only a short wizard. DarkTunnel
must discover and register the VPN transports that already exist on the VPS.
It must not install, configure, replace, or restart the VPN stack.

Supported existing transports are:

- AmneziaWG 2.0;
- WDTT;
- VK Turn proxy.

DarkTunnel is the control plane/catalog. The VPS remains the owner of its VPN
configuration and runtime.

## Telegram wizard

The administrator supplies:

1. Server display name.
2. Country.
3. City.
4. SSH address (`host` or `host:port`).
5. SSH user.
6. Authentication: password or private key.

The password/private key is kept only for the onboarding job and must not be
stored in the `servers` table or written to audit logs.

## Automatic actions

After the administrator confirms the wizard, backend must:

1. Verify the SSH host key and show its fingerprint on first connection.
2. Install/update only the localhost-only DarkTunnel node agent.
3. Detect existing AmneziaWG, WDTT and VK Turn installations.
4. Read runtime state without modifying their configuration.
5. Register the server in the backend.
6. Create one transport record for every detected transport.
7. Publish only transports that pass the available health checks.
8. Return a concise discovery report to Telegram.

The onboarding process must not install or update AmneziaWG, WDTT or VK Turn.
It must not restart `wdtt`, `wdtt-firewall`, `awg-quick@*`, `wg-quick@*`, or a
VK Turn container/process.

## One-command node installation

After merge to `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/mnmdeveloper/darktunnel/main/deploy/node-installer/install.sh | sudo bash -s -- install
```

Update the read-only agent without changing VPN transports:

```bash
curl -fsSL https://raw.githubusercontent.com/mnmdeveloper/darktunnel/main/deploy/node-installer/install.sh | sudo bash -s -- update
```

Status:

```bash
sudo bash /opt/darktunnel-node/install.sh status
```

During branch testing, replace `main` with `server-profile-safe`.

## Node agent contract

The agent listens only on `127.0.0.1:8787` and exposes read-only endpoints:

- `GET /health` — agent health;
- `GET /v1/status` — node identity plus transport discovery;
- `GET /v1/transports` — transport discovery only.

Every response has `schema_version`. Current schema version is `1`.

The agent reports, where available:

- detection state;
- runtime/service state;
- interface;
- listening port;
- public key;
- peer count and latest handshake for AmneziaWG;
- WDTT service/firewall/interface state;
- VK Turn process/container/listening-port state.

The agent never returns private keys, SSH credentials, WDTT master password,
or VPN private configuration.

## Compatibility rule

The installer is additive and idempotent:

- it does not delete or replace `/etc/wdtt`;
- it does not delete or replace AmneziaWG/WireGuard configs;
- it does not install or replace VPN binaries;
- it does not restart existing VPN transports;
- it binds the management API to `127.0.0.1`;
- it generates a unique management token with mode `0600`;
- repeated `install`/`update` runs preserve node identity and token.

## Backend records

`servers` remains the geographic/logical node. Transport-specific data is
represented by `server_transports`:

- `server_id`;
- `type`: `amneziawg2`, `wdtt`, or `vkturn`;
- `enabled`, `published`, `auto_select`;
- `host`, `port`, `mtu`, `dns`;
- encrypted transport configuration only where the existing client contract
  requires it;
- detected version;
- last health state.

The existing `ServerNode.protocol_mode` and legacy configuration remain for
compatibility. They are not removed in this phase.

## Critical safety rule

A successful DarkTunnel onboarding must leave a working VPS working exactly as
it was before onboarding. If discovery fails, the correct action is to report
failure — not to attempt to repair the VPN automatically.
