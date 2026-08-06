# DarkTunnel Server Onboarding v2

## Goal

Adding a VPN server from Telegram must require only a short wizard. The backend
must discover and register all compatible transports automatically without
breaking a working WDTT or AmneziaWG installation.

## Telegram wizard

The administrator supplies:

1. Server display name.
2. Country.
3. City.
4. SSH address (`host` or `host:port`).
5. SSH user.
6. Authentication: password or private key.

The password/private key is kept only for the onboarding job and must not be
stored in the `servers` table or written to audit logs. A future secret-manager
integration may retain an encrypted deployment credential when automatic remote
updates are enabled explicitly.

## Automatic actions

After the administrator confirms the wizard, backend must:

1. Verify the SSH host key and show its fingerprint on first connection.
2. Upload or execute the versioned one-command node installer from this repo.
3. Detect public IPv4/domain automatically when possible.
4. Detect existing AmneziaWG 2.0 and WDTT installations.
5. Leave existing transport configuration and services untouched.
6. Install/update the localhost-only DarkTunnel node agent.
7. Register the server in the backend.
8. Create one transport record for every detected transport.
9. Enable the server and detected transports for auto-selection.
10. Run end-to-end health checks before publishing.
11. Publish only transports that pass health checks.
12. Return a concise report to Telegram.

## One-command node installation

After merge to `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/mnmdeveloper/darktunnel/main/deploy/node-installer/install.sh | sudo bash -s -- install
```

Update without changing or restarting existing VPN transports:

```bash
curl -fsSL https://raw.githubusercontent.com/mnmdeveloper/darktunnel/main/deploy/node-installer/install.sh | sudo bash -s -- update
```

Status:

```bash
sudo bash /opt/darktunnel-node/install.sh status
```

During branch testing, replace `main` with `server-onboarding-v2` or set
`DARKTUNNEL_BRANCH=server-onboarding-v2`.

## Compatibility rule

The installer is additive and idempotent:

- it does not delete or replace `/etc/wdtt`;
- it does not delete or replace AmneziaWG/WireGuard configs;
- it does not restart `wdtt`, `wdtt-firewall`, `awg-quick@*`, or `wg-quick@*`;
- it binds the management API to `127.0.0.1`;
- it generates a unique management token with mode `0600`;
- repeated `install`/`update` runs preserve node identity and token.

## Client delivery contract

Opening a DarkTunnel activation link must be enough for the app. After redeeming
the link, the client downloads:

- subscription/license state;
- published servers;
- all enabled transports for every server;
- per-device AmneziaWG peer configuration;
- per-device WDTT configuration;
- Network Strategy remote configuration;
- health/probe endpoints and minimum compatible versions.

No master WDTT credential, SSH password, SSH private key, or server-side private
key may be returned to the client.

## Planned backend records

`servers` remains the geographic/logical node. Transport-specific data moves to
`server_transports`:

- `server_id`;
- `type`: `amneziawg2` or `wdtt`;
- `enabled`, `published`, `auto_select`;
- `host`, `port`, `mtu`, `dns`;
- encrypted server configuration;
- detected version and compatibility range;
- last health state.

This is introduced with a migration and compatibility adapter so the existing
single `protocol_mode` server rows continue to work until converted.
