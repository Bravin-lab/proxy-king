#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash setup_3proxy.sh <proxy_count> <start_port> [username_prefix] [protocol] [whitelist] [credential_mode] [--expire-days N|--expires-at DATETIME] [--harden-os] [--keep-ipv6]
#   sudo bash setup_3proxy.sh --list-active
#   sudo bash setup_3proxy.sh --list-expired
#   sudo bash setup_3proxy.sh --reactivate-user <username> [--new-expire-days N|--new-expires-at DATETIME]
#   sudo bash setup_3proxy.sh --rotate-passwords [--user <username>]
#   sudo bash setup_3proxy.sh --delete-user <username>
#   sudo bash setup_3proxy.sh --add-user <port> <username> [password] [--expire-days N|--expires-at DATETIME]
#   sudo bash setup_3proxy.sh --pause-user <username>
#   sudo bash setup_3proxy.sh --resume-user <username>
#   sudo bash setup_3proxy.sh --port-range-check <start_port> <count>
#   sudo bash setup_3proxy.sh --health-check
# Example:
#   sudo bash setup_3proxy.sh 20 10000 user
#   sudo bash setup_3proxy.sh 20 10000 user socks5 203.0.113.10
#   sudo bash setup_3proxy.sh 5 15000 user http "*" manual

CFG_DIR="/etc/3proxy"
CFG_FILE="$CFG_DIR/3proxy.cfg"
OUTPUT_CREDENTIALS="/root/proxy-users.txt"
OUTPUT_LIST="/root/proxy-list.txt"
DB_FILE="$CFG_DIR/proxy-db.txt"
SETTINGS_FILE="$CFG_DIR/proxy-settings.env"
EXPIRY_CHECK_SCRIPT="/usr/local/bin/3proxy-expiry-check.sh"
EXPIRY_SERVICE_FILE="/etc/systemd/system/3proxy-expiry-check.service"
EXPIRY_TIMER_FILE="/etc/systemd/system/3proxy-expiry-check.timer"
SYSCTL_HARDEN_FILE="/etc/sysctl.d/99-proxy-hardening.conf"

print_usage() {
  echo "Usage:"
  echo "  sudo bash $0 <proxy_count> <start_port> [username_prefix] [protocol] [whitelist] [credential_mode] [--expire-days N|--expires-at DATETIME] [--harden-os] [--keep-ipv6]"
  echo "  sudo bash $0 --list-active"
  echo "  sudo bash $0 --list-expired"
  echo "  sudo bash $0 --reactivate-user <username> [--new-expire-days N|--new-expires-at DATETIME]"
  echo "  sudo bash $0 --rotate-passwords [--user <username>]"
  echo "  sudo bash $0 --delete-user <username>"
  echo "  sudo bash $0 --add-user <port> <username> [password] [--expire-days N|--expires-at DATETIME]"
  echo "  sudo bash $0 --pause-user <username>"
  echo "  sudo bash $0 --resume-user <username>"
  echo "  sudo bash $0 --port-range-check <start_port> <count>"
  echo "  sudo bash $0 --health-check"
  echo
  echo "protocol: http (default) or socks5"
  echo "whitelist: optional source IP/CIDR or comma-separated list"
  echo "credential_mode: auto (default) or manual"
  echo "--expire-days N: optional expiration window in days"
  echo "--expires-at DATETIME: optional absolute expiry date/time"
  echo "--harden-os: apply host network hardening"
  echo "--keep-ipv6: with --harden-os, do not disable IPv6"
}

render_existing_config_from_db() {
  local tmp_cfg
  local user_line
  local active_count
  local username
  local password
  local port
  local expires_epoch
  local status

  if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "[ERROR] Missing settings file: $SETTINGS_FILE"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$SETTINGS_FILE"

  tmp_cfg="$(mktemp)"
  {
    echo "daemon"
    echo "maxconn 2000"
    echo "nserver 1.1.1.1/tcp"
    echo "nserver 8.8.8.8/tcp"
    echo "nserver 9.9.9.9/tcp"
    echo "nscache 65536"
    echo "internal 0.0.0.0"
    if [[ -n "${EXTERNAL_IP}" ]]; then
      echo "external ${EXTERNAL_IP}"
    fi
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid 65535"
    echo "setuid 65535"
    echo "stacksize 6291456"
    echo "auth strong"
    echo
  } > "$tmp_cfg"

  user_line="users "
  active_count=0
  while IFS='|' read -r username password port expires_epoch status; do
    [[ -z "${username:-}" ]] && continue
    if [[ "$status" == "active" ]]; then
      user_line+="${username}:CL:${password} "
      active_count=$((active_count + 1))
    fi
  done < "$DB_FILE"

  if [[ "$active_count" -eq 0 ]]; then
    user_line+="disabled:CL:disabled"
  fi

  echo "$user_line" >> "$tmp_cfg"
  echo >> "$tmp_cfg"

  while IFS='|' read -r username password port expires_epoch status; do
    [[ -z "${username:-}" ]] && continue
    if [[ "$status" == "active" ]]; then
      {
        echo "allow ${username} ${WHITELIST}"
        echo "${PROXY_BIN} -n -a -p${port} -i0.0.0.0${OUTBOUND_BIND_OPT}"
        echo "deny *"
        echo "flush"
        echo
      } >> "$tmp_cfg"
    fi
  done < "$DB_FILE"

  if [[ "$active_count" -eq 0 ]]; then
    {
      echo "deny *"
      echo "flush"
      echo
    } >> "$tmp_cfg"
  fi

  mv "$tmp_cfg" "$CFG_FILE"
  chmod 600 "$CFG_FILE"
}

