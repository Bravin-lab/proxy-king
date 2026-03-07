# Ubuntu VPS Proxy Creator (3proxy)

This project provides a Bash script that installs and configures authenticated proxies on an Ubuntu VPS using `3proxy`.

## Files

- `setup_3proxy.sh`: Main setup script
- `proxy_ui.sh`: Interactive terminal UI (whiptail menu)

## What it does

- Installs `3proxy`, `curl`, and `ufw`
- Generates multiple username/password proxies
- Assigns one proxy per TCP port
- Supports `http` and `socks5`
- Supports optional source IP/CIDR whitelist per proxy user
- Supports credential modes: auto-generate or manual input
- Supports account expiration via `--expire-days` or `--expires-at`
- Supports optional host hardening (`--harden-os`) with IPv6 disable by default
- Uses TCP DNS resolvers in 3proxy config
- Binds outbound traffic to detected public IPv4 when available
- Writes config to `/etc/3proxy/3proxy.cfg`
- Restarts and enables `3proxy`
- Saves generated credentials to:
  - `/root/proxy-users.txt` (`USERNAME:PASSWORD:PORT`)
  - `/root/proxy-list.txt` (`PROTOCOL://USERNAME:PASSWORD@IP:PORT`)

## Usage

Run on your Ubuntu VPS as root:

```bash
sudo bash setup_3proxy.sh <proxy_count> <start_port> [username_prefix] [protocol] [whitelist] [credential_mode] [--expire-days N|--expires-at DATETIME] [--harden-os] [--keep-ipv6]
```

Interactive UI mode:

```bash
sudo bash proxy_ui.sh
```

The UI provides menu-driven actions for create, add, pause/resume, delete, rotate passwords, health check, and port range check.

Management commands:

```bash
sudo bash setup_3proxy.sh --list-active
sudo bash setup_3proxy.sh --list-expired
sudo bash setup_3proxy.sh --reactivate-user <username> [--new-expire-days N|--new-expires-at DATETIME]
sudo bash setup_3proxy.sh --rotate-passwords [--user <username>]
sudo bash setup_3proxy.sh --delete-user <username>
sudo bash setup_3proxy.sh --add-user <port> <username> [password] [--expire-days N|--expires-at DATETIME]
sudo bash setup_3proxy.sh --pause-user <username>
sudo bash setup_3proxy.sh --resume-user <username>
sudo bash setup_3proxy.sh --port-range-check <start_port> <count>
sudo bash setup_3proxy.sh --health-check
```

Example:

```bash
sudo bash setup_3proxy.sh 20 10000 user
```

This creates 20 proxies on ports `10000-10019` with users like `user001`, `user002`, etc.

Create SOCKS5 proxies and only allow one source IP:

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 203.0.113.10
```

Create HTTP proxies and allow a CIDR block:

```bash
sudo bash setup_3proxy.sh 10 12000 corp http 198.51.100.0/24
```

Create proxies and enter username/password manually during setup:

```bash
sudo bash setup_3proxy.sh 5 15000 user http "*" manual
```

Create proxies that expire in 7 days:

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 203.0.113.10 auto --expire-days 7
```

Create proxies that expire at a fixed date/time:

```bash
sudo bash setup_3proxy.sh 20 10000 user http "*" auto --expires-at "2026-03-31 23:59:59"
```

Create proxies with host hardening (disables IPv6):

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 203.0.113.10 auto --expire-days 7 --harden-os
```

Create proxies with hardening but keep IPv6 enabled:

```bash
sudo bash setup_3proxy.sh 20 10000 user socks5 203.0.113.10 auto --harden-os --keep-ipv6
```

Check if a range of ports is available before creating proxies:

```bash
sudo bash setup_3proxy.sh --port-range-check 10000 20
```

Add one user incrementally:

```bash
sudo bash setup_3proxy.sh --add-user 12050 team01
```

Pause, resume, or delete one user:

```bash
sudo bash setup_3proxy.sh --pause-user team01
sudo bash setup_3proxy.sh --resume-user team01
sudo bash setup_3proxy.sh --delete-user team01
```

Rotate passwords safely and regenerate list output:

```bash
sudo bash setup_3proxy.sh --rotate-passwords
sudo bash setup_3proxy.sh --rotate-passwords --user user003
```

Run proxy health checks:

```bash
sudo bash setup_3proxy.sh --health-check
```

## Important notes

- Minimum start port is `1024`.
- `protocol` values: `http` (default) or `socks5`.
- `whitelist` is optional and can be `*` (default), a single IP, CIDR, or comma-separated values.
- `credential_mode` values: `auto` (default) or `manual`.
- In `manual` mode, script prompts for username/password per proxy.
- Use only one expiration option at a time: `--expire-days` or `--expires-at`.
- Expired users are automatically disabled by `3proxy-expiry-check.timer`.
- `--list-active` and `--list-expired` show users from `/etc/3proxy/proxy-db.txt`.
- `--reactivate-user` sets the user status back to active and rebuilds 3proxy config.
- `--pause-user` disables one user without deleting it.
- `--resume-user` is an alias flow for reactivation.
- `--add-user` adds one user/port without recreating all proxies.
- `--delete-user` removes one user cleanly and reloads 3proxy.
- `--rotate-passwords` rotates all users or one selected user and regenerates `/root/proxy-list.txt`.
- `--port-range-check` checks DB conflicts and currently listening ports.
- `--health-check` tests active proxies and shows up/down with latency.
- `--harden-os` applies sysctl network hardening and DNS egress controls.
- `--keep-ipv6` can be used with `--harden-os` if you do not want to disable IPv6.
- For SOCKS, generated URLs use `socks5h://...` so DNS is resolved via proxy.
- If `/etc/3proxy/3proxy.cfg` already exists, a timestamped backup is created.
- If UFW is active, the script automatically opens the proxy port range.
- After running, check service status:

```bash
systemctl status 3proxy --no-pager
```

## Leak-Prevention notes

- The script enforces authenticated users and optional source IP whitelist.
- It applies `-a` anonymous mode for HTTP proxy behavior.
- It sets DNS resolvers with `/tcp` to reduce UDP DNS leakage paths on server-side resolution.
- For SOCKS clients, use the provided `socks5h://` format (not `socks5://`) to avoid client-side DNS leaks.
