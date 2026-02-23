#!/usr/bin/env bash
# ==========================================================
#   Masoud SSH Tunnel Manager v3.1 (Single-file Installer+Manager)
#   Author: Masoud
#   https://github.com/masooooood
# ==========================================================

set -euo pipefail

VERSION="3.1"
APP="masoud-ssh"
INSTALL_PATH="/usr/local/bin/${APP}"
BASE_DIR="/etc/masoud-ssh-tunnel"
CONF_DIR="${BASE_DIR}/tunnels"
GLOBAL_CONF="${BASE_DIR}/global.conf"
FORWARD_SCRIPT="/usr/local/bin/masoud-ssh-forward.sh"
KEY_PATH="/root/.ssh/masoud_ssh_key"

# ---------- UI ----------
banner() {
  clear || true
  echo "=================================================="
  echo "  Masoud SSH Tunnel Manager v${VERSION}"
  echo "  https://github.com/masooooood"
  echo "=================================================="
}

pause() { read -r -p "Press Enter... " _ || true; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root."
    exit 1
  fi
}

# ---------- Self install + re-exec (auto run without typing masoud-ssh) ----------
install_self_and_reexec() {
  local src
  src="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  # If the script is run via process substitution (bash <(curl ...)),
  # $0 is like /dev/fd/63; copying that file works.
  cp -f "$src" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"

  # If we are not already running from installed path, re-exec it.
  # This ensures all future operations use the installed copy.
  if [[ "$src" != "$INSTALL_PATH" ]]; then
    exec "$INSTALL_PATH"
  fi
}

# ---------- Dependencies ----------
install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt update -y >/dev/null 2>&1 || true
  apt install -y autossh openssh-client >/dev/null 2>&1
}