format_epoch_or_never() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -gt 0 ]]; then
    date -d "@${v}" '+%Y-%m-%d %H:%M:%S %Z'
  else
    echo "never"
  fi
}

load_settings_or_fail() {
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "[ERROR] Missing settings file: $SETTINGS_FILE"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$SETTINGS_FILE"
}

uri_scheme_from_proxy_bin() {
  if [[ "${PROXY_BIN:-}" == "socks" ]]; then
    echo "socks5h"
  else
    echo "http"
  fi
}

is_port_listening() {
  local port="$1"
  ss -lntH "( sport = :${port} )" 2>/dev/null | grep -q .
}

regenerate_exports_from_db() {
  local username
  local password
  local port
  local expires_epoch
  local status
  local scheme
  local list_ip

  load_settings_or_fail || return 1

  scheme="$(uri_scheme_from_proxy_bin)"
  list_ip="${EXTERNAL_IP:-}"
  if [[ -z "$list_ip" ]]; then
    list_ip="$(curl -4 -fsS ifconfig.me || true)"
  fi
  if [[ -z "$list_ip" ]]; then
    list_ip="YOUR_SERVER_IP"
  fi

  : > "$OUTPUT_CREDENTIALS"
  : > "$OUTPUT_LIST"

  while IFS='|' read -r username password port expires_epoch status; do
    [[ -z "${username:-}" ]] && continue
    if [[ "$status" == "active" ]]; then
      echo "${username}:${password}:${port}" >> "$OUTPUT_CREDENTIALS"
      echo "${scheme}://${username}:${password}@${list_ip}:${port}" >> "$OUTPUT_LIST"
    fi
  done < "$DB_FILE"
}

rebuild_runtime_from_db() {
  render_existing_config_from_db
  regenerate_exports_from_db
  systemctl restart 3proxy
}

apply_os_hardening() {
  local disable_ipv6="$1"

  echo "[INFO] Applying OS hardening..."

  {
    echo "# Managed by setup_3proxy.sh"
    echo "net.ipv4.conf.all.rp_filter = 1"
    echo "net.ipv4.conf.default.rp_filter = 1"
    echo "net.ipv4.conf.all.accept_redirects = 0"
    echo "net.ipv4.conf.default.accept_redirects = 0"
    echo "net.ipv4.conf.all.send_redirects = 0"
    echo "net.ipv4.conf.default.send_redirects = 0"
    echo "net.ipv4.conf.all.accept_source_route = 0"
    echo "net.ipv4.conf.default.accept_source_route = 0"

    if [[ "$disable_ipv6" == "1" ]]; then
      echo "net.ipv6.conf.all.disable_ipv6 = 1"
      echo "net.ipv6.conf.default.disable_ipv6 = 1"
      echo "net.ipv6.conf.lo.disable_ipv6 = 1"
    fi
  } > "$SYSCTL_HARDEN_FILE"

  sysctl --system >/dev/null

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
    echo "[INFO] UFW is active. Hardening DNS egress rules..."
    ufw allow out to 1.1.1.1 port 53 proto tcp >/dev/null || true
    ufw allow out to 8.8.8.8 port 53 proto tcp >/dev/null || true
    ufw allow out to 9.9.9.9 port 53 proto tcp >/dev/null || true
    ufw deny out to any port 53 proto udp >/dev/null || true
    ufw deny out to any port 53 proto tcp >/dev/null || true
  else
    echo "[WARN] UFW not active. DNS egress hardening rules were not applied."
  fi
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERROR] Run this script as root (use sudo)."
  exit 1
fi

