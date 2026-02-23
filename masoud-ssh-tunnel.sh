#!/usr/bin/env bash
# ==========================================================
#   Masoud SSH Tunnel Manager v3.4 (Single-file Installer+Manager)
#   Author: Masoud
#   https://github.com/masooooood
# ==========================================================

set -o igncr 2>/dev/null || true
set -euo pipefail

VERSION="3.4"

APP="masoud-ssh"
BASE_DIR="/etc/masoud-ssh-tunnel"
CONF_DIR="${BASE_DIR}/tunnels"
GLOBAL_CONF="${BASE_DIR}/global.conf"
FORWARD_SCRIPT="/usr/local/bin/masoud-ssh-forward.sh"
KEY_PATH="/root/.ssh/masoud_ssh_key"

# Raw URL of THIS script in your repo:
UPDATE_URL_DEFAULT="https://raw.githubusercontent.com/masooooood/Masoud-SSH-Tunnel/main/masoud-ssh-tunnel.sh"

TTY="/dev/tty"

# ---------- Safe input from keyboard (works even with curl|bash) ----------
read_tty() {
  local prompt="${1:-}"
  local __var="${2:-REPLY}"
  local default="${3:-}"
  local input=""

  if [[ -r "$TTY" ]]; then
    printf "%s" "$prompt" > "$TTY"
    IFS= read -r input < "$TTY" || true
  else
    IFS= read -r -p "$prompt" input || true
  fi

  if [[ -z "$input" && -n "$default" ]]; then
    input="$default"
  fi

  printf -v "$__var" '%s' "$input"
}

pause() { read_tty "Press Enter..." _ ""; }

banner() {
  # clear only if we have a tty
  if [[ -t 1 ]]; then clear || true; fi
  echo "=================================================="
  echo "  Masoud SSH Tunnel Manager v${VERSION}"
  echo "  https://github.com/masooooood"
  echo "=================================================="
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root."
    exit 1
  fi
}

# ---------- Choose install path robustly ----------
choose_install_path() {
  # prefer /usr/local/bin, then /usr/bin, then ~/.local/bin
  if [[ -d /usr/local/bin ]] && [[ -w /usr/local/bin ]]; then
    echo "/usr/local/bin/${APP}"
    return
  fi
  if [[ -d /usr/bin ]] && [[ -w /usr/bin ]]; then
    echo "/usr/bin/${APP}"
    return
  fi
  mkdir -p "${HOME}/.local/bin" 2>/dev/null || true
  echo "${HOME}/.local/bin/${APP}"
}

INSTALL_PATH="$(choose_install_path)"

# ---------- Dependencies ----------
install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt update -y >/dev/null 2>&1 || true
  apt install -y autossh openssh-client curl >/dev/null 2>&1
}

# ---------- Files/dirs ----------
init_dirs() { mkdir -p "$BASE_DIR" "$CONF_DIR"; }

