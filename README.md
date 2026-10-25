# Ubuntu VPS Proxy Creator (3proxy)

Provision and manage authenticated HTTP/SOCKS5 proxies on Ubuntu VPS with one script.

## Overview

This project is designed for operators who want a practical proxy lifecycle workflow on a server:

- Create proxies in bulk
- Add additional proxy batches without deleting existing accounts
- Add, pause, resume, delete, and rotate users
- Enforce optional source IP allowlists
- Set account expiry and auto-disable expired users
- Run port and health checks
- Apply optional OS/network hardening

## Files

- `setup_3proxy.sh`: main provisioning and management CLI
- `proxy_ui.sh`: terminal menu-driven CLI loop for VPS usage
- `telegram_bot.sh`: Telegram bot runner (long polling)
- `install_telegram_bot.sh`: installer for Telegram bot systemd service

## Installation (Fresh Ubuntu VPS)

Follow these steps in order on a new server.

1. Point domain DNS to your VPS (recommended before proxy creation).

- Create an `A` record for your proxy host (example: `proxy.example.com`) to your VPS public IPv4.
- If using Cloudflare for standard proxy ports, keep the record as **DNS only** (not proxied/orange-cloud).

2. Prepare the server and clone project.

```bash
sudo apt update
sudo apt install -y git build-essential openssl libssl-dev
git clone https://github.com/Bravin-lab/proxy-king
cd proxy-king
chmod +x setup_3proxy.sh proxy_ui.sh
```

3. (Optional) Verify intended port range is free.

```bash
sudo bash setup_3proxy.sh --port-range-check 10000 20
```

4. Create first proxy batch.

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 "*" auto --host proxy.example.com --harden-os
```

5. Install and use interactive menu command.

```bash
sudo bash setup_3proxy.sh --install-menu
menu
```

`menu` is installed to `/usr/local/bin/menu` and can be run from any directory.
It opens a loop-style terminal menu (numbered options) without `whiptail`.

6. Verify service and security status.

```bash
sudo systemctl status 3proxy --no-pager
sudo systemctl status 3proxy-expiry-check.timer --no-pager
sudo bash setup_3proxy.sh --health-check
sudo bash setup_3proxy.sh --security-audit
```

## Telegram Bot Control

Install Telegram control bot on VPS (replace values):

```bash
chmod +x telegram_bot.sh install_telegram_bot.sh
sudo bash install_telegram_bot.sh <BOT_TOKEN> <ALLOWED_CHAT_ID_CSV> /home/ubuntu/proxy-king/setup_3proxy.sh
```

Interactive mode (prompts for missing values):

```bash
sudo bash install_telegram_bot.sh
```

Find your Telegram chat ID:

1. Start a chat with your bot and send `/start`
2. Open `https://api.telegram.org/bot<BOT_TOKEN>/getUpdates`
3. Use the numeric `chat.id` as allowed ID

Service management:

```bash
sudo systemctl status proxy-telegram-bot --no-pager
sudo journalctl -u proxy-telegram-bot -f --no-pager
```

Available Telegram commands:

- `/help`
- `/status`
- `/health`
- `/list_active`
- `/list_expired`
- `/restart_3proxy`
- `/add_user <port> <username> [password] [protocol] [max_client_ips] [action]`
- `/pause_user <username>`
- `/resume_user <username>`
- `/rotate_passwords [username]`

## AWS Security Group Configuration

Configure these rules in your AWS EC2 security group **before** creating proxies.

### Inbound Rules

| Type | Protocol | Port Range | Source | Purpose |
|------|----------|-----------|--------|---------|
| SSH | TCP | 22 | Your IP or 0.0.0.0/0 | VPS administration |
| Custom TCP | TCP | `10000-10019` | Client IPs or 0.0.0.0/0 | Proxy access (adjust per your setup) |

### Outbound Rules

| Type | Protocol | Port Range | Destination | Purpose |
|------|----------|-----------|-------------|---------|
| All traffic | All | All | 0.0.0.0/0 | Allow proxies to connect to clients/destinations |

**Note:** Replace port range `10000-10019` with your actual proxy port range. Example: if creating 50 proxies on ports `20000-20049`, open TCP `20000:20049`.

## End-to-End VPS Setup

Use this exact flow on a fresh Ubuntu VPS.

1. Clone repository and set executable permissions.

```bash
git clone https://github.com/Bravin-lab/proxy-king
cd proxy-king
chmod +x setup_3proxy.sh proxy_ui.sh
```

2. Check target port range before creation.

```bash
sudo bash setup_3proxy.sh --port-range-check 10000 20
```

3. Create your first proxy batch.

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 "*" auto --harden-os
```

4. Verify services are running.

```bash
systemctl status 3proxy --no-pager
systemctl status 3proxy-expiry-check.timer --no-pager
```

5. Validate proxy health.

```bash
sudo bash setup_3proxy.sh --health-check
```

6. Use routine operations as needed.

```bash
# Rotate all passwords
sudo bash setup_3proxy.sh --rotate-passwords