if [[ "${1:-}" == --* ]]; then
  case "$1" in
    --list-active|--list-expired|--reactivate-user|--rotate-passwords|--delete-user|--add-user|--pause-user|--resume-user|--health-check)
      if [[ ! -f "$DB_FILE" ]]; then
        echo "[ERROR] Proxy DB not found at $DB_FILE"
        echo "Run proxy creation first."
        exit 1
      fi
      ;;
  esac

  case "$1" in
    --list-active|--list-expired)
      TARGET_STATUS="active"
      if [[ "$1" == "--list-expired" ]]; then
        TARGET_STATUS="expired"
      fi

      printf '%-20s %-8s %-10s %s\n' "USERNAME" "PORT" "STATUS" "EXPIRES_AT"
      while IFS='|' read -r username password port expires_epoch status; do
        [[ -z "${username:-}" ]] && continue
        if [[ "$status" == "$TARGET_STATUS" ]]; then
          printf '%-20s %-8s %-10s %s\n' "$username" "$port" "$status" "$(format_epoch_or_never "$expires_epoch")"
        fi
      done < "$DB_FILE"
      exit 0
      ;;
    --reactivate-user|--resume-user)
      TARGET_USER="${2:-}"
      NEW_EXPIRE_DAYS=""
      NEW_EXPIRES_AT=""

      if [[ -z "$TARGET_USER" ]]; then
        echo "[ERROR] Missing username."
        echo "Usage: sudo bash $0 --reactivate-user <username> [--new-expire-days N|--new-expires-at DATETIME]"
        exit 1
      fi

      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --new-expire-days)
            NEW_EXPIRE_DAYS="${2:-}"
            shift 2
            ;;
          --new-expires-at)
            NEW_EXPIRES_AT="${2:-}"
            shift 2
            ;;
          *)
            echo "[ERROR] Unknown option for resume/reactivate: $1"
            exit 1
            ;;
        esac
      done

      if [[ -n "$NEW_EXPIRE_DAYS" && -n "$NEW_EXPIRES_AT" ]]; then
        echo "[ERROR] Use either --new-expire-days or --new-expires-at, not both."
        exit 1
      fi

      NEW_EXPIRES_EPOCH=""
      if [[ -n "$NEW_EXPIRE_DAYS" ]]; then
        if ! [[ "$NEW_EXPIRE_DAYS" =~ ^[0-9]+$ ]] || [[ "$NEW_EXPIRE_DAYS" -le 0 ]]; then
          echo "[ERROR] --new-expire-days must be a positive integer."
          exit 1
        fi
        NEW_EXPIRES_EPOCH=$(( $(date +%s) + NEW_EXPIRE_DAYS * 86400 ))
      elif [[ -n "$NEW_EXPIRES_AT" ]]; then
        if ! NEW_EXPIRES_EPOCH="$(date -d "$NEW_EXPIRES_AT" +%s 2>/dev/null)"; then
          echo "[ERROR] Invalid --new-expires-at value."
          exit 1
        fi
      fi

      FOUND=0
      TMP_DB="$(mktemp)"
      while IFS='|' read -r username password port expires_epoch status; do
        [[ -z "${username:-}" ]] && continue
        if [[ "$username" == "$TARGET_USER" ]]; then
          FOUND=1
          if [[ -n "$NEW_EXPIRES_EPOCH" ]]; then
            expires_epoch="$NEW_EXPIRES_EPOCH"
          fi
          status="active"
        fi
        echo "${username}|${password}|${port}|${expires_epoch}|${status}" >> "$TMP_DB"
      done < "$DB_FILE"

      if [[ "$FOUND" -eq 0 ]]; then
        rm -f "$TMP_DB"
        echo "[ERROR] User not found in DB: $TARGET_USER"
        exit 1
      fi

      mv "$TMP_DB" "$DB_FILE"
      chmod 600 "$DB_FILE"

      rebuild_runtime_from_db

      echo "[INFO] User resumed/reactivated: $TARGET_USER"
      if [[ -n "$NEW_EXPIRES_EPOCH" ]]; then
        echo "[INFO] New expiry: $(date -d "@${NEW_EXPIRES_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z')"
      else
        echo "[INFO] Expiry unchanged."
      fi
      exit 0
      ;;
    --pause-user)
      TARGET_USER="${2:-}"
      if [[ -z "$TARGET_USER" ]]; then
        echo "[ERROR] Missing username."
        echo "Usage: sudo bash $0 --pause-user <username>"
        exit 1
      fi

      FOUND=0
      TMP_DB="$(mktemp)"
      while IFS='|' read -r username password port expires_epoch status; do
        [[ -z "${username:-}" ]] && continue
        if [[ "$username" == "$TARGET_USER" ]]; then
          FOUND=1
          status="paused"
        fi
        echo "${username}|${password}|${port}|${expires_epoch}|${status}" >> "$TMP_DB"
      done < "$DB_FILE"

      if [[ "$FOUND" -eq 0 ]]; then
        rm -f "$TMP_DB"
        echo "[ERROR] User not found in DB: $TARGET_USER"
        exit 1
      fi

      mv "$TMP_DB" "$DB_FILE"
      chmod 600 "$DB_FILE"
      rebuild_runtime_from_db
      echo "[INFO] User paused: $TARGET_USER"
      exit 0
      ;;
    --delete-user)
      TARGET_USER="${2:-}"
      if [[ -z "$TARGET_USER" ]]; then
        echo "[ERROR] Missing username."
        echo "Usage: sudo bash $0 --delete-user <username>"
        exit 1
      fi

      FOUND=0
      TMP_DB="$(mktemp)"
      while IFS='|' read -r username password port expires_epoch status; do
        [[ -z "${username:-}" ]] && continue
        if [[ "$username" == "$TARGET_USER" ]]; then
          FOUND=1
          continue
        fi
        echo "${username}|${password}|${port}|${expires_epoch}|${status}" >> "$TMP_DB"
      done < "$DB_FILE"

      if [[ "$FOUND" -eq 0 ]]; then
        rm -f "$TMP_DB"
        echo "[ERROR] User not found in DB: $TARGET_USER"
        exit 1
      fi

      mv "$TMP_DB" "$DB_FILE"
      chmod 600 "$DB_FILE"
      rebuild_runtime_from_db
      echo "[INFO] User deleted: $TARGET_USER"
      exit 0
      ;;
    --rotate-passwords)
      TARGET_USER=""
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --user)
            TARGET_USER="${2:-}"
            if [[ -z "$TARGET_USER" ]]; then
              echo "[ERROR] --user requires a value."
              exit 1
            fi
            shift 2
            ;;
          *)
            echo "[ERROR] Unknown option for --rotate-passwords: $1"
            exit 1
            ;;
        esac
      done

      FOUND=0
      CHANGED=0
      TMP_DB="$(mktemp)"
      while IFS='|' read -r username password port expires_epoch status; do
        [[ -z "${username:-}" ]] && continue
        if [[ -z "$TARGET_USER" || "$username" == "$TARGET_USER" ]]; then
          FOUND=1
          password="$(openssl rand -hex 6)"
          CHANGED=$((CHANGED + 1))
        fi
        echo "${username}|${password}|${port}|${expires_epoch}|${status}" >> "$TMP_DB"
      done < "$DB_FILE"

      if [[ -n "$TARGET_USER" && "$FOUND" -eq 0 ]]; then
        rm -f "$TMP_DB"
        echo "[ERROR] User not found in DB: $TARGET_USER"
        exit 1
      fi

      mv "$TMP_DB" "$DB_FILE"
      chmod 600 "$DB_FILE"
      rebuild_runtime_from_db
      if [[ -n "$TARGET_USER" ]]; then
        echo "[INFO] Password rotated for user: $TARGET_USER"
      else
        echo "[INFO] Passwords rotated for ${CHANGED} users."
      fi
      echo "[INFO] Updated list: $OUTPUT_LIST"
      exit 0
      ;;
    --add-user)
      NEW_PORT="${2:-}"
      NEW_USERNAME="${3:-}"
      NEW_PASSWORD=""
      NEW_EXPIRE_DAYS=""
      NEW_EXPIRES_AT=""
      OPT_INDEX=4

      if [[ -z "$NEW_PORT" || -z "$NEW_USERNAME" ]]; then
        echo "[ERROR] Usage: sudo bash $0 --add-user <port> <username> [password] [--expire-days N|--expires-at DATETIME]"
        exit 1
      fi

      if [[ "${4:-}" != "" && "${4:-}" != --* ]]; then
        NEW_PASSWORD="$4"
        OPT_INDEX=5
      fi

      while [[ $OPT_INDEX -le $# ]]; do
        opt="${!OPT_INDEX}"
        case "$opt" in
          --expire-days)
            OPT_INDEX=$((OPT_INDEX + 1))
            NEW_EXPIRE_DAYS="${!OPT_INDEX:-}"
            OPT_INDEX=$((OPT_INDEX + 1))
            ;;
          --expires-at)
            OPT_INDEX=$((OPT_INDEX + 1))
            NEW_EXPIRES_AT="${!OPT_INDEX:-}"
            OPT_INDEX=$((OPT_INDEX + 1))
            ;;
          *)
            echo "[ERROR] Unknown option for --add-user: $opt"
            exit 1
            ;;
        esac
      done

      if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ "$NEW_PORT" -lt 1024 ]] || [[ "$NEW_PORT" -gt 65535 ]]; then
        echo "[ERROR] Port must be an integer in range 1024-65535."
        exit 1
      fi

      if [[ ! "$NEW_USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "[ERROR] Username can contain only letters, numbers, _, ., -"
        exit 1
      fi

      if grep -qE "^${NEW_USERNAME}\|" "$DB_FILE"; then
        echo "[ERROR] Username already exists: $NEW_USERNAME"
        exit 1
      fi

      if awk -F'|' -v p="$NEW_PORT" '$3==p{found=1} END{exit !found}' "$DB_FILE"; then
        echo "[ERROR] Port already exists in DB: $NEW_PORT"
        exit 1
      fi

      if is_port_listening "$NEW_PORT"; then
        echo "[ERROR] Port is already in use on system: $NEW_PORT"
        exit 1
      fi

      if [[ -z "$NEW_PASSWORD" || "$NEW_PASSWORD" == --* ]]; then
        NEW_PASSWORD="$(openssl rand -hex 6)"
      fi

      if [[ "$NEW_PASSWORD" == *":"* || "$NEW_PASSWORD" == *" "* ]]; then
        echo "[ERROR] Password cannot contain spaces or ':'"
        exit 1
      fi

      if [[ -n "$NEW_EXPIRE_DAYS" && -n "$NEW_EXPIRES_AT" ]]; then
        echo "[ERROR] Use either --expire-days or --expires-at, not both."
        exit 1
      fi

      NEW_EXPIRES_EPOCH="0"
      if [[ -n "$NEW_EXPIRE_DAYS" ]]; then
        if ! [[ "$NEW_EXPIRE_DAYS" =~ ^[0-9]+$ ]] || [[ "$NEW_EXPIRE_DAYS" -le 0 ]]; then
          echo "[ERROR] --expire-days must be a positive integer."
          exit 1
        fi
        NEW_EXPIRES_EPOCH=$(( $(date +%s) + NEW_EXPIRE_DAYS * 86400 ))
      elif [[ -n "$NEW_EXPIRES_AT" ]]; then
        if ! NEW_EXPIRES_EPOCH="$(date -d "$NEW_EXPIRES_AT" +%s 2>/dev/null)"; then
          echo "[ERROR] Invalid --expires-at value."
          exit 1
        fi
      fi

      echo "${NEW_USERNAME}|${NEW_PASSWORD}|${NEW_PORT}|${NEW_EXPIRES_EPOCH}|active" >> "$DB_FILE"
      chmod 600 "$DB_FILE"
      rebuild_runtime_from_db
      echo "[INFO] Added user: ${NEW_USERNAME} on port ${NEW_PORT}"
      exit 0
      ;;
    --port-range-check)
      CHECK_START="${2:-}"
      CHECK_COUNT="${3:-}"

      if ! [[ "$CHECK_START" =~ ^[0-9]+$ ]] || ! [[ "$CHECK_COUNT" =~ ^[0-9]+$ ]] || [[ "$CHECK_COUNT" -le 0 ]]; then
        echo "[ERROR] Usage: sudo bash $0 --port-range-check <start_port> <count>"
        exit 1
      fi

      CHECK_END=$((CHECK_START + CHECK_COUNT - 1))
      if [[ "$CHECK_START" -lt 1024 || "$CHECK_END" -gt 65535 ]]; then
        echo "[ERROR] Port range must be within 1024-65535."
        exit 1
      fi

      printf '%-8s %-8s %-10s %s\n' "PORT" "DB_USED" "LISTENING" "RESULT"
      for ((p=CHECK_START; p<=CHECK_END; p++)); do
        DB_USED="no"
        if [[ -f "$DB_FILE" ]] && awk -F'|' -v port="$p" '$3==port{found=1} END{exit !found}' "$DB_FILE"; then
          DB_USED="yes"
        fi

        LISTENING="no"
        if is_port_listening "$p"; then
          LISTENING="yes"
        fi

        RESULT="free"
        if [[ "$DB_USED" == "yes" || "$LISTENING" == "yes" ]]; then
          RESULT="busy"
        fi
        printf '%-8s %-8s %-10s %s\n' "$p" "$DB_USED" "$LISTENING" "$RESULT"
      done
      exit 0
      ;;
    --health-check)
      load_settings_or_fail
      SCHEME="$(uri_scheme_from_proxy_bin)"
      TEST_URL="https://api.ipify.org"
      printf '%-20s %-8s %-8s %-10s %s\n' "USERNAME" "PORT" "STATUS" "LATENCY" "DETAIL"
      while IFS='|' read -r username password port expires_epoch status; do
        [[ -z "${username:-}" ]] && continue
        if [[ "$status" != "active" ]]; then
          continue
        fi

        proxy_url="${SCHEME}://${username}:${password}@127.0.0.1:${port}"
        check_out="$(curl -4 -sS --max-time 12 --proxy "$proxy_url" -o /dev/null -w '%{http_code} %{time_total}' "$TEST_URL" 2>/dev/null || true)"
        http_code="${check_out%% *}"
        latency="${check_out##* }"

        if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [[ "$http_code" != "000" ]]; then
          printf '%-20s %-8s %-8s %-10s %s\n' "$username" "$port" "up" "${latency}s" "HTTP $http_code"
        else
          printf '%-20s %-8s %-8s %-10s %s\n' "$username" "$port" "down" "-" "request failed"
        fi
      done < "$DB_FILE"
      exit 0
      ;;
    --*)
      echo "[ERROR] Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
