#!/usr/bin/env bash
###############################################################################
# Project Zomboid dedicated server LXC - automated provisioning for Proxmox
#
# One-liner from the Proxmox node shell (root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/project-zomboid-lxc-creator/main/proxmox-create-pz-lxc.sh)"
#
# Creates an LXC, installs SteamCMD + the PZ dedicated server inside it, sets it
# to autostart, and pre-seeds your server name, admin password, RAM, and branch.
#
# Prompts ask for CTID, resources, network, branch, server name + admin pass.
# Skip prompts:  NONINTERACTIVE=1 CT_ROOT_PASSWORD=x PZ_ADMINPASS=y bash -c "$(curl ...)"
###############################################################################
set -euo pipefail

# ----------------------------- configurable ---------------------------------
CTID="${CTID:-140}"
HOSTNAME="${HOSTNAME_CT:-zomboid}"
CORES="${CORES:-4}"                       # PZ is single-thread heavy; clock > cores
MEMORY="${MEMORY:-8192}"                  # MB container RAM
SWAP="${SWAP:-2048}"
DISK_GB="${DISK_GB:-30}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"

IP_CONFIG="${IP_CONFIG:-dhcp}"            # or static, e.g. 192.168.1.70/24
GATEWAY="${GATEWAY:-}"

CT_ROOT_PASSWORD="${CT_ROOT_PASSWORD:-}"
ENABLE_SSH_ROOT="${ENABLE_SSH_ROOT:-1}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# Project Zomboid settings
PZ_BRANCH="${PZ_BRANCH:-unstable}"        # unstable=Build42 (current), stable=Build41
PZ_SERVERNAME="${PZ_SERVERNAME:-servertest}"
PZ_ADMINPASS="${PZ_ADMINPASS:-}"
PZ_RAM_MB="${PZ_RAM_MB:-6144}"            # JVM heap (leave headroom under MEMORY)
PZ_GAMEPORT="${PZ_GAMEPORT:-16261}"

RAW_BASE="https://raw.githubusercontent.com/blake165/project-zomboid-lxc-creator/main"
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then echo "Run as root on the Proxmox host." >&2; exit 1; fi
if ! command -v pct &>/dev/null; then echo "pct not found - is this a Proxmox host?" >&2; exit 1; fi

# Locate or download the container setup script
LOCAL_SETUP="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")" 2>/dev/null)/pz-lxc-setup.sh"
if [[ -f "${LOCAL_SETUP}" ]]; then
  SETUP_SCRIPT="${LOCAL_SETUP}"
  echo "==> Using local pz-lxc-setup.sh"
else
  SETUP_SCRIPT="$(mktemp /tmp/pz-lxc-setup.XXXXXX.sh)"
  echo "==> Downloading pz-lxc-setup.sh from ${RAW_BASE}..."
  if ! curl -fsSL -o "${SETUP_SCRIPT}" "${RAW_BASE}/pz-lxc-setup.sh"; then
    echo "Failed to download pz-lxc-setup.sh - check RAW_BASE in this script." >&2
    exit 1
  fi
fi

# --------------------------- interactive wizard -----------------------------
ask() { local q="$1" def="$2" ans; read -r -p "  ${q} [${def}]: " ans </dev/tty; echo "${ans:-$def}"; }

