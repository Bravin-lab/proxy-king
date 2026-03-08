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

if ! command -v whiptail >/dev/null 2>&1; then
  echo "[INFO] Installing whiptail..."
  apt-get update -y >/dev/null
  apt-get install -y whiptail >/dev/null
fi

run_setup() {
  local cmd=("$SETUP_SCRIPT" "$@")

  clear
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
  read -r -p "Press Enter to continue..." _
}

ask_input() {
  local title="$1"
  local prompt="$2"
  local default_val="$3"
  whiptail --title "$title" --inputbox "$prompt" 12 70 "$default_val" 3>&1 1>&2 2>&3
}

ask_menu() {
  local title="$1"
  local prompt="$2"
  shift 2
  whiptail --title "$title" --menu "$prompt" 20 78 10 "$@" 3>&1 1>&2 2>&3
}

create_proxies_flow() {
  local count start_port user_prefix protocol whitelist cred_mode
  local expire_mode expire_days expires_at max_client_ips
  local harden="no" keep_ipv6="no"
  local cmd_args=()

  count="$(ask_input "Create Proxies" "Proxy count" "20")" || return
  start_port="$(ask_input "Create Proxies" "Start port" "10000")" || return
  user_prefix="$(ask_input "Create Proxies" "Username prefix" "user")" || return

  protocol="$(ask_menu "Create Proxies" "Protocol" \
    "http" "HTTP proxy" \
    "socks5" "SOCKS5 proxy")" || return

  whitelist="$(ask_input "Create Proxies" "Source whitelist (*, IP, CIDR, or comma-separated)" "*")" || return

  cred_mode="$(ask_menu "Create Proxies" "Credential mode" \
    "auto" "Auto-generate users/passwords" \
    "manual" "Prompt per user/password")" || return

  max_client_ips="$(ask_input "Create Proxies" "Max unique client IPs per account (0 = unlimited)" "0")" || return

  expire_mode="$(ask_menu "Create Proxies" "Expiration mode" \
    "none" "No expiry" \
    "days" "Expire after N days" \
    "at" "Expire at date/time")" || return

  expire_days=""
  expires_at=""
  case "$expire_mode" in
    days)
      expire_days="$(ask_input "Create Proxies" "Expire after how many days?" "7")" || return
      ;;
    at)
      expires_at="$(ask_input "Create Proxies" "Expires at (e.g. 2026-03-31 23:59:59)" "")" || return
      ;;
  esac

  if whiptail --title "Create Proxies" --yesno "Enable OS hardening?" 10 60; then
    harden="yes"
    if whiptail --title "Create Proxies" --yesno "Keep IPv6 enabled?" 10 60; then
      keep_ipv6="yes"
    fi
  fi

  cmd_args=("$count" "$start_port" "$user_prefix" "$protocol" "$whitelist" "$cred_mode")
  if [[ -n "$expire_days" ]]; then
    cmd_args+=("--expire-days" "$expire_days")
  fi
  if [[ -n "$expires_at" ]]; then
    cmd_args+=("--expires-at" "$expires_at")
  fi
  if [[ -n "$max_client_ips" ]]; then
    cmd_args+=("--max-client-ips" "$max_client_ips")
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
  local port username password protocol expire_mode expire_days expires_at max_client_ips
  local cmd_args=()

  port="$(ask_input "Add User" "Port" "12050")" || return
  username="$(ask_input "Add User" "Username" "team01")" || return
  password="$(ask_input "Add User" "Password (leave blank to auto-generate)" "")" || return

  protocol="$(ask_menu "Add User" "Protocol" \
    "auto" "Use current default protocol" \
    "http" "HTTP" \
    "socks5" "SOCKS5")" || return

  max_client_ips="$(ask_input "Add User" "Max unique client IPs (0 = unlimited)" "0")" || return

  expire_mode="$(ask_menu "Add User" "Expiration mode" \
    "none" "No expiry" \
    "days" "Expire after N days" \
    "at" "Expire at date/time")" || return

  expire_days=""
  expires_at=""
  case "$expire_mode" in
    days)
      expire_days="$(ask_input "Add User" "Expire after how many days?" "7")" || return
      ;;
    at)
      expires_at="$(ask_input "Add User" "Expires at (e.g. 2026-03-31 23:59:59)" "")" || return
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

  mode="$(ask_menu "Resume/Reactivate" "Choose action" \
    "resume" "Resume user" \
    "reactivate" "Reactivate user")" || return

  username="$(ask_input "Resume/Reactivate" "Username" "user001")" || return

  if whiptail --title "Resume/Reactivate" --yesno "Set a new expiry?" 10 60; then
    use_new_expiry="yes"
  fi

  if [[ "$mode" == "resume" ]]; then
    if [[ "$use_new_expiry" == "yes" ]]; then
      expiry_type="$(ask_menu "New Expiry" "Select mode" \
        "days" "Expire after N days" \
        "at" "Expire at date/time")" || return
      if [[ "$expiry_type" == "days" ]]; then
        days="$(ask_input "New Expiry" "Days" "7")" || return
        run_setup --resume-user "$username" --new-expire-days "$days"
      else
        at="$(ask_input "New Expiry" "Date/time" "2026-03-31 23:59:59")" || return
        run_setup --resume-user "$username" --new-expires-at "$at"
      fi
    else
      run_setup --resume-user "$username"
    fi
  else
    if [[ "$use_new_expiry" == "yes" ]]; then
      expiry_type="$(ask_menu "New Expiry" "Select mode" \
        "days" "Expire after N days" \
        "at" "Expire at date/time")" || return
      if [[ "$expiry_type" == "days" ]]; then
        days="$(ask_input "New Expiry" "Days" "7")" || return
        run_setup --reactivate-user "$username" --new-expire-days "$days"
      else
        at="$(ask_input "New Expiry" "Date/time" "2026-03-31 23:59:59")" || return
        run_setup --reactivate-user "$username" --new-expires-at "$at"
      fi
    else
      run_setup --reactivate-user "$username"
    fi
  fi
}

rotate_passwords_flow() {
  local scope username
  scope="$(ask_menu "Rotate Passwords" "Scope" \
    "all" "Rotate all users" \
    "one" "Rotate one user")" || return

  if [[ "$scope" == "all" ]]; then
    run_setup --rotate-passwords
  else
    username="$(ask_input "Rotate Passwords" "Username" "user001")" || return
    run_setup --rotate-passwords --user "$username"
  fi
}

port_check_flow() {
  local start_port count
  start_port="$(ask_input "Port Range Check" "Start port" "10000")" || return
  count="$(ask_input "Port Range Check" "Count" "20")" || return
  run_setup --port-range-check "$start_port" "$count"
}

health_check_flow() {
  run_setup --health-check
}

list_flow() {
  local which
  which="$(ask_menu "List Users" "Select list" \
    "active" "Active users" \
    "expired" "Expired users")" || return

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
  username="$(ask_input "$title" "Username" "user001")" || return
  run_setup "$action" "$username"
}

while true; do
  action="$(ask_menu "Proxy Manager UI" "Choose an action" \
    "1" "Create proxies" \
    "2" "List users (active/expired)" \
    "3" "Add user (incremental)" \
    "4" "Rotate passwords" \
    "5" "Pause user" \
    "6" "Resume/Reactivate user" \
    "7" "Delete user" \
    "8" "Port range check" \
    "9" "Health check" \
    "0" "Exit")" || break

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
    0) break ;;
  esac
done

echo "Bye."