fi

if [[ $# -lt 2 ]]; then
  print_usage
  exit 1
fi

PROXY_COUNT="$1"
START_PORT="$2"
USER_PREFIX="${3:-user}"
PROTOCOL_RAW="${4:-http}"
WHITELIST="${5:-*}"
CREDENTIAL_MODE_RAW="${6:-auto}"
EXPIRE_DAYS=""
EXPIRES_AT=""
HARDEN_OS="0"
DISABLE_IPV6_ON_HARDEN="1"

if [[ $# -ge 7 ]]; then
  EXTRA_ARGS=("${@:7}")
  idx=0
  while [[ $idx -lt ${#EXTRA_ARGS[@]} ]]; do
    arg="${EXTRA_ARGS[$idx]}"
    case "$arg" in
      --expire-days)
        idx=$((idx + 1))
        EXPIRE_DAYS="${EXTRA_ARGS[$idx]:-}"
        if [[ -z "$EXPIRE_DAYS" ]]; then
          echo "[ERROR] --expire-days requires a value."
          exit 1
        fi
        ;;
      --expires-at)
        idx=$((idx + 1))
        EXPIRES_AT="${EXTRA_ARGS[$idx]:-}"
        if [[ -z "$EXPIRES_AT" ]]; then
          echo "[ERROR] --expires-at requires a value."
          exit 1
        fi
        ;;
      --harden-os)
        HARDEN_OS="1"
        ;;
      --keep-ipv6)
        DISABLE_IPV6_ON_HARDEN="0"
        ;;
      *)
        echo "[ERROR] Unknown option: $arg"
        exit 1
        ;;
    esac
    idx=$((idx + 1))
  done
fi

if [[ -n "$EXPIRE_DAYS" && -n "$EXPIRES_AT" ]]; then
  echo "[ERROR] Use either --expire-days or --expires-at, not both."
  exit 1
fi

if [[ "$DISABLE_IPV6_ON_HARDEN" == "0" && "$HARDEN_OS" != "1" ]]; then
  echo "[ERROR] --keep-ipv6 can only be used with --harden-os."
  exit 1
fi

PROTOCOL="$(printf '%s' "$PROTOCOL_RAW" | tr '[:upper:]' '[:lower:]')"
if [[ "$PROTOCOL" != "http" && "$PROTOCOL" != "socks5" ]]; then
  echo "[ERROR] protocol must be 'http' or 'socks5'."
  exit 1
fi

if [[ "$WHITELIST" == "" ]]; then
  WHITELIST="*"
fi

CREDENTIAL_MODE="$(printf '%s' "$CREDENTIAL_MODE_RAW" | tr '[:upper:]' '[:lower:]')"
if [[ "$CREDENTIAL_MODE" != "auto" && "$CREDENTIAL_MODE" != "manual" ]]; then
  echo "[ERROR] credential_mode must be 'auto' or 'manual'."
  exit 1
fi

if ! [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]] || [[ "$PROXY_COUNT" -le 0 ]]; then
  echo "[ERROR] proxy_count must be a positive integer."
  exit 1
fi

if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [[ "$START_PORT" -lt 1024 ]] || [[ "$START_PORT" -gt 65535 ]]; then
  echo "[ERROR] start_port must be an integer in range 1024-65535."
  exit 1
fi

END_PORT=$((START_PORT + PROXY_COUNT - 1))
if [[ "$END_PORT" -gt 65535 ]]; then
  echo "[ERROR] Port range exceeds 65535. Reduce proxy_count or start_port."
  exit 1
fi

for ((p=START_PORT; p<=END_PORT; p++)); do
  if is_port_listening "$p"; then
    echo "[ERROR] Port already in use on system: $p"
    echo "[ERROR] Use --port-range-check <start_port> <count> before creation."
    exit 1
  fi
done

TMP_CFG="$(mktemp)"

if [[ "$PROTOCOL" == "http" ]]; then
  PROXY_BIN="proxy"
  PROTOCOL_LABEL="http"
  URI_SCHEME="http"
else
  PROXY_BIN="socks"
  PROTOCOL_LABEL="socks5"
  # socks5h tells clients to resolve DNS through the proxy, reducing DNS leaks.
  URI_SCHEME="socks5h"
fi

PUBLIC_IP="$(curl -4 -fsS ifconfig.me || true)"
HAS_PUBLIC_IP="0"
if [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  HAS_PUBLIC_IP="1"
fi

if [[ "$HAS_PUBLIC_IP" == "1" ]]; then
  OUTBOUND_BIND_OPT=" -e${PUBLIC_IP}"
  EXTERNAL_LINE="external ${PUBLIC_IP}"
  EXTERNAL_IP="$PUBLIC_IP"
else
  PUBLIC_IP="YOUR_SERVER_IP"
  OUTBOUND_BIND_OPT=""
  EXTERNAL_LINE=""
  EXTERNAL_IP=""
fi

if [[ -n "$EXPIRE_DAYS" ]]; then
  if ! [[ "$EXPIRE_DAYS" =~ ^[0-9]+$ ]] || [[ "$EXPIRE_DAYS" -le 0 ]]; then
    echo "[ERROR] --expire-days must be a positive integer."
    exit 1
  fi
  EXPIRES_EPOCH_GLOBAL=$(( $(date +%s) + EXPIRE_DAYS * 86400 ))
elif [[ -n "$EXPIRES_AT" ]]; then
  if ! EXPIRES_EPOCH_GLOBAL="$(date -d "$EXPIRES_AT" +%s 2>/dev/null)"; then
    echo "[ERROR] Invalid --expires-at value. Use a date format accepted by 'date -d'."
    exit 1
  fi
else
  EXPIRES_EPOCH_GLOBAL=0
fi

echo "[INFO] Updating package index..."
apt-get update -y

echo "[INFO] Installing dependencies..."
apt-get install -y 3proxy curl ufw openssl >/dev/null

if [[ "$HARDEN_OS" == "1" ]]; then
  apply_os_hardening "$DISABLE_IPV6_ON_HARDEN"
fi

mkdir -p "$CFG_DIR"

if [[ -f "$CFG_FILE" ]]; then
  BACKUP_FILE="$CFG_FILE.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$CFG_FILE" "$BACKUP_FILE"
  echo "[INFO] Existing config backed up to $BACKUP_FILE"
fi

render_config_from_db() {
  local db_file="$1"
  local settings_file="$2"
  local output_file="$3"
  local tmp_cfg
  local user_line
  local active_count
  local username
  local password
  local port
  local expires_epoch
  local status

  # shellcheck disable=SC1090
  source "$settings_file"

  tmp_cfg="$(mktemp)"
  {
    echo "daemon"
    echo "maxconn 2000"
    echo "nserver 1.1.1.1/tcp"
    echo "nserver 8.8.8.8/tcp"
    echo "nserver 9.9.9.9/tcp"
    echo "nscache 65536"
    echo "internal 0.0.0.0"
    if [[ -n "${EXTERNAL_IP}" ]]; then
      echo "external ${EXTERNAL_IP}"
    fi
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid 65535"
    echo "setuid 65535"
    echo "stacksize 6291456"
    echo "auth strong"
    echo
  } > "$tmp_cfg"

  user_line="users "
  active_count=0
  while IFS='|' read -r username password port expires_epoch status; do
    [[ -z "${username:-}" ]] && continue
    if [[ "$status" == "active" ]]; then
      user_line+="${username}:CL:${password} "
      active_count=$((active_count + 1))
    fi
  done < "$db_file"

  if [[ "$active_count" -eq 0 ]]; then
    user_line+="disabled:CL:disabled"
  fi

  echo "$user_line" >> "$tmp_cfg"
  echo >> "$tmp_cfg"

  while IFS='|' read -r username password port expires_epoch status; do
    [[ -z "${username:-}" ]] && continue
    if [[ "$status" == "active" ]]; then
      {
        echo "allow ${username} ${WHITELIST}"
        echo "${PROXY_BIN} -n -a -p${port} -i0.0.0.0${OUTBOUND_BIND_OPT}"
        echo "deny *"
        echo "flush"
        echo
      } >> "$tmp_cfg"
    fi
  done < "$db_file"

  if [[ "$active_count" -eq 0 ]]; then
    {
      echo "deny *"
      echo "flush"
      echo
    } >> "$tmp_cfg"
  fi

  mv "$tmp_cfg" "$output_file"
  chmod 600 "$output_file"
}

USER_LINE="users "
: > "$OUTPUT_CREDENTIALS"
: > "$OUTPUT_LIST"
: > "$DB_FILE"

declare -a USERNAMES
declare -a PASSWORDS
declare -A SEEN_USERNAMES

for ((i=0; i<PROXY_COUNT; i++)); do
  PORT=$((START_PORT + i))
  if [[ "$CREDENTIAL_MODE" == "manual" ]]; then
    while true; do
      read -r -p "Enter username for proxy on port ${PORT}: " USERNAME
      if [[ -z "$USERNAME" ]]; then
        echo "[WARN] Username cannot be empty."
        continue
      fi
      if [[ ! "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "[WARN] Username can contain only letters, numbers, _, ., -"
        continue
      fi
      if [[ -n "${SEEN_USERNAMES[$USERNAME]:-}" ]]; then
        echo "[WARN] Username already used in this batch. Use a unique one."
        continue
      fi
      SEEN_USERNAMES[$USERNAME]=1
      break
    done

    while true; do
      read -r -s -p "Enter password for ${USERNAME}: " PASSWORD
      echo
      read -r -s -p "Confirm password for ${USERNAME}: " PASSWORD_CONFIRM
      echo

      if [[ -z "$PASSWORD" ]]; then
        echo "[WARN] Password cannot be empty."
        continue
      fi
      if [[ "$PASSWORD" == *":"* || "$PASSWORD" == *" "* ]]; then
        echo "[WARN] Password cannot contain spaces or ':'"
        continue
      fi
      if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
        echo "[WARN] Passwords do not match. Try again."
        continue
      fi
      break
    done
  else
    USERNAME="${USER_PREFIX}$(printf '%03d' $((i + 1)))"
    PASSWORD="$(openssl rand -hex 6)"
  fi

  USERNAMES[$i]="$USERNAME"
  PASSWORDS[$i]="$PASSWORD"

  echo "${USERNAME}:${PASSWORD}:${PORT}" >> "$OUTPUT_CREDENTIALS"
  echo "${URI_SCHEME}://${USERNAME}:${PASSWORD}@${PUBLIC_IP}:${PORT}" >> "$OUTPUT_LIST"
  echo "${USERNAME}|${PASSWORD}|${PORT}|${EXPIRES_EPOCH_GLOBAL}|active" >> "$DB_FILE"

done

{
  printf "PROXY_BIN=%q\n" "$PROXY_BIN"
  printf "WHITELIST=%q\n" "$WHITELIST"
  printf "OUTBOUND_BIND_OPT=%q\n" "$OUTBOUND_BIND_OPT"
  printf "EXTERNAL_IP=%q\n" "$EXTERNAL_IP"
} > "$SETTINGS_FILE"
chmod 600 "$SETTINGS_FILE"

render_config_from_db "$DB_FILE" "$SETTINGS_FILE" "$CFG_FILE"

cat > "$EXPIRY_CHECK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CFG_DIR="/etc/3proxy"
CFG_FILE="$CFG_DIR/3proxy.cfg"
DB_FILE="$CFG_DIR/proxy-db.txt"
SETTINGS_FILE="$CFG_DIR/proxy-settings.env"

if [[ ! -f "$DB_FILE" || ! -f "$SETTINGS_FILE" ]]; then
  exit 0
fi

# shellcheck disable=SC1090
source "$SETTINGS_FILE"

render_config_from_db() {
  local db_file="$1"
  local output_file="$2"
  local tmp_cfg
  local user_line
  local active_count
  local username
  local password
  local port
  local expires_epoch
  local status

  tmp_cfg="$(mktemp)"
  {
    echo "daemon"
    echo "maxconn 2000"
    echo "nserver 1.1.1.1/tcp"
    echo "nserver 8.8.8.8/tcp"
    echo "nserver 9.9.9.9/tcp"
    echo "nscache 65536"
    echo "internal 0.0.0.0"
    if [[ -n "${EXTERNAL_IP}" ]]; then
      echo "external ${EXTERNAL_IP}"
    fi
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid 65535"
    echo "setuid 65535"
    echo "stacksize 6291456"
    echo "auth strong"
    echo
  } > "$tmp_cfg"

  user_line="users "
  active_count=0
  while IFS='|' read -r username password port expires_epoch status; do
    [[ -z "${username:-}" ]] && continue
    if [[ "$status" == "active" ]]; then
      user_line+="${username}:CL:${password} "
      active_count=$((active_count + 1))
    fi
  done < "$db_file"

  if [[ "$active_count" -eq 0 ]]; then
    user_line+="disabled:CL:disabled"
  fi

  echo "$user_line" >> "$tmp_cfg"
  echo >> "$tmp_cfg"

  while IFS='|' read -r username password port expires_epoch status; do
    [[ -z "${username:-}" ]] && continue
    if [[ "$status" == "active" ]]; then
      {
        echo "allow ${username} ${WHITELIST}"
        echo "${PROXY_BIN} -n -a -p${port} -i0.0.0.0${OUTBOUND_BIND_OPT}"
        echo "deny *"
        echo "flush"
        echo
      } >> "$tmp_cfg"
    fi
  done < "$db_file"

  if [[ "$active_count" -eq 0 ]]; then
    {
      echo "deny *"
      echo "flush"
      echo
    } >> "$tmp_cfg"
  fi

  mv "$tmp_cfg" "$output_file"
  chmod 600 "$output_file"
}

NOW_EPOCH="$(date +%s)"
CHANGED=0
TMP_DB="$(mktemp)"

while IFS='|' read -r username password port expires_epoch status; do
  [[ -z "${username:-}" ]] && continue
  new_status="$status"

  if [[ "$status" == "active" && "$expires_epoch" =~ ^[0-9]+$ && "$expires_epoch" -gt 0 && "$NOW_EPOCH" -ge "$expires_epoch" ]]; then
    new_status="expired"
    CHANGED=1
  fi

  echo "${username}|${password}|${port}|${expires_epoch}|${new_status}" >> "$TMP_DB"
done < "$DB_FILE"

if [[ "$CHANGED" -eq 1 ]]; then
  mv "$TMP_DB" "$DB_FILE"
  chmod 600 "$DB_FILE"
  render_config_from_db "$DB_FILE" "$CFG_FILE"
  systemctl restart 3proxy
else
  rm -f "$TMP_DB"
fi
EOF

chmod 700 "$EXPIRY_CHECK_SCRIPT"

cat > "$EXPIRY_SERVICE_FILE" <<EOF
[Unit]
Description=3proxy expiry check
After=network.target

[Service]
Type=oneshot
ExecStart=$EXPIRY_CHECK_SCRIPT
EOF

cat > "$EXPIRY_TIMER_FILE" <<EOF
[Unit]
Description=Run 3proxy expiry check every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true
AccuracySec=1m

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now 3proxy-expiry-check.timer >/dev/null 2>&1 || true

echo "[INFO] Enabling and restarting 3proxy service..."
systemctl enable 3proxy >/dev/null 2>&1 || true
systemctl restart 3proxy

if systemctl is-active --quiet 3proxy; then
  echo "[INFO] 3proxy is running."
else
  echo "[ERROR] 3proxy failed to start. Check: systemctl status 3proxy"
  exit 1
fi

if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -qi "Status: active"; then
    echo "[INFO] UFW is active. Opening port range ${START_PORT}:${END_PORT}/tcp..."
    ufw allow "${START_PORT}:${END_PORT}/tcp" >/dev/null
  fi
fi

echo
echo "[DONE] Proxies created successfully."
echo "Protocol:         ${PROTOCOL_LABEL}"
echo "Allowed source:   ${WHITELIST}"
echo "Credential mode:  ${CREDENTIAL_MODE}"
if [[ "$HARDEN_OS" == "1" ]]; then
  if [[ "$DISABLE_IPV6_ON_HARDEN" == "1" ]]; then
    echo "OS hardening:     enabled (IPv6 disabled)"
  else
    echo "OS hardening:     enabled (IPv6 kept)"
  fi
else
  echo "OS hardening:     disabled"
fi
echo "Credentials file:  ${OUTPUT_CREDENTIALS}"
echo "Proxy list file:   ${OUTPUT_LIST}"
echo "Proxy DB file:     ${DB_FILE}"
echo
echo "Format in ${OUTPUT_LIST}: ${URI_SCHEME}://USERNAME:PASSWORD@IP:PORT"
if [[ "$PROTOCOL" == "socks5" ]]; then
  echo "[INFO] SOCKS URIs use socks5h:// to route DNS through proxy."
fi
if [[ "$HAS_PUBLIC_IP" != "1" ]]; then
  echo "[WARN] Could not detect public IPv4. Replace YOUR_SERVER_IP in /root/proxy-list.txt"
fi
if [[ "$EXPIRES_EPOCH_GLOBAL" -gt 0 ]]; then
  echo "Expires at:        $(date -d "@${EXPIRES_EPOCH_GLOBAL}" '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Expiry timer:      systemctl status 3proxy-expiry-check.timer --no-pager"
else
  echo "Expires at:        never"
fi