# ---------- Global defaults ----------
load_global() {
  KHAREJ_IP_DEFAULT=""
  SSH_PORT_DEFAULT="22"
  UPDATE_URL="$UPDATE_URL_DEFAULT"

  if [[ -f "$GLOBAL_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$GLOBAL_CONF" || true
  fi
}

save_global() {
  cat > "$GLOBAL_CONF" <<EOF
# Masoud SSH Tunnel Manager global defaults
KHAREJ_IP_DEFAULT="${KHAREJ_IP_DEFAULT}"
SSH_PORT_DEFAULT="${SSH_PORT_DEFAULT}"
UPDATE_URL="${UPDATE_URL}"
EOF
}

set_global_menu() {
  load_global
  echo "Current default Kharej IP: ${KHAREJ_IP_DEFAULT:-<empty>}"
  read_tty "Enter default Kharej IP (empty=keep): " ip ""
  [[ -n "${ip}" ]] && KHAREJ_IP_DEFAULT="$ip"

  echo "Current default SSH Port: ${SSH_PORT_DEFAULT:-22}"
  read_tty "Enter default SSH Port (empty=keep): " p ""
  [[ -n "${p}" ]] && SSH_PORT_DEFAULT="$p"

  echo "Update URL (raw script url):"
  echo "  ${UPDATE_URL}"
  read_tty "Enter new Update URL (empty=keep): " u ""
  [[ -n "${u}" ]] && UPDATE_URL="$u"

  save_global
  echo "Saved."
  pause
}

# ---------- SSH key ----------
ensure_key() {
  if [[ ! -f "$KEY_PATH" ]]; then
    echo "Generating SSH key at: $KEY_PATH"
    ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" >/dev/null
  fi
}

# ---------- Forward script ----------
write_forward_script() {
  cat > "$FORWARD_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${KHAREJ_IP:?missing KHAREJ_IP}"
: "${SSH_PORT:?missing SSH_PORT}"
: "${KEY_PATH:?missing KEY_PATH}"
: "${PORTS:?missing PORTS}"

LARGS=()
for p in ${PORTS}; do
  LARGS+=("-L" "0.0.0.0:${p}:127.0.0.1:${p}")
done

exec autossh -M 0 -N \
  -o ServerAliveInterval=20 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -i "${KEY_PATH}" \
  -p "${SSH_PORT}" \
  "${LARGS[@]}" \
  "root@${KHAREJ_IP}"
EOF
  chmod +x "$FORWARD_SCRIPT"
}

# ---------- Validation ----------
is_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}
trim_spaces() { echo "${1//[[:space:]]/}"; }

parse_ports() {
  local raw parts part start end i
  raw="$(trim_spaces "$1")"
  [[ -z "$raw" ]] && return 1

  IFS=',' read -ra parts <<< "$raw"
  declare -A seen=()
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    if [[ "$part" == *"-"* ]]; then
      start="${part%-*}"
      end="${part#*-}"
      if ! is_port "$start" || ! is_port "$end" || (( 10#$start > 10#$end )); then
        echo "INVALID"; return 2
      fi
      for ((i=10#$start;i<=10#$end;i++)); do seen["$i"]=1; done
    else
      if ! is_port "$part"; then echo "INVALID"; return 2; fi
      seen["$part"]=1
    fi
  done
  printf "%s\n" "${!seen[@]}" | sort -n | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# ---------- systemd helpers ----------
svc_name() { echo "masoud-ssh-tunnel-$1.service"; }
tunnel_conf() { echo "${CONF_DIR}/$1.conf"; }
reload_systemd() { systemctl daemon-reload; }

write_service() {
  local name="$1"
  local service="/etc/systemd/system/$(svc_name "$name")"
  local envfile; envfile="$(tunnel_conf "$name")"

  cat > "$service" <<EOF
[Unit]
Description=Masoud SSH Tunnel ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${envfile}
ExecStart=${FORWARD_SCRIPT}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ---------- Self install + re-exec (works from file OR curl|bash pipe) ----------
install_self_and_reexec() {
  # If already running from install path -> ok
  local src=""
  src="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
  if [[ -n "$src" && "$src" == "$INSTALL_PATH" ]]; then
    return
  fi

  # If we have a real file -> copy
  if [[ -n "$src" && -f "$src" && -r "$src" ]]; then
    cp -f "$src" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    exec "$INSTALL_PATH"
  fi

  # Pipe/stdin mode -> download from URL
  echo "Installing to: $INSTALL_PATH"
  echo "Downloading from: $UPDATE_URL_DEFAULT"
  curl -fsSL "$UPDATE_URL_DEFAULT" | tr -d '\r' > "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  exec "$INSTALL_PATH"
}

# ---------- Update system ----------
get_latest_version() {
  load_global
  curl -fsSL "$UPDATE_URL" 2>/dev/null | tr -d '\r' | grep -m1 '^VERSION=' | cut -d'"' -f2 || true
}
version_gt() {
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
}
check_updates_menu() {
  load_global
  echo "Checking updates..."
  local latest; latest="$(get_latest_version)"
  [[ -z "$latest" ]] && { echo "Could not fetch latest version."; pause; return; }
  echo "Current: $VERSION"
  echo "Latest : $latest"
  if version_gt "$latest" "$VERSION"; then echo "Update available ✅"; else echo "You are up to date ✅"; fi
  pause
}
update_now_menu() {
  load_global
  echo "Updating from:"
  echo "  $UPDATE_URL"
  curl -fsSL "$UPDATE_URL" | tr -d '\r' > "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  echo "Updated. Re-launching..."
  exec "$INSTALL_PATH"
}

# ---------- SSH key copy/test ----------
ssh_copy_id_menu() {
  load_global
  read_tty "Kharej IP (default: ${KHAREJ_IP_DEFAULT:-none}): " ip ""
  ip="${ip:-$KHAREJ_IP_DEFAULT}"
  [[ -z "$ip" ]] && { echo "Kharej IP is empty."; pause; return; }

  read_tty "SSH Port (default: ${SSH_PORT_DEFAULT:-22}): " port ""
  port="${port:-$SSH_PORT_DEFAULT}"
  is_port "$port" || { echo "Invalid port."; pause; return; }

  ensure_key
  echo "Copying key to root@${ip}:${port} ..."
  ssh-copy-id -i "${KEY_PATH}.pub" -p "$port" "root@${ip}"
  echo "Done."
  pause
}

ssh_test_menu() {
  load_global
  read_tty "Kharej IP (default: ${KHAREJ_IP_DEFAULT:-none}): " ip ""
  ip="${ip:-$KHAREJ_IP_DEFAULT}"
  [[ -z "$ip" ]] && { echo "Kharej IP is empty."; pause; return; }

  read_tty "SSH Port (default: ${SSH_PORT_DEFAULT:-22}): " port ""
  port="${port:-$SSH_PORT_DEFAULT}"
  is_port "$port" || { echo "Invalid port."; pause; return; }

  ensure_key
  echo "Testing SSH..."
  ssh -i "$KEY_PATH" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${ip}" "echo OK"
  pause
}

# ---------- Create tunnel ----------
create_tunnel_menu() {
  load_global
  echo "Create Tunnel"
  echo "------------"
  read_tty "Tunnel name (example: t1): " name ""
  name="$(trim_spaces "$name")"
  [[ -z "$name" ]] && { echo "Name is empty."; pause; return; }

  if [[ -f "$(tunnel_conf "$name")" ]] || systemctl list-unit-files | grep -q "^$(svc_name "$name")"; then
    echo "Tunnel name already exists."
    pause
    return
  fi

  read_tty "Kharej IP (default: ${KHAREJ_IP_DEFAULT:-none}): " ip ""
  ip="${ip:-$KHAREJ_IP_DEFAULT}"
  [[ -z "$ip" ]] && { echo "Kharej IP is empty."; pause; return; }

  read_tty "SSH Port (default: ${SSH_PORT_DEFAULT:-22}): " port ""
  port="${port:-$SSH_PORT_DEFAULT}"
  is_port "$port" || { echo "Invalid SSH port."; pause; return; }

  echo "Ports examples: 6000 | 6000,7000 | 60000-60070 | 60000-60070,20000,2088"
  read_tty "Enter ports: " pinput ""
  local ports; ports="$(parse_ports "$pinput" || true)"
  [[ -z "$ports" || "$ports" == "INVALID" ]] && { echo "Invalid ports input."; pause; return; }

  ensure_key

  cat > "$(tunnel_conf "$name")" <<EOF
KHAREJ_IP="${ip}"
SSH_PORT="${port}"
KEY_PATH="${KEY_PATH}"
PORTS="${ports}"
EOF

  write_service "$name"
  reload_systemd
  systemctl enable --now "$(svc_name "$name")"
  echo "Created and started: $(svc_name "$name")"
  pause
}

# ---------- List ----------
list_tunnels_menu() {
  echo "Tunnels:"
  echo "--------"
  local any=0
  for f in "${CONF_DIR}"/*.conf; do
    [[ -e "$f" ]] || continue
    any=1
    local name svc st
    name="$(basename "$f" .conf)"
    svc="$(svc_name "$name")"
    st="$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")"
    echo "- $name  [$st]"
  done
  [[ "$any" -eq 0 ]] && echo "No tunnels created."
  pause
}

# ---------- Monitor ----------
count_conns_for_ports() {
  local ports="$1" total=0 p
  for p in $ports; do
    local c
    c="$(ss -nt state established "( sport = :$p )" 2>/dev/null | tail -n +2 | wc -l || true)"
    total=$((total + c))
  done
  echo "$total"
}

monitor_tunnel_menu() {
  read_tty "Tunnel name: " name ""
  name="$(trim_spaces "$name")"
  [[ -z "$name" || ! -f "$(tunnel_conf "$name")" ]] && { echo "Tunnel not found."; pause; return; }

  local svc; svc="$(svc_name "$name")"
  echo "Service: $svc"
  systemctl status "$svc" --no-pager || true

  # shellcheck disable=SC1090
  source "$(tunnel_conf "$name")" || true
  echo ""
  echo "Kharej: ${KHAREJ_IP}:${SSH_PORT}"
  echo "Ports : ${PORTS}"
  echo "ESTABLISHED connections (sum): $(count_conns_for_ports "$PORTS")"
  pause
}

# ---------- Logs ----------
logs_tunnel_menu() {
  read_tty "Tunnel name: " name ""
  name="$(trim_spaces "$name")"
  local svc; svc="$(svc_name "$name")"
  journalctl -u "$svc" -n 120 --no-pager || true
  pause
}

# ---------- Start/Stop/Restart ----------
service_action_menu() {
  read_tty "Tunnel name: " name ""
  name="$(trim_spaces "$name")"
  [[ -z "$name" || ! -f "$(tunnel_conf "$name")" ]] && { echo "Tunnel not found."; pause; return; }
  local svc; svc="$(svc_name "$name")"

  echo "1) Start"
  echo "2) Stop"
  echo "3) Restart"
  echo "4) Enable (boot)"
  echo "5) Disable (boot)"
  read_tty "Select: " c ""

  case "$c" in
    1) systemctl start "$svc" ;;
    2) systemctl stop "$svc" ;;
    3) systemctl restart "$svc" ;;
    4) systemctl enable "$svc" ;;
    5) systemctl disable "$svc" ;;
    *) echo "Invalid." ;;
  esac
  pause
}

# ---------- Edit ----------
edit_tunnel_menu() {
  read_tty "Tunnel name: " name ""
  name="$(trim_spaces "$name")"
  local cf; cf="$(tunnel_conf "$name")"
  [[ -z "$name" || ! -f "$cf" ]] && { echo "Tunnel not found."; pause; return; }

  echo "Editing: $cf"
  echo "After save, service will be restarted."
  pause
  ${EDITOR:-nano} "$cf"

  reload_systemd
  systemctl restart "$(svc_name "$name")"
  echo "Restarted."
  pause
}

# ---------- Delete ----------
delete_tunnel_menu() {
  read_tty "Tunnel name: " name ""
  name="$(trim_spaces "$name")"
  local cf svc
  cf="$(tunnel_conf "$name")"
  svc="$(svc_name "$name")"
  [[ -z "$name" || ! -f "$cf" ]] && { echo "Tunnel not found."; pause; return; }

  read_tty "Are you sure delete '$name'? (y/N): " yn "N"
  [[ "${yn,,}" != "y" ]] && { echo "Canceled."; pause; return; }

  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/$svc" "$cf"
  reload_systemd
  echo "Deleted."
  pause
}

# ---------- Backup/Restore ----------
backup_menu() {
  local out="/root/masoud-ssh-tunnel-backup-$(date +%F-%H%M%S).tar.gz"
  tar -czf "$out" "$BASE_DIR" "/etc/systemd/system" --wildcards "*masoud-ssh-tunnel-*.service" 2>/dev/null || true
  echo "Backup saved: $out"
  pause
}

restore_menu() {
  read_tty "Backup file path (.tar.gz): " fp ""
  [[ ! -f "$fp" ]] && { echo "File not found."; pause; return; }

  tar -xzf "$fp" -C / 2>/dev/null || true
  reload_systemd

  for f in "${CONF_DIR}"/*.conf; do
    [[ -e "$f" ]] || continue
    local name svc
    name="$(basename "$f" .conf)"
    svc="$(svc_name "$name")"
    systemctl enable --now "$svc" 2>/dev/null || true
  done
  echo "Restore done."
  pause
}

# ---------- Uninstall ----------
uninstall_menu() {
  read_tty "Uninstall ALL tunnels and remove manager? (y/N): " yn "N"
  [[ "${yn,,}" != "y" ]] && { echo "Canceled."; pause; return; }

  for f in "${CONF_DIR}"/*.conf; do
    [[ -e "$f" ]] || continue
    local name svc
    name="$(basename "$f" .conf)"
    svc="$(svc_name "$name")"
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc" 2>/dev/null || true
    rm -f "$f" 2>/dev/null || true
  done

  rm -f "$FORWARD_SCRIPT" 2>/dev/null || true
  rm -rf "$BASE_DIR" 2>/dev/null || true
  systemctl daemon-reload
  rm -f "$INSTALL_PATH" 2>/dev/null || true

  echo "Uninstalled."
  exit 0
}

# ---------- Main menu ----------
main_menu() {
  while true; do
    banner
    echo "1) Set Defaults (Kharej IP / SSH Port / Update URL)"
    echo "2) SSH: Copy Key to Kharej (ssh-copy-id)"
    echo "3) SSH: Test Connection"
    echo "------------------------------------------"
    echo "4) Create Tunnel"
    echo "5) List Tunnels"
    echo "6) Tunnel: Start/Stop/Restart/Enable/Disable"
    echo "7) Tunnel: Status + Connections"
    echo "8) Tunnel: Logs"
    echo "9) Tunnel: Edit"
    echo "10) Tunnel: Delete"
    echo "------------------------------------------"
    echo "11) Backup"
    echo "12) Restore"
    echo "------------------------------------------"
    echo "13) Check Updates"
    echo "14) Update Now"
    echo "------------------------------------------"
    echo "15) Uninstall"
    echo "0) Exit"
    echo ""

    read_tty "Select: " ch ""
    case "$ch" in
      1) set_global_menu ;;
      2) ssh_copy_id_menu ;;
      3) ssh_test_menu ;;
      4) create_tunnel_menu ;;
      5) list_tunnels_menu ;;
      6) service_action_menu ;;
      7) monitor_tunnel_menu ;;
      8) logs_tunnel_menu ;;
      9) edit_tunnel_menu ;;
      10) delete_tunnel_menu ;;
      11) backup_menu ;;
      12) restore_menu ;;
      13) check_updates_menu ;;
      14) update_now_menu ;;
      15) uninstall_menu ;;
      0) exit 0 ;;
      *) echo "Invalid."; sleep 1 ;;
    esac
  done
}

# ---------- Run ----------
need_root
init_dirs
install_deps
write_forward_script
ensure_key
install_self_and_reexec
main_menu
