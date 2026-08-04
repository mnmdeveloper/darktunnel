# DarkTunnel backend and Telegram admin bot

## Install on the VPS

Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/mnmdeveloper/darktunnel/backend-bot-mvp/install-backend.sh | sudo bash
```

The installer asks for the Telegram bot token, the numeric Telegram owner ID, and the public API URL. It generates database and activation-encryption secrets locally, writes them with mode `0600`, mounts `/etc/wdtt` read-only, builds the containers, starts PostgreSQL, Redis, API and bot, and checks `/health`.

The existing WDTT service is not stopped or reinstalled.

## Local status

```bash
cd /opt/darktunnel
sudo docker compose --env-file .env -f docker-compose.backend.yml ps
curl -fsS http://127.0.0.1:8000/health
```

## Logs

```bash
cd /opt/darktunnel
sudo docker compose --env-file .env -f docker-compose.backend.yml logs -f --tail=200 api bot
```
