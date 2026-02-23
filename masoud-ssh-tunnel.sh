#!/usr/bin/env bash
# ==========================================================
#  Masoud SSH Tunnel Manager (Stable Edition)
#  Author: Masoud | https://github.com/masooooood
# ==========================================================
# Notes:
# - Does NOT run apt automatically (avoids hanging).
# - Has a menu option to install dependencies if you want.
# - Reads input from /dev/tty (stable even when installed via curl|bash).
# ==========================================================

set -euo pipefail

APP_NAME="masoud-ssh"
INSTALL_PATH="/usr/local/bin/masoud-ssh"

BASE_DIR="/etc/masoud-ssh-tunnel"
TUN_DIR="${BASE_DIR}/tunnels"

KEY_PATH="/root/.ssh/masoud_ssh_key"
FWD_SCRIPT="/usr/local/bin/masoud-ssh-forward.sh"
SERVICE_TMPL="/etc/systemd/system/masoud-ssh-tunnel@.service"

TTY="/dev/tty"

# -------------------- TTY Safe Input --------------------
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
  clear >/dev/null 2>&1 || true
  echo "=================================================="
  echo " Masoud SSH Tunnel Manager (Stable Edition)"
  echo " https://github.com/masooooood"
  echo "=================================================="
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# -------------------- Install (no apt by default) --------------------
install_self_hint() {
  # This script is intended to be installed by:
  # curl ... | tr -d '\r' | tee /usr/local/bin/masoud-ssh >/dev/null && chmod +x /usr/local/bin/masoud-ssh
  :
}

install_deps_apt() {
  export DEBIAN_FRONTEND=noninteractive

  echo "Installing dependencies via apt..."
  echo "If apt is locked or repos are slow, you can cancel with Ctrl+C."
  echo ""

  if have_cmd timeout; then
    timeout 180 apt update -y || true
    timeout 180 apt install -y autossh openssh-client curl nano || true
  else
    apt update -y || true
    apt install -y autossh openssh-client curl nano || true
  fi

  echo ""
  if have_cmd autossh; then
    echo "✅ autossh installed."
  else
    echo "❌ autossh still not installed."
    echo "Try manually:"
    echo "  apt update && apt install -y autossh"
  fi
  pause
}

# -------------------- Files/dirs --------------------
init_dirs() { mkdir -p "$BASE_DIR" "$TUN_DIR"; }

ensure_key() {
  if [[ ! -f "$KEY_PATH" ]]; then
    echo "Generating SSH key: $KEY_PATH"
    mkdir -p /root/.ssh
    ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" >/dev/null
  fi
}

# -------------------- Port parsing --------------------
is_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

trim_spaces() { echo "${1//[[:space:]]/}"; }

# supports: 6000 | 6000,7000 | 60000-60070 | 60000-60070,20000,2088
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

# -------------------- Forward script --------------------
ensure_forward_script() {
  cat > "$FWD_SCRIPT" <<'EOF'
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
  chmod +x "$FWD_SCRIPT"
}

