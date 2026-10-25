#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup_3proxy.sh"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash proxy_ui.sh"
  exit 1
fi

if [[ ! -f "$SETUP_SCRIPT" ]]; then
  echo "[ERROR] Missing setup script: $SETUP_SCRIPT"
  exit 1
fi

run_setup() {
  local cmd=("$SETUP_SCRIPT" "$@")

  echo
  echo "Running: bash ${cmd[*]}"
  echo
  if bash "${cmd[@]}"; then
    echo
    echo "[DONE] Command completed."
  else
    echo
    echo "[ERROR] Command failed."
  fi
  echo
  read -r -p "Press Enter to continue..." _pause
}

prompt_input() {
  local prompt="$1"
  local default_val="${2:-}"
  local value=""

  if [[ -n "$default_val" ]]; then
    read -r -p "$prompt [$default_val]: " value
    if [[ -z "$value" ]]; then
      value="$default_val"
    fi
  else
    read -r -p "$prompt: " value
  fi

  printf '%s' "$value"
}

pause_screen() {
  echo
  read -r -p "Press Enter to continue..." _pause
}

choose_protocol() {
  local choice
  while true; do
    echo >&2
    echo "Select protocol:" >&2
    echo "1) http" >&2
    echo "2) socks5" >&2
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
      1) echo "http"; return ;;
      2) echo "socks5"; return ;;
      *) echo "[WARN] Invalid choice." >&2 ;;
    esac
  done
}

choose_expiry_mode() {
  local choice
  while true; do
    echo >&2
    echo "Select expiration mode:" >&2
    echo "1) none" >&2
    echo "2) days" >&2
    echo "3) at (absolute date/time)" >&2
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
      1) echo "none"; return ;;
      2) echo "days"; return ;;
      3) echo "at"; return ;;
      *) echo "[WARN] Invalid choice." >&2 ;;
    esac
  done
}

choose_max_ips_action() {
  local choice
  while true; do
    echo >&2
    echo "On max client IP limit breach:" >&2
    echo "1) delete" >&2
    echo "2) pause" >&2
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
      1) echo "delete"; return ;;
      2) echo "pause"; return ;;
      *) echo "[WARN] Invalid choice." >&2 ;;
    esac
  done
}

create_proxies_flow() {
  local count start_port user_prefix protocol whitelist cred_mode distribution_host
  local expire_mode expire_days expires_at max_client_ips max_client_ips_action
  local harden="no" keep_ipv6="no"
  local cmd_args=()

  echo
  echo "=== Create Proxies ==="

  count="$(prompt_input "Proxy count" "20")"
  start_port="$(prompt_input "Start port" "10000")"
  user_prefix="$(prompt_input "Username prefix" "user")"
  protocol="$(choose_protocol)"
  whitelist="$(prompt_input "Source whitelist (*, IP, CIDR, comma-separated)" "*")"
  distribution_host="$(prompt_input "Distribution host/domain (blank = auto server IP)" "")"

  while true; do
    cred_mode="$(prompt_input "Credential mode (auto/manual)" "auto")"
    cred_mode="$(printf '%s' "$cred_mode" | tr '[:upper:]' '[:lower:]')"
    if [[ "$cred_mode" == "auto" || "$cred_mode" == "manual" ]]; then
      break
    fi
    echo "[WARN] Enter auto or manual."
  done

  max_client_ips="$(prompt_input "Max unique client IPs per account (0=unlimited)" "0")"
  max_client_ips_action="$(choose_max_ips_action)"
  expire_mode="$(choose_expiry_mode)"

  expire_days=""
  expires_at=""
  case "$expire_mode" in
    days)
      expire_days="$(prompt_input "Expire after how many days" "7")"
      ;;
    at)
      expires_at="$(prompt_input "Expires at (e.g. 2026-03-31 23:59:59)" "")"
      ;;
  esac

  if [[ "$(prompt_input "Enable OS hardening? (y/N)" "n")" =~ ^[Yy]$ ]]; then
    harden="yes"
    if [[ "$(prompt_input "Keep IPv6 enabled? (y/N)" "n")" =~ ^[Yy]$ ]]; then
      keep_ipv6="yes"
    fi
  fi

  cmd_args=("$count" "$start_port" "$user_prefix" "$protocol" "$whitelist" "$cred_mode")
  if [[ -n "$distribution_host" ]]; then
    cmd_args+=("--host" "$distribution_host")
  fi
  if [[ -n "$expire_days" ]]; then
    cmd_args+=("--expire-days" "$expire_days")
  fi
  if [[ -n "$expires_at" ]]; then
    cmd_args+=("--expires-at" "$expires_at")
  fi
  if [[ -n "$max_client_ips" ]]; then
    cmd_args+=("--max-client-ips" "$max_client_ips")
    cmd_args+=("--max-client-ips-action" "$max_client_ips_action")
  fi
  if [[ "$harden" == "yes" ]]; then
    cmd_args+=("--harden-os")
    if [[ "$keep_ipv6" == "yes" ]]; then
      cmd_args+=("--keep-ipv6")
    fi
  fi

  run_setup "${cmd_args[@]}"
}