# Add one user
sudo bash setup_3proxy.sh --add-user 12050 team01

# Pause/resume a user
sudo bash setup_3proxy.sh --pause-user team01
sudo bash setup_3proxy.sh --resume-user team01
```

## Main Create Command

```bash
sudo bash setup_3proxy.sh <proxy_count> <start_port> [username_prefix] [protocol] [whitelist] [credential_mode] [--expire-days N|--expires-at DATETIME] [--max-client-ips N] [--max-client-ips-action delete|pause] [--host DOMAIN_OR_IP] [--harden-os] [--keep-ipv6]
```

Parameters:

- `<proxy_count>`: number of proxies to create
- `<start_port>`: first port in range, minimum `1024`
- `[username_prefix]`: default `user`
- `[protocol]`: `http` (default) or `socks5`
- `[whitelist]`: source IP/CIDR or comma-separated list, default `*`
- `[credential_mode]`: `auto` (default) or `manual`
- `--max-client-ips N`: enforce unique connected client IP limit per account (`0` disables)
- `--max-client-ips-action delete|pause`: action on limit breach (default `delete`)
- `--host DOMAIN_OR_IP`: host used in exported proxy URLs (for example, `proxy.example.com`)

## Management Commands

```bash
sudo bash setup_3proxy.sh --list-active
sudo bash setup_3proxy.sh --list-expired
sudo bash setup_3proxy.sh --add-user <port> <username> [password] [--protocol http|socks5] [--max-client-ips N] [--max-client-ips-action delete|pause] [--expire-days N|--expires-at DATETIME]
sudo bash setup_3proxy.sh --pause-user <username>
sudo bash setup_3proxy.sh --resume-user <username>
sudo bash setup_3proxy.sh --reactivate-user <username> [--new-expire-days N|--new-expires-at DATETIME]
sudo bash setup_3proxy.sh --delete-user <username>
sudo bash setup_3proxy.sh --rotate-passwords [--user <username>]
sudo bash setup_3proxy.sh --port-range-check <start_port> <count>
sudo bash setup_3proxy.sh --health-check
sudo bash setup_3proxy.sh --list-alive
sudo bash setup_3proxy.sh --set-host <domain_or_ip>
sudo bash setup_3proxy.sh --harden-now [--keep-ipv6]
sudo bash setup_3proxy.sh --security-audit
```

Set or change the exported proxy host later:

```bash
sudo bash setup_3proxy.sh --set-host proxy.example.com
```

## Common Examples

Create HTTP proxies and allow only one source IP:

```bash
sudo bash setup_3proxy.sh 20 10000 user http 203.0.113.10
```

Create proxies with manual username/password input:

```bash
sudo bash setup_3proxy.sh 5 15000 user socks5 "*" manual
```

Create proxies that expire in 7 days:

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 "*" auto --expire-days 7
```

Create proxies with hardening enabled:

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 "*" auto --harden-os
```

Check a target range before deployment:

```bash
sudo bash setup_3proxy.sh --port-range-check 10000 20
```

Rotate all passwords:

```bash
sudo bash setup_3proxy.sh --rotate-passwords
```

## Outputs and Runtime Files

- `/etc/3proxy/3proxy.cfg`: generated runtime config
- `/etc/3proxy/proxy-db.txt`: managed user database (source of truth)
- `/etc/3proxy/proxy-settings.env`: managed runtime settings
- `/root/proxy-users.txt`: `USERNAME:PASSWORD:PORT` (active users)
- `/root/proxy-list.txt`: `SCHEME://USERNAME:PASSWORD@IP:PORT` (active users)

Expiry automation:

- `/usr/local/bin/3proxy-expiry-check.sh`
- `3proxy-expiry-check.service`
- `3proxy-expiry-check.timer`

## Security Notes

- No proxy is fully "undetectable". This project focuses on reducing leaks and exposure.
- For SOCKS, generated URLs use `socks5h://` to route DNS resolution through proxy.
- DNS resolvers are configured with `/tcp` to reduce DNS leak paths.
- Optional `--harden-os` applies sysctl network hardening and DNS egress controls.
- `--harden-now` can apply hardening to an already installed server without recreating proxies.
- `--security-audit` prints pass/fail checks for firewall, services, DNS mode, timer status, and files.
- `--keep-ipv6` keeps IPv6 enabled when hardening is enabled.
- If UFW is active, proxy port range is opened automatically during creation.

## Requirements

- Ubuntu VPS with root/sudo access
- Internet access to install packages
- `systemd` available (for service and expiry timer)

The script installs required packages automatically (`3proxy`, `curl`, `ufw`, `openssl`).

## Service Checks

```bash
systemctl status 3proxy --no-pager
systemctl status 3proxy-expiry-check.timer --no-pager
```

## Disclaimer

Use only where you are authorized to operate proxies and comply with your provider policy, local law, and target service terms.