# ---------- Files/dirs ----------
init_dirs() {
  mkdir -p "$BASE_DIR" "$CONF_DIR"
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

# ---------- Global defaults ----------
load_global() {
  KHAREJ_IP_DEFAULT=""
  SSH_PORT_DEFAULT="22"

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
EOF
}

set_global_menu() {
  load_global
  echo "Current Kharej IP default: ${KHAREJ_IP_DEFAULT:-<empty>}"
  read -r -p "Enter default Kharej IP (leave empty to keep): " ip || true
  if [[ -n "${ip}" ]]; then KHAREJ_IP_DEFAULT="$ip"; fi

  echo "Current SSH Port default: ${SSH_PORT_DEFAULT:-22}"
  read -r -p "Enter default SSH Port (enter to keep): " p || true
  if [[ -n "${p}" ]]; then SSH_PORT_DEFAULT="$p"; fi

  save_global
  echo "Saved."
  pause
}

# ---------- Validation ----------
is_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

trim_spaces() {
  local s="$1"
  s="${s//[[:space:]]/}"
  echo "$s"
}

# Parse input: single | multi | range | mixed
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
      if ! is_port "$start" || ! is_port "$end" || (( start > end )); then
        echo "INVALID"
        return 2
      fi
      for ((i=start;i<=end;i++)); do
        seen["$i"]=1
      done
    else
      if ! is_port "$part"; then
        echo "INVALID"
        return 2
      fi
      seen["$part"]=1
    fi
  done

  printf "%s\n" "${!seen[@]}" | sort -n | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# ---------- systemd helpers ----------
svc_name() { echo "masoud-ssh-tunnel-$1.service"; }
tunnel_conf() { echo "${CONF_DIR}/$1.conf"; }

write_service() {
  local name="$1"
  local service="/etc/systemd/system/$(svc_name "$name")"
  local envfile
  envfile="$(tunnel_conf "$name")"

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

reload_systemd() { systemctl daemon-reload; }

# ---------- SSH key copy/test ----------
ssh_copy_id_menu() {
  load_global
  read -r -p "Kharej IP (default: ${KHAREJ_IP_DEFAULT:-none}): " ip || true
  ip="${ip:-$KHAREJ_IP_DEFAULT}"
  if [[ -z "$ip" ]]; then echo "Kharej IP is empty."; pause; return; fi

  read -r -p "SSH Port (default: ${SSH_PORT_DEFAULT:-22}): " port || true
  port="${port:-$SSH_PORT_DEFAULT}"
  if ! is_port "$port"; then echo "Invalid port."; pause; return; fi

  ensure_key
  echo "Copying SSH key to root@${ip}:${port} ..."
  ssh-copy-id -i "${KEY_PATH}.pub" -p "$port" "root@${ip}"
  echo "Done."
  pause
}

ssh_test_menu() {
  load_global
  read -r -p "Kharej IP (default: ${KHAREJ_IP_DEFAULT:-none}): " ip || true
  ip="${ip:-$KHAREJ_IP_DEFAULT}"
  if [[ -z "$ip" ]]; then echo "Kharej IP is empty."; pause; return; fi

  read -r -p "SSH Port (default: ${SSH_PORT_DEFAULT:-22}): " port || true
  port="${port:-$SSH_PORT_DEFAULT}"
  if ! is_port "$port"; then echo "Invalid port."; pause; return; fi

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
  read -r -p "Tunnel name (example: t1): " name || true
  name="$(trim_spaces "$name")"
  if [[ -z "$name" ]]; then echo "Name is empty."; pause; return; fi

  if [[ -f "$(tunnel_conf "$name")" ]] || systemctl list-unit-files | grep -q "^$(svc_name "$name")"; then
    echo "Tunnel name already exists."
    pause
    return
  fi

  read -r -p "Kharej IP (default: ${KHAREJ_IP_DEFAULT:-none}): " ip || true
  ip="${ip:-$KHAREJ_IP_DEFAULT}"
  if [[ -z "$ip" ]]; then echo "Kharej IP is empty."; pause; return; fi

  read -r -p "SSH Port (default: ${SSH_PORT_DEFAULT:-22}): " port || true
  port="${port:-$SSH_PORT_DEFAULT}"
  if ! is_port "$port"; then echo "Invalid SSH port."; pause; return; fi

  echo "Ports input examples:"
  echo "  single: 6000"
  echo "  multi : 60000,20000,2088"
  echo "  range : 60000-60070"
  echo "  mixed : 60000-60070,20000,2088"
  read -r -p "Enter ports: " pinput || true
  local ports
  ports="$(parse_ports "$pinput" || true)"
  if [[ -z "$ports" || "$ports" == "INVALID" ]]; then
    echo "Invalid ports input."
    pause
    return
  fi

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

# ---------- List tunnels ----------
list_tunnels_menu() {
  echo "Tunnels:"
  echo "--------"
  local any=0
  for f in "${CONF_DIR}"/*.conf; do
    [[ -e "$f" ]] || continue
    any=1
    local name
    name="$(basename "$f" .conf)"
    local svc
    svc="$(svc_name "$name")"
    local st
    st="$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")"
    echo "- $name  [$st]"
  done
  [[ "$any" -eq 0 ]] && echo "No tunnels created."
  pause
}

# ---------- Status/monitor ----------
count_conns_for_ports() {
  local ports="$1"
  local total=0
  local p
  for p in $ports; do
    local c
    c="$(ss -nt state established "( sport = :$p )" 2>/dev/null | tail -n +2 | wc -l || true)"
    total=$((total + c))
  done
  echo "$total"
}

monitor_tunnel_menu() {
  read -r -p "Tunnel name: " name || true
  name="$(trim_spaces "$name")"
  if [[ -z "$name" ]] || [[ ! -f "$(tunnel_conf "$name")" ]]; then
    echo "Tunnel not found."
    pause
    return
  fi

  local svc
  svc="$(svc_name "$name")"

  echo "Service: $svc"
  systemctl status "$svc" --no-pager || true

  # shellcheck disable=SC1090
  source "$(tunnel_conf "$name")" || true
  echo ""
  echo "Kharej: ${KHAREJ_IP}:${SSH_PORT}"
  echo "Ports : ${PORTS}"
  echo "ESTABLISHED connections (sum on local ports): $(count_conns_for_ports "$PORTS")"
  pause
}

# ---------- Logs ----------
logs_tunnel_menu() {
  read -r -p "Tunnel name: " name || true
  name="$(trim_spaces "$name")"
  local svc
  svc="$(svc_name "$name")"
  journalctl -u "$svc" -n 120 --no-pager || true
  pause
}

# ---------- Start/Stop/Restart ----------
service_action_menu() {
  read -r -p "Tunnel name: " name || true
  name="$(trim_spaces "$name")"
  if [[ -z "$name" ]] || [[ ! -f "$(tunnel_conf "$name")" ]]; then
    echo "Tunnel not found."
    pause
    return
  fi
  local svc
  svc="$(svc_name "$name")"

  echo "1) Start"
  echo "2) Stop"
  echo "3) Restart"
  echo "4) Enable (boot)"
  echo "5) Disable (boot)"
  read -r -p "Select: " c || true

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
  read -r -p "Tunnel name: " name || true
  name="$(trim_spaces "$name")"
  local cf
  cf="$(tunnel_conf "$name")"
  if [[ -z "$name" ]] || [[ ! -f "$cf" ]]; then
    echo "Tunnel not found."
    pause
    return
  fi

  echo "Editing: $cf"
  echo "After editing, service will be restarted."
  pause

  ${EDITOR:-nano} "$cf"

  reload_systemd
  systemctl restart "$(svc_name "$name")"
  echo "Restarted."
  pause
}

# ---------- Delete ----------
delete_tunnel_menu() {
  read -r -p "Tunnel name: " name || true
  name="$(trim_spaces "$name")"
  local cf svc
  cf="$(tunnel_conf "$name")"
  svc="$(svc_name "$name")"

  if [[ -z "$name" ]] || [[ ! -f "$cf" ]]; then
    echo "Tunnel not found."
    pause
    return
  fi

  read -r -p "Are you sure delete '$name'? (y/N): " yn || true
  if [[ "${yn,,}" != "y" ]]; then
    echo "Canceled."
    pause
    return
  fi

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
  read -r -p "Backup file path (.tar.gz): " fp || true
  if [[ ! -f "$fp" ]]; then
    echo "File not found."
    pause
    return
  fi
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
  read -r -p "Uninstall ALL tunnels and remove manager? (y/N): " yn || true
  if [[ "${yn,,}" != "y" ]]; then
    echo "Canceled."
    pause
    return
  fi

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
    echo "1) Set Defaults (Kharej IP / SSH Port)"
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
    echo "13) Uninstall"
    echo "0) Exit"
    echo ""
    read -r -p "Select: " ch || true

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
      13) uninstall_menu ;;
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

# Install + auto run from installed binary (no need to type masoud-ssh after install)
install_self_and_reexec

# If we are already running from /usr/local/bin/masoud-ssh, continue:
main_menu