add_user_flow() {
  local port username password protocol expire_mode expire_days expires_at max_client_ips max_client_ips_action
  local cmd_args=()

  echo
  echo "=== Add User ==="
  port="$(prompt_input "Port" "12050")"
  username="$(prompt_input "Username" "team01")"
  password="$(prompt_input "Password (blank = auto-generate)" "")"

  while true; do
    protocol="$(prompt_input "Protocol (auto/http/socks5)" "auto")"
    protocol="$(printf '%s' "$protocol" | tr '[:upper:]' '[:lower:]')"
    if [[ "$protocol" == "auto" || "$protocol" == "http" || "$protocol" == "socks5" ]]; then
      break
    fi
    echo "[WARN] Enter auto, http, or socks5."
  done

  max_client_ips="$(prompt_input "Max unique client IPs (0=unlimited)" "0")"
  max_client_ips_action="$(choose_max_ips_action)"
  expire_mode="$(choose_expiry_mode)"

  expire_days=""
  expires_at=""
  case "$expire_mode" in
    days)
      expire_days="$(prompt_input "Expire after how many days" "7")"
      ;;
    at)
      expires_at="$(prompt_input "Expires at (e.g. 2026-03-31 23:59:59)" "")"
      ;;
  esac

  cmd_args=("--add-user" "$port" "$username")
  if [[ -n "$password" ]]; then
    cmd_args+=("$password")
  fi
  if [[ "$protocol" != "auto" ]]; then
    cmd_args+=("--protocol" "$protocol")
  fi
  if [[ -n "$max_client_ips" ]]; then
    cmd_args+=("--max-client-ips" "$max_client_ips")
    cmd_args+=("--max-client-ips-action" "$max_client_ips_action")
  fi
  if [[ -n "$expire_days" ]]; then
    cmd_args+=("--expire-days" "$expire_days")
  fi
  if [[ -n "$expires_at" ]]; then
    cmd_args+=("--expires-at" "$expires_at")
  fi

  run_setup "${cmd_args[@]}"
}

reactivate_or_resume_flow() {
  local mode username use_new_expiry="no" expiry_type days at

  echo
  echo "=== Resume/Reactivate User ==="

  while true; do
    mode="$(prompt_input "Action (resume/reactivate)" "resume")"
    mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    if [[ "$mode" == "resume" || "$mode" == "reactivate" ]]; then
      break
    fi
    echo "[WARN] Enter resume or reactivate."
  done

  username="$(prompt_input "Username" "user001")"

  if [[ "$(prompt_input "Set a new expiry? (y/N)" "n")" =~ ^[Yy]$ ]]; then
    use_new_expiry="yes"
  fi

  if [[ "$mode" == "resume" ]]; then
    if [[ "$use_new_expiry" == "yes" ]]; then
      expiry_type="$(choose_expiry_mode)"
      if [[ "$expiry_type" == "none" ]]; then
        run_setup --resume-user "$username"
        return
      fi
      if [[ "$expiry_type" == "days" ]]; then
        days="$(prompt_input "Days" "7")"
        run_setup --resume-user "$username" --new-expire-days "$days"
      else
        at="$(prompt_input "Date/time" "2026-03-31 23:59:59")"
        run_setup --resume-user "$username" --new-expires-at "$at"
      fi
    else
      run_setup --resume-user "$username"
    fi
  else
    if [[ "$use_new_expiry" == "yes" ]]; then
      expiry_type="$(choose_expiry_mode)"
      if [[ "$expiry_type" == "none" ]]; then
        run_setup --reactivate-user "$username"
        return
      fi
      if [[ "$expiry_type" == "days" ]]; then
        days="$(prompt_input "Days" "7")"
        run_setup --reactivate-user "$username" --new-expire-days "$days"
      else
        at="$(prompt_input "Date/time" "2026-03-31 23:59:59")"
        run_setup --reactivate-user "$username" --new-expires-at "$at"
      fi
    else
      run_setup --reactivate-user "$username"
    fi
  fi
}

