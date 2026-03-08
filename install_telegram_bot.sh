#!/usr/bin/env bash
set -euo pipefail

# Installs proxy Telegram bot as a systemd service.
# Usage:
#   sudo bash install_telegram_bot.sh <telegram_bot_token> <allowed_chat_ids_csv> [proxy_script_path]

BOT_TOKEN="${1:-}"
ALLOWED_CHAT_IDS="${2:-}"
PROXY_SCRIPT_PATH="${3:-/home/ubuntu/proxy-king/setup_3proxy.sh}"

if [[ -z "$BOT_TOKEN" || -z "$ALLOWED_CHAT_IDS" ]]; then
  if [[ ! -t 0 ]]; then
    echo "[ERROR] Missing required arguments in non-interactive mode."
    echo "Usage: sudo bash $0 <telegram_bot_token> <allowed_chat_ids_csv> [proxy_script_path]"
    echo "Example: sudo bash $0 123456:ABCDEF 123456789 /home/ubuntu/proxy-king/setup_3proxy.sh"
    exit 1
  fi

  echo "[INFO] Interactive setup for Telegram bot"
  if [[ -z "$BOT_TOKEN" ]]; then
    read -r -p "Enter Telegram bot token: " BOT_TOKEN
  fi
  if [[ -z "$ALLOWED_CHAT_IDS" ]]; then
    read -r -p "Enter allowed chat IDs (comma-separated): " ALLOWED_CHAT_IDS
  fi
  read -r -p "Proxy script path [/home/ubuntu/proxy-king/setup_3proxy.sh]: " input_proxy_path
  if [[ -n "${input_proxy_path:-}" ]]; then
    PROXY_SCRIPT_PATH="$input_proxy_path"
  fi
fi

if [[ -z "$BOT_TOKEN" || -z "$ALLOWED_CHAT_IDS" ]]; then
  echo "[ERROR] BOT token and allowed chat IDs are required."
  exit 1
fi

SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_SOURCE="$SCRIPT_SOURCE_DIR/telegram_bot.sh"
BOT_TARGET="/usr/local/bin/proxy-telegram-bot.sh"
ENV_FILE="/etc/proxy-telegram-bot.env"
SERVICE_FILE="/etc/systemd/system/proxy-telegram-bot.service"

if [[ ! -f "$BOT_SOURCE" ]]; then
  echo "[ERROR] Missing bot script at: $BOT_SOURCE"
  exit 1
fi

echo "[INFO] Installing dependencies..."
apt-get update -y >/dev/null
apt-get install -y curl jq sudo >/dev/null

echo "[INFO] Installing bot script..."
cp "$BOT_SOURCE" "$BOT_TARGET"
chmod 755 "$BOT_TARGET"

echo "[INFO] Writing environment file..."
cat > "$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
ALLOWED_CHAT_IDS=$ALLOWED_CHAT_IDS
PROXY_SCRIPT_PATH=$PROXY_SCRIPT_PATH
BOT_POLL_TIMEOUT=30
EOF
chmod 600 "$ENV_FILE"

echo "[INFO] Writing systemd service..."
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Proxy Telegram Bot Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/proxy-telegram-bot.env
ExecStart=/usr/local/bin/proxy-telegram-bot.sh
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "[INFO] Enabling service..."
systemctl daemon-reload
systemctl enable --now proxy-telegram-bot

sleep 1
if systemctl is-active --quiet proxy-telegram-bot; then
  echo "[DONE] Telegram bot is running."
  echo "[INFO] Service: proxy-telegram-bot"
  echo "[INFO] View logs: journalctl -u proxy-telegram-bot -f --no-pager"
else
  echo "[ERROR] Telegram bot failed to start."
  systemctl --no-pager -l status proxy-telegram-bot || true
  exit 1
fi