if [[ "${NONINTERACTIVE}" != "1" && -e /dev/tty ]]; then
  echo ""
  echo "============================================"
  echo "   Project Zomboid LXC - interactive setup"
  echo "============================================"
  echo "Press Enter to accept the [default] value."
  echo ""

  while :; do
    CTID=$(ask "Container ID" "${CTID}")
    if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then echo "  ! Must be a number."
    elif pct status "${CTID}" &>/dev/null; then echo "  ! CTID ${CTID} is already in use, pick another."
    else break; fi
  done

  HOSTNAME=$(ask "Hostname" "${HOSTNAME}")
  CORES=$(ask "CPU cores (PZ likes high clock over many cores)" "${CORES}")
  MEMORY=$(ask "Container memory (MB)" "${MEMORY}")
  DISK_GB=$(ask "Disk size (GB)" "${DISK_GB}")
  STORAGE=$(ask "Storage for container disk" "${STORAGE}")
  BRIDGE=$(ask "Network bridge" "${BRIDGE}")

  NET_CHOICE=$(ask "Network: dhcp or static?" "$([[ ${IP_CONFIG} == dhcp ]] && echo dhcp || echo static)")
  if [[ "${NET_CHOICE}" == "static" ]]; then
    while :; do
      IP_CONFIG=$(ask "Static IP with CIDR (e.g. 192.168.1.70/24)" "$([[ ${IP_CONFIG} == dhcp ]] && echo '' || echo "${IP_CONFIG}")")
      [[ "${IP_CONFIG}" =~ ^[0-9.]+/[0-9]+$ ]] && break
      echo "  ! Format must be IP/prefix, e.g. 192.168.1.70/24"
    done
    while :; do
      GATEWAY=$(ask "Gateway (e.g. 192.168.1.1)" "${GATEWAY}")
      [[ -n "${GATEWAY}" ]] && break
      echo "  ! Gateway is required for a static IP."
    done
  else
    IP_CONFIG="dhcp"; GATEWAY=""
  fi

  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    while :; do
      read -r -s -p "  Container root password: " PW1 </dev/tty; echo
      read -r -s -p "  Confirm password: " PW2 </dev/tty; echo
      if [[ -z "${PW1}" ]]; then echo "  ! Password cannot be empty."
      elif [[ "${PW1}" != "${PW2}" ]]; then echo "  ! Passwords do not match, try again."
      else CT_ROOT_PASSWORD="${PW1}"; break; fi
    done
  fi

  SSH_CHOICE=$(ask "Enable SSH root login (for mods/config edits)? (yes/no)" "yes")
  [[ "${SSH_CHOICE}" =~ ^[Yy] ]] && ENABLE_SSH_ROOT=1 || ENABLE_SSH_ROOT=0

  echo ""
  echo "  -- Project Zomboid settings --"
  BRANCH_CHOICE=$(ask "Game build: 'b42' (unstable, current) or 'b41' (stable)?" "$([[ ${PZ_BRANCH} == unstable ]] && echo b42 || echo b41)")
  [[ "${BRANCH_CHOICE}" == "b41" ]] && PZ_BRANCH="stable" || PZ_BRANCH="unstable"

  PZ_SERVERNAME=$(ask "Server name (config set name)" "${PZ_SERVERNAME}")
  PZ_RAM_MB=$(ask "Server RAM / JVM heap (MB) - keep below container memory" "${PZ_RAM_MB}")
  PZ_GAMEPORT=$(ask "Game UDP port" "${PZ_GAMEPORT}")

  if [[ -z "${PZ_ADMINPASS}" ]]; then
    while :; do
      read -r -s -p "  In-game admin password: " AP1 </dev/tty; echo
      read -r -s -p "  Confirm admin password: " AP2 </dev/tty; echo
      if [[ -z "${AP1}" ]]; then echo "  ! Admin password cannot be empty."
      elif [[ "${AP1}" != "${AP2}" ]]; then echo "  ! Passwords do not match, try again."
      else PZ_ADMINPASS="${AP1}"; break; fi
    done
  fi

  echo ""
  echo "--------------------------------------------"
  echo "  CTID       : ${CTID}"
  echo "  Hostname   : ${HOSTNAME}"
  echo "  Cores      : ${CORES}"
  echo "  Memory     : ${MEMORY} MB (server heap ${PZ_RAM_MB} MB)"
  echo "  Disk       : ${DISK_GB} GB on ${STORAGE}"
  echo "  Network    : ${BRIDGE}, ${IP_CONFIG}${GATEWAY:+ gw ${GATEWAY}}"
  echo "  SSH root   : $([[ ${ENABLE_SSH_ROOT} == 1 ]] && echo enabled || echo disabled)"
  echo "  PZ build   : $([[ ${PZ_BRANCH} == unstable ]] && echo 'Build 42 (unstable)' || echo 'Build 41 (stable)')"
  echo "  PZ server  : ${PZ_SERVERNAME}, UDP ${PZ_GAMEPORT}"
  echo "--------------------------------------------"
  CONFIRM=$(ask "Create this container? (yes/no)" "yes")
  [[ "${CONFIRM}" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  echo ""
else
  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    echo "Non-interactive mode: set CT_ROOT_PASSWORD env var." >&2; exit 1
  fi
  if [[ -z "${PZ_ADMINPASS}" ]]; then
    echo "Non-interactive mode: set PZ_ADMINPASS env var." >&2; exit 1
  fi
fi
# -----------------------------------------------------------------------------

if pct status "${CTID}" &>/dev/null; then
  echo "CTID ${CTID} already exists. Pick a free ID." >&2; exit 1
fi

echo "==> Checking for Debian 12 template..."
pveam update >/dev/null
TEMPLATE=$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | awk '/debian-12-standard/ {print $1; exit}')
if [[ -z "${TEMPLATE}" ]]; then
  TEMPLATE_NAME=$(pveam available --section system | awk '/debian-12-standard/ {print $2; exit}')
  [[ -z "${TEMPLATE_NAME}" ]] && { echo "No debian-12-standard template available." >&2; exit 1; }
  echo "    Downloading ${TEMPLATE_NAME}..."
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_NAME}"
  TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
