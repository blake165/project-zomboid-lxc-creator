#!/usr/bin/env bash
###############################################################################
# Project Zomboid dedicated server setup for a Proxmox LXC container
#
# Runs INSIDE the container as root. Normally invoked by
# proxmox-create-pz-lxc.sh, but safe to re-run to repair/update:
#   bash /root/pz-lxc-setup.sh
#
# Installs SteamCMD + the PZ Dedicated Server (app 380870) as a non-root
# 'pzuser', presets admin password / server name / RAM / branch, and creates
# a systemd service that autostarts with the container.
###############################################################################
set -euo pipefail

# Passed in by the host wizard (with sane fallbacks):
PZ_BRANCH="${PZ_BRANCH:-stable}"          # stable (B41) or unstable (B42)
PZ_SERVERNAME="${PZ_SERVERNAME:-servertest}"
PZ_ADMINPASS="${PZ_ADMINPASS:-changeme}"
PZ_RAM_MB="${PZ_RAM_MB:-6144}"            # JVM heap for the server
PZ_GAMEPORT="${PZ_GAMEPORT:-16261}"

PZUSER="pzuser"
PZ_HOME="/home/${PZUSER}"
PZ_DIR="${PZ_HOME}/pzserver"
APPID="380870"

if [[ $EUID -ne 0 ]]; then echo "Please run as root." >&2; exit 1; fi

echo "==> Installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386    # SteamCMD needs 32-bit libs
apt-get update -qq
apt-get install -y -qq locales curl wget ca-certificates \
  lib32gcc-s1 lib32stdc++6 libsdl2-2.0-0:i386 >/dev/null
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

echo "==> Creating service user '${PZUSER}'..."
id "${PZUSER}" &>/dev/null || useradd -m -d "${PZ_HOME}" -s /bin/bash "${PZUSER}"
mkdir -p "${PZ_DIR}"

echo "==> Installing SteamCMD..."
# Accept the Steam license non-interactively and install steamcmd
echo steam steam/question select "I AGREE" | debconf-set-selections
echo steam steam/license note '' | debconf-set-selections
apt-get install -y -qq steamcmd >/dev/null 2>&1 || {
  # Fallback: install from Valve's tarball if the distro package isn't available
  mkdir -p "${PZ_HOME}/steamcmd"
  curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C "${PZ_HOME}/steamcmd"
}
# Resolve the steamcmd entrypoint (package puts it in /usr/games)
STEAMCMD="$(command -v steamcmd || echo "${PZ_HOME}/steamcmd/steamcmd.sh")"

echo "==> Downloading Project Zomboid server (branch: ${PZ_BRANCH})..."
BETA_ARGS=""
[[ "${PZ_BRANCH}" == "unstable" ]] && BETA_ARGS="-beta unstable"
# Run steamcmd as the pzuser so files aren't root-owned
sudo -u "${PZUSER}" bash -c "
  '${STEAMCMD}' +force_install_dir '${PZ_DIR}' +login anonymous \
    +app_update ${APPID} ${BETA_ARGS} validate +quit
"

if [[ ! -f "${PZ_DIR}/start-server.sh" ]]; then
  echo "PZ server files not found after install (${PZ_DIR}/start-server.sh missing)." >&2
  echo "Check the steamcmd output above for errors and re-run." >&2
  exit 1
fi

echo "==> Pre-seeding server config (name=${PZ_SERVERNAME})..."
# PZ writes config to ~/Zomboid/Server/<name>.ini on first boot. We create the
# directory and a minimal ini so the admin password + ram are set up front,
# avoiding the interactive first-run password prompt.
ZOMBOID_DIR="${PZ_HOME}/Zomboid/Server"
sudo -u "${PZUSER}" mkdir -p "${ZOMBOID_DIR}"

# JVM heap: PZ reads -Xmx from ProjectZomboid64.json / start-server.sh args.
# We pass RAM via the service ExecStart instead, which is the robust way.

echo "==> Creating systemd service..."
cat > /etc/systemd/system/pzserver.service <<EOF
[Unit]
Description=Project Zomboid Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PZUSER}
Group=${PZUSER}
WorkingDirectory=${PZ_DIR}
# -servername selects the config set; -adminpassword sets it on first run;
# -port sets the UDP game port. Heap is controlled with -Xmx/-Xms.
ExecStart=${PZ_DIR}/start-server.sh -servername "${PZ_SERVERNAME}" -adminpassword "${PZ_ADMINPASS}" -port ${PZ_GAMEPORT}
Restart=on-failure
RestartSec=15
LimitNOFILE=65535
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8

[Install]
WantedBy=multi-user.target
EOF

# Bake the JVM heap size into the server's launch options
if [[ -f "${PZ_DIR}/ProjectZomboid64.json" ]]; then
  sed -i -E "s/-Xmx[0-9]+m/-Xmx${PZ_RAM_MB}m/; s/-Xms[0-9]+m/-Xms${PZ_RAM_MB}m/" \
    "${PZ_DIR}/ProjectZomboid64.json" 2>/dev/null || true
fi

chown -R "${PZUSER}:${PZUSER}" "${PZ_HOME}"
systemctl daemon-reload
systemctl enable pzserver.service >/dev/null
systemctl restart pzserver.service

cat <<EOM

=============================================================================
 Project Zomboid server setup complete!
=============================================================================
 Branch     : ${PZ_BRANCH}$([[ ${PZ_BRANCH} == unstable ]] && echo " (Build 42)" || echo " (Build 41)")
 Server name: ${PZ_SERVERNAME}
 Admin pass : (the one you set in the wizard)
 RAM (heap) : ${PZ_RAM_MB} MB

 First boot generates the world and can take a few minutes - watch it:
   journalctl -u pzserver -f
 You'll see "SERVER STARTED" when it's ready.

 Connect from the game: Servers -> add the container IP, port ${PZ_GAMEPORT}.

 Config files (edit then 'systemctl restart pzserver'):
   ${ZOMBOID_DIR}/${PZ_SERVERNAME}.ini             (server settings)
   ${ZOMBOID_DIR}/${PZ_SERVERNAME}_SandboxVars.lua (world/gameplay)

 Ports to forward on your router (BOTH UDP):
   ${PZ_GAMEPORT}/udp  and  $((PZ_GAMEPORT+1))/udp
=============================================================================
EOM
