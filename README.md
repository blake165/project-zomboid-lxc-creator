# Project Zomboid Dedicated Server LXC for Proxmox — one-command install

Spin up a Proxmox LXC running a [Project Zomboid](https://projectzomboid.com/)
dedicated server with a single pasted command. An interactive wizard handles
container creation, SteamCMD, the PZ server install, your admin password, RAM,
and Build 41 vs Build 42 selection.

## Usage

Paste into the **Proxmox node shell** (as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/project-zomboid-lxc-creator/main/proxmox-create-pz-lxc.sh)"
```

The wizard asks for container settings, then PZ settings (build, server name,
RAM, admin password), then:

- downloads the Debian 12 LXC template (if missing)
- creates + starts an unprivileged container (autostart on boot)
- installs SteamCMD + the PZ Dedicated Server (Steam app `380870`) as a
  non-root `pzuser`
- presets your server name, admin password, JVM heap, and game branch
- creates a systemd service so the server survives reboots
- prints the connect IP/port when done

First boot generates the world (a few minutes) — watch with
`pct exec <CTID> -- journalctl -u pzserver -f` and wait for **SERVER STARTED**.

## Build 41 vs Build 42

Project Zomboid's **Build 42** is the current major version but is still on the
**unstable** Steam branch. The wizard lets you pick:

- **b42** (unstable) — newest features; recommended for a fresh server in 2026
- **b41** (stable) — older, rock-solid

Build 41 saves/mods are **not** compatible with Build 42 — pick one and build
your world on it from the start. A fresh container avoids the known Build 42
"Thread-0" error that comes from mixing old saves with the new branch.

## Settings the wizard sets

| Prompt | Default | Notes |
|---|---|---|
| Container ID | `140` | unused (FiveM 110, Minecraft 130 — no clash) |
| Hostname | `zomboid` | |
| CPU cores | `4` | PZ is single-thread heavy — high clock beats many cores |
| Container memory | `8192` MB | |
| Disk | `30` GB | the explored map grows over time |
| Network | `dhcp` | or static `IP/CIDR` + gateway |
| Container root password | — | prompted, hidden |
| SSH root login | `yes` | for uploading mods / editing config |
| Game build | `b42` | or `b41` |
| Server name | `servertest` | names the config set |
| Server RAM (heap) | `6144` MB | keep below container memory |
| Game UDP port | `16261` | |
| Admin password | — | in-game admin panel password (prompted, hidden) |

### Scripted install

```bash
NONINTERACTIVE=1 \
CTID=141 MEMORY=12288 PZ_RAM_MB=8192 \
PZ_BRANCH=unstable PZ_SERVERNAME=knox PZ_GAMEPORT=16261 \
CT_ROOT_PASSWORD='root-pass' PZ_ADMINPASS='admin-pass' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-projectzomboid-lxc-for-proxmox/main/proxmox-create-pz-lxc.sh)"
```

## Connecting

In-game: **Servers → add server →** the container's IP and port `16261`.

## Ports (both UDP!)

Forward on your router to the container IP:

- `16261/udp` — game
- `16262/udp` — Steam integration

PZ traffic is UDP — forwarding TCP does nothing. Set a DHCP reservation (or
static IP) so the container address stays put.

## Config & mods

Server settings live in (edit, then restart the service):

```
/home/pzuser/Zomboid/Server/<servername>.ini
/home/pzuser/Zomboid/Server/<servername>_SandboxVars.lua
```

```bash
pct exec <CTID> -- systemctl restart pzserver
```

Workshop mods: add their Workshop IDs and Mod IDs to the `.ini`
(`WorkshopItems=` and `Mods=`), then restart — the server downloads them on
next boot.

## RAM guidance

~4GB minimum, plus roughly 100–200MB per player and per large mod. A 16-player
modded server wants 6–8GB of heap. Set the heap below the container's total
memory so the OS has headroom.

## Updating the server

```bash
pct exec <CTID> -- bash /root/pz-lxc-setup.sh
```
Re-runs SteamCMD (updates the server files) and restarts the service.
