#!/usr/bin/env bash
set -euo pipefail

# Telegram bot controller for setup_3proxy.sh
# Required env vars:
#   TELEGRAM_BOT_TOKEN
#   ALLOWED_CHAT_IDS (comma-separated numeric chat IDs)
# Optional env vars:
#   PROXY_SCRIPT_PATH (default: /home/ubuntu/proxy-king/setup_3proxy.sh)
#   BOT_POLL_TIMEOUT (default: 30)

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${ALLOWED_CHAT_IDS:?ALLOWED_CHAT_IDS is required}"

PROXY_SCRIPT_PATH="${PROXY_SCRIPT_PATH:-/home/ubuntu/proxy-king/setup_3proxy.sh}"
BOT_POLL_TIMEOUT="${BOT_POLL_TIMEOUT:-30}"
API_BASE="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
OFFSET_FILE="/var/lib/proxy-telegram-bot/offset"

mkdir -p /var/lib/proxy-telegram-bot

require_bin() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Missing dependency: $cmd"
    exit 1
  fi
}

require_bin curl
require_bin jq
require_bin bash

if [[ ! -x "$PROXY_SCRIPT_PATH" ]]; then
  echo "[ERROR] Proxy script not found or not executable: $PROXY_SCRIPT_PATH"
  exit 1
fi

send_message() {
  local chat_id="$1"
  local text="$2"

  curl -sS -X POST "${API_BASE}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    >/dev/null || true
}

is_allowed_chat() {
  local chat_id="$1"
  local ids=()
  IFS=',' read -r -a ids <<< "$ALLOWED_CHAT_IDS"

  for allowed in "${ids[@]}"; do
    if [[ "$chat_id" == "$allowed" ]]; then
      return 0
    fi
  done

  return 1
}

run_proxy_cmd() {
  local args=("$@")
  sudo bash "$PROXY_SCRIPT_PATH" "${args[@]}" 2>&1 || true
}