rotate_passwords_flow() {
  local scope username

  echo
  echo "=== Rotate Passwords ==="
  while true; do
    scope="$(prompt_input "Scope (all/one)" "all")"
    scope="$(printf '%s' "$scope" | tr '[:upper:]' '[:lower:]')"
    if [[ "$scope" == "all" || "$scope" == "one" ]]; then
      break
    fi
    echo "[WARN] Enter all or one."
  done

  if [[ "$scope" == "all" ]]; then
    run_setup --rotate-passwords
  else
    username="$(prompt_input "Username" "user001")"
    run_setup --rotate-passwords --user "$username"
  fi
}

port_check_flow() {
  local start_port count
  echo
  echo "=== Port Range Check ==="
  start_port="$(prompt_input "Start port" "10000")"
  count="$(prompt_input "Count" "20")"
  run_setup --port-range-check "$start_port" "$count"
}

health_check_flow() {
  run_setup --health-check
}

alive_accounts_flow() {
  run_setup --list-alive
}

set_distribution_host_flow() {
  local host
  echo
  echo "=== Set Distribution Host ==="
  host="$(prompt_input "Domain or IP (example: proxy.example.com)" "")"
  if [[ -z "$host" ]]; then
    echo "[WARN] Host cannot be empty."
    pause_screen
    return
  fi
  run_setup --set-host "$host"
}

apply_hardening_now_flow() {
  local keep_ipv6
  echo
  echo "=== Apply Security Hardening ==="
  keep_ipv6="$(prompt_input "Keep IPv6 enabled? (y/N)" "n")"
  if [[ "$keep_ipv6" =~ ^[Yy]$ ]]; then
    run_setup --harden-now --keep-ipv6
  else
    run_setup --harden-now
  fi
}

run_security_audit_flow() {
  echo
  echo "=== Security Audit ==="
  run_setup --security-audit
}

list_flow() {
  local which=""

  echo
  echo "=== List Users ==="
  while true; do
    which="$(prompt_input "Which list (active/expired)" "active")"
    which="$(printf '%s' "$which" | tr '[:upper:]' '[:lower:]')"
    if [[ "$which" == "active" || "$which" == "expired" ]]; then
      break
    fi
    echo "[WARN] Enter active or expired."
  done

  if [[ "$which" == "active" ]]; then
    run_setup --list-active
  else
    run_setup --list-expired
  fi
}

simple_user_action() {
  local action="$1"
  local title="$2"
  local username
  echo
  echo "=== $title ==="
  username="$(prompt_input "Username" "user001")"
  run_setup "$action" "$username"
}

show_main_menu() {
  clear
  echo "==============================================="
  echo " Proxy Manager - CLI Menu"
  echo "==============================================="
  echo "1) Create proxies"
  echo "2) List users (active/expired)"
  echo "3) Add user (incremental)"
  echo "4) Rotate passwords"
  echo "5) Pause user"
  echo "6) Resume/Reactivate user"
  echo "7) Delete user"
  echo "8) Port range check"
  echo "9) Health check"
  echo "10) Show alive accounts"
  echo "11) Set distribution host/domain"
  echo "12) Apply security hardening now"
  echo "13) Run security audit"
  echo "0) Exit"
  echo
}

while true; do
  show_main_menu
  read -r -p "Select option [0-13]: " action

  case "$action" in
    1) create_proxies_flow ;;
    2) list_flow ;;
    3) add_user_flow ;;
    4) rotate_passwords_flow ;;
    5) simple_user_action "--pause-user" "Pause User" ;;
    6) reactivate_or_resume_flow ;;
    7) simple_user_action "--delete-user" "Delete User" ;;
    8) port_check_flow ;;
    9) health_check_flow ;;
    10) alive_accounts_flow ;;
    11) set_distribution_host_flow ;;
    12) apply_hardening_now_flow ;;
    13) run_security_audit_flow ;;
    0) break ;;
    *)
      echo "[WARN] Invalid menu option."
      pause_screen
      ;;
  esac
done

echo "Bye."