fi
echo "    Using template: ${TEMPLATE}"

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG}"
if [[ "${IP_CONFIG}" != "dhcp" ]]; then
  [[ -z "${GATEWAY}" ]] && { echo "Static IP set but GATEWAY is empty." >&2; exit 1; }
  NET0+=",gw=${GATEWAY}"
fi

echo "==> Creating container ${CTID} (${HOSTNAME})..."
pct create "${CTID}" "${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "${NET0}" \
  --unprivileged 1 \
  --features nesting=1 \
  --password "${CT_ROOT_PASSWORD}" \
  --onboot 1

echo "==> Starting container..."
pct start "${CTID}"

echo "==> Waiting for network inside the container..."
for i in $(seq 1 30); do
  pct exec "${CTID}" -- ping -c1 -W2 deb.debian.org &>/dev/null && break
  sleep 2
  [[ $i -eq 30 ]] && { echo "Container never got network access." >&2; exit 1; }
done

if [[ "${ENABLE_SSH_ROOT}" == "1" ]]; then
  echo "==> Enabling SSH root login..."
  pct exec "${CTID}" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-pz-root.conf
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  "
fi

echo "==> Pushing and running PZ setup script (SteamCMD download is large)..."
pct push "${CTID}" "${SETUP_SCRIPT}" /root/pz-lxc-setup.sh
pct exec "${CTID}" -- env \
  PZ_BRANCH="${PZ_BRANCH}" \
  PZ_SERVERNAME="${PZ_SERVERNAME}" \
  PZ_ADMINPASS="${PZ_ADMINPASS}" \
  PZ_RAM_MB="${PZ_RAM_MB}" \
  PZ_GAMEPORT="${PZ_GAMEPORT}" \
  bash /root/pz-lxc-setup.sh

CT_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')

cat <<EOM

=============================================================================
 Container ${CTID} provisioned successfully!
=============================================================================
 PZ server : ${CT_IP}:${PZ_GAMEPORT}  (add this in-game under Servers)
 Build     : $([[ ${PZ_BRANCH} == unstable ]] && echo 'Build 42 (unstable)' || echo 'Build 41 (stable)')
 Root login: 'pct enter ${CTID}' or console
EOM
[[ "${ENABLE_SSH_ROOT}" == "1" ]] && echo " SSH       : ssh root@${CT_IP}  (password you chose in the wizard)"
cat <<EOM

 First boot generates the world - watch it come up:
   pct exec ${CTID} -- journalctl -u pzserver -f
   (wait for "SERVER STARTED")

 Forward on your router for outside players - BOTH UDP:
   ${PZ_GAMEPORT}/udp  and  $((PZ_GAMEPORT+1))/udp
 Set a DHCP reservation (or static IP) so ${CT_IP} doesn't change.

 Edit settings: /home/pzuser/Zomboid/Server/${PZ_SERVERNAME}.ini
 then: pct exec ${CTID} -- systemctl restart pzserver
=============================================================================
EOM