# -------------------- systemd template --------------------
ensure_service_template() {
  cat > "$SERVICE_TMPL" <<EOF
[Unit]
Description=Masoud SSH Tunnel #%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${TUN_DIR}/tunnel-%i.conf
ExecStart=${FWD_SCRIPT}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

svc_name() { echo "masoud-ssh-tunnel@${1}.service"; }
conf_path() { echo "${TUN_DIR}/tunnel-${1}.conf"; }

# -------------------- Helpers --------------------
require_autossh_or_warn() {
  if ! have_cmd autossh; then
    echo "WARNING: autossh is not installed."
    echo "Go to menu: Install Dependencies (apt)"
    echo "Or install manually:"
    echo "  apt update && apt install -y autossh"
    echo ""
  fi
}

copy_key_menu() {
  ensure_key
  read_tty "Kharej IP: " ip ""
  ip="$(trim_spaces "$ip")"
  [[ -z "$ip" ]] && { echo "IP is empty."; pause; return; }

  read_tty "SSH Port (default 22): " port "22"
  port="$(trim_spaces "$port")"
  is_port "$port" || { echo "Invalid port."; pause; return; }

  echo "Copying key to root@${ip}:${port} ..."
  ssh-copy-id -i "${KEY_PATH}.pub" -p "$port" "root@${ip}"
  echo "Done."
  pause
}

# -------------------- Create/Manage --------------------
create_tunnel() {
  require_autossh_or_warn

  read_tty "Tunnel number (مثلا 1): " N ""
  N="$(trim_spaces "$N")"
  [[ -z "$N" || ! "$N" =~ ^[0-9]+$ ]] && { echo "Invalid number."; pause; return; }

  local cf; cf="$(conf_path "$N")"
  if [[ -f "$cf" ]]; then
    read_tty "Tunnel $N exists. Overwrite? (y/N): " yn "N"
    [[ "${yn,,}" != "y" ]] && { echo "Canceled."; pause; return; }
  fi

  read_tty "Kharej IP: " ip ""
  ip="$(trim_spaces "$ip")"
  [[ -z "$ip" ]] && { echo "IP is empty."; pause; return; }

  read_tty "SSH Port (default 22): " port "22"
  port="$(trim_spaces "$port")"
  is_port "$port" || { echo "Invalid SSH port."; pause; return; }

  echo "Ports examples:"
  echo "  single : 6000"
  echo "  multi  : 60000,20000,2088"
  echo "  range  : 60000-60070"
  echo "  mixed  : 60000-60070,20000,2088"
  read_tty "Ports: " pinput ""
  local ports; ports="$(parse_ports "$pinput" || true)"
  [[ -z "$ports" || "$ports" == "INVALID" ]] && { echo "Invalid ports."; pause; return; }

  ensure_key
  ensure_forward_script
  ensure_service_template
  init_dirs

  cat > "$cf" <<EOF
KHAREJ_IP="${ip}"
SSH_PORT="${port}"
KEY_PATH="${KEY_PATH}"
PORTS="${ports}"
EOF

  systemctl enable --now "$(svc_name "$N")" || true

  echo ""
  echo "✅ Created: $cf"
  echo "Service : $(svc_name "$N")"
  echo "Status  : systemctl status $(svc_name "$N") --no-pager"
  pause
}

list_tunnels() {
  echo "Tunnels:"
  echo "--------"
  local found=0
  for f in "${TUN_DIR}"/tunnel-*.conf; do
    [[ -e "$f" ]] || continue
    found=1
    local n; n="$(basename "$f" | sed -E 's/^tunnel-([0-9]+)\.conf$/\1/')"
    local st; st="$(systemctl is-active "$(svc_name "$n")" 2>/dev/null || echo "unknown")"
    echo "- Tunnel $n  [$st]"
  done
  [[ "$found" -eq 0 ]] && echo "No tunnels."
  pause
}

manage_tunnel() {
  read_tty "Tunnel number: " N ""
  N="$(trim_spaces "$N")"
  [[ -z "$N" || ! "$N" =~ ^[0-9]+$ ]] && { echo "Invalid number."; pause; return; }

  local cf; cf="$(conf_path "$N")"
  if [[ ! -f "$cf" ]]; then
    echo "Tunnel $N not found."
    pause
    return
  fi

  while true; do
    clear >/dev/null 2>&1 || true
    echo "=== Tunnel #$N ==="
    echo "Config : $cf"
    echo "Service: $(svc_name "$N")"
    echo "--------------------------------"
    echo "1) Status"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Restart"
    echo "5) Logs"
    echo "6) Edit (nano) + restart"
    echo "7) Delete"
    echo "0) Back"
    echo ""
    read_tty "Select: " c ""

    case "$c" in
      1) systemctl status "$(svc_name "$N")" --no-pager || true; pause ;;
      2) systemctl start "$(svc_name "$N")" || true; echo "Started."; pause ;;
      3) systemctl stop "$(svc_name "$N")" || true; echo "Stopped."; pause ;;
      4) systemctl restart "$(svc_name "$N")" || true; echo "Restarted."; pause ;;
      5) journalctl -u "$(svc_name "$N")" -n 120 --no-pager || true; pause ;;
      6)
        nano "$cf"
        systemctl restart "$(svc_name "$N")" || true
        echo "Edited + restarted."
        pause
        ;;
      7)
        read_tty "Delete tunnel #$N ? (y/N): " yn "N"
        if [[ "${yn,,}" == "y" ]]; then
          systemctl stop "$(svc_name "$N")" 2>/dev/null || true
          systemctl disable "$(svc_name "$N")" 2>/dev/null || true
          rm -f "$cf"
          systemctl daemon-reload
          echo "Deleted."
          pause
          return
        fi
        ;;
      0) return ;;
      *) echo "Invalid."; sleep 1 ;;
    esac
  done
}

uninstall_all() {
  read_tty "Remove ALL tunnels & files? (y/N): " yn "N"
  [[ "${yn,,}" != "y" ]] && { echo "Canceled."; pause; return; }

  for f in "${TUN_DIR}"/tunnel-*.conf; do
    [[ -e "$f" ]] || continue
    local n; n="$(basename "$f" | sed -E 's/^tunnel-([0-9]+)\.conf$/\1/')"
    systemctl stop "$(svc_name "$n")" 2>/dev/null || true
    systemctl disable "$(svc_name "$n")" 2>/dev/null || true
    rm -f "$f"
  done

  rm -f "$SERVICE_TMPL" "$FWD_SCRIPT"
  rm -rf "$BASE_DIR"
  systemctl daemon-reload

  echo "Uninstalled."
  pause
}

# -------------------- Main --------------------
main() {
  need_root
  init_dirs
  ensure_key
  ensure_forward_script
  ensure_service_template

  while true; do
    banner
    echo "1) Create Tunnel"
    echo "2) Manage Tunnel "
    echo "3) List Tunnels"
    echo "4) SSH Copy Key "
    echo "5) Install Dependencies (apt) "
    echo "6) Uninstall All"
    echo "0) Exit"
    echo ""

    read_tty "Select: " ch ""

    case "$ch" in
      1) create_tunnel ;;
      2) manage_tunnel ;;
      3) list_tunnels ;;
      4) copy_key_menu ;;
      5) install_deps_apt ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) echo "Invalid."; sleep 1 ;;
    esac
  done
}

main