truncate_text() {
  local input="$1"
  local limit=3500
  if (( ${#input} > limit )); then
    printf '%s\n[...truncated...]' "${input:0:limit}"
  else
    printf '%s' "$input"
  fi
}

handle_command() {
  local chat_id="$1"
  local text="$2"
  local out=""
  local cmd="${text%% *}"
  local parts=()
  local add_port=""
  local add_user=""
  local add_pass=""
  local add_proto=""
  local add_max_ips=""
  local token=""
  local -a add_cmd=()

  read -r -a parts <<< "$text"

  case "$cmd" in
    /start|/help)
      send_message "$chat_id" $'Proxy Bot commands:\n/help\n/status\n/health\n/list_active\n/list_expired\n/restart_3proxy\n/add_user <port> <username> [password] [protocol] [max_client_ips]\n/pause_user <username>\n/resume_user <username>\n/rotate_passwords [username]'
      ;;
    /status)
      out="$(systemctl status 3proxy --no-pager -l 2>&1 || true)"
      send_message "$chat_id" "$(truncate_text "$out")"
      ;;
    /health)
      out="$(run_proxy_cmd --health-check)"
      send_message "$chat_id" "$(truncate_text "$out")"
      ;;
    /list_active)
      out="$(run_proxy_cmd --list-active)"
      send_message "$chat_id" "$(truncate_text "$out")"
      ;;
    /list_expired)
      out="$(run_proxy_cmd --list-expired)"
      send_message "$chat_id" "$(truncate_text "$out")"
      ;;
    /restart_3proxy)
      if systemctl restart 3proxy 2>/dev/null; then
        send_message "$chat_id" "3proxy restarted successfully."
      else
        send_message "$chat_id" "Failed to restart 3proxy. Check system logs."
      fi
      ;;
    /add_user)
      if [[ "${#parts[@]}" -lt 3 ]]; then
        send_message "$chat_id" "Usage: /add_user <port> <username> [password] [protocol] [max_client_ips]"
      elif ! [[ "${parts[1]}" =~ ^[0-9]+$ ]]; then
        send_message "$chat_id" "Invalid port. Example: /add_user 12050 team01"
      else
        add_port="${parts[1]}"
        add_user="${parts[2]}"
        add_pass=""
        add_proto=""
        add_max_ips=""

        for ((i=3; i<${#parts[@]}; i++)); do
          token="${parts[$i]}"
          if [[ "${token,,}" == "http" || "${token,,}" == "socks5" ]]; then
            if [[ -n "$add_proto" ]]; then
              out="Usage: /add_user <port> <username> [password] [protocol] [max_client_ips]"
              break
            fi
            add_proto="${token,,}"
          elif [[ "$token" =~ ^[0-9]+$ ]]; then
            if [[ -n "$add_max_ips" ]]; then
              out="Usage: /add_user <port> <username> [password] [protocol] [max_client_ips]"
              break
            fi
            add_max_ips="$token"
          elif [[ -z "$add_pass" ]]; then
            add_pass="$token"
          else
            out="Usage: /add_user <port> <username> [password] [protocol] [max_client_ips]"
            break
          fi
        done

        if [[ -z "$out" ]]; then
          add_cmd=(--add-user "$add_port" "$add_user")
          if [[ -n "$add_pass" ]]; then
            add_cmd+=("$add_pass")
          fi
          if [[ -n "$add_proto" ]]; then
            add_cmd+=(--protocol "$add_proto")
          fi
          if [[ -n "$add_max_ips" ]]; then
            add_cmd+=(--max-client-ips "$add_max_ips")
          fi
          out="$(run_proxy_cmd "${add_cmd[@]}")"
        fi
        send_message "$chat_id" "$(truncate_text "$out")"
      fi
      ;;
    /pause_user)
      if [[ "${#parts[@]}" -ne 2 ]]; then
        send_message "$chat_id" "Usage: /pause_user <username>"
      else
        out="$(run_proxy_cmd --pause-user "${parts[1]}")"
        send_message "$chat_id" "$(truncate_text "$out")"
      fi
      ;;
    /resume_user)
      if [[ "${#parts[@]}" -ne 2 ]]; then
        send_message "$chat_id" "Usage: /resume_user <username>"
      else
        out="$(run_proxy_cmd --resume-user "${parts[1]}")"
        send_message "$chat_id" "$(truncate_text "$out")"
      fi
      ;;
    /rotate_passwords)
      if [[ "${#parts[@]}" -eq 1 ]]; then
        out="$(run_proxy_cmd --rotate-passwords)"
      elif [[ "${#parts[@]}" -eq 2 ]]; then
        out="$(run_proxy_cmd --rotate-passwords --user "${parts[1]}")"
      else
        out="Usage: /rotate_passwords [username]"
      fi
      send_message "$chat_id" "$(truncate_text "$out")"
      ;;
    *)
      send_message "$chat_id" "Unknown command. Send /help"
      ;;
  esac
}

if [[ -f "$OFFSET_FILE" ]]; then
  OFFSET="$(cat "$OFFSET_FILE")"
else
  OFFSET=0
fi

while true; do
  UPDATES_JSON="$(curl -sS "${API_BASE}/getUpdates?timeout=${BOT_POLL_TIMEOUT}&offset=${OFFSET}")"

  if [[ "$(jq -r '.ok' <<< "$UPDATES_JSON" 2>/dev/null)" != "true" ]]; then
    sleep 2
    continue
  fi

  mapfile -t update_rows < <(jq -c '.result[]?' <<< "$UPDATES_JSON")
  if [[ "${#update_rows[@]}" -eq 0 ]]; then
    continue
  fi

  for row in "${update_rows[@]}"; do
    update_id="$(jq -r '.update_id' <<< "$row")"
    chat_id="$(jq -r '.message.chat.id // .edited_message.chat.id // empty' <<< "$row")"
    text="$(jq -r '.message.text // .edited_message.text // empty' <<< "$row")"

    OFFSET=$((update_id + 1))
    printf '%s' "$OFFSET" > "$OFFSET_FILE"

    if [[ -z "$chat_id" || -z "$text" ]]; then
      continue
    fi

    if ! is_allowed_chat "$chat_id"; then
      send_message "$chat_id" "Unauthorized."
      continue
    fi

    handle_command "$chat_id" "$text"
  done
done
