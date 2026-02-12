#!/usr/bin/env bash
# scanserv.sh — Run on the Proxmox host to create and configure an LXC container
#               that acts as a Brother scan-to-NAS bridge.
#
# Usage:
#   1. Edit config.env with your printer IP, NAS details, etc.
#   2. Run: bash scanserv.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.env"

# ── Helpers ───────────────────────────────────────────────
msg()  { echo -e "\e[1;32m==> $*\e[0m"; }
warn() { echo -e "\e[1;33m    WARN: $*\e[0m"; }
die()  { echo -e "\e[1;31mERROR: $*\e[0m" >&2; exit 1; }

# ── Preflight checks ─────────────────────────────────────
[[ -f "$CONFIG" ]] || die "Config not found: $CONFIG\nCopy config.env.example to config.env and edit it."
# shellcheck source=/dev/null
source "$CONFIG"

command -v pct  >/dev/null || die "pct not found — this script must run on a Proxmox host."
command -v pveam >/dev/null || die "pveam not found — this script must run on a Proxmox host."

[[ -f "$SCRIPT_DIR/install.sh" ]] || die "install.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_DIR/scan.sh" ]]    || die "scan.sh not found in $SCRIPT_DIR"

# ── Resolve container ID ─────────────────────────────────
if [[ "$CT_ID" == "auto" ]]; then
    CT_ID=$(pvesh get /cluster/nextid)
    msg "Auto-selected CT ID: $CT_ID"
fi

# ── Download Debian 12 template if needed ─────────────────
msg "Checking for Debian 12 template"
TEMPLATE=$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null \
    | awk '/debian-12.*amd64/ {print $1; exit}') || true

if [[ -z "$TEMPLATE" ]]; then
    msg "Downloading Debian 12 template"
    # Find the latest available Debian 12 template
    TEMPLATE_NAME=$(pveam available --section system \
        | awk '/debian-12.*amd64/ {print $2; exit}')
    [[ -n "$TEMPLATE_NAME" ]] || die "No Debian 12 template found in available images"
    pveam download "$CT_TEMPLATE_STORAGE" "$TEMPLATE_NAME"
    TEMPLATE="${CT_TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
else
    msg "Using existing template: $TEMPLATE"
fi

# ── Build network string ─────────────────────────────────
NET_STR="name=eth0,bridge=${CT_BRIDGE}"
if [[ "$CT_IP" == "dhcp" ]]; then
    NET_STR="${NET_STR},ip=dhcp"
else
    NET_STR="${NET_STR},ip=${CT_IP}"
    [[ -n "$CT_GW" ]] && NET_STR="${NET_STR},gw=${CT_GW}"
fi

# ── Create LXC container ─────────────────────────────────
msg "Creating LXC container $CT_ID ($CT_HOSTNAME)"
pct create "$CT_ID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --memory "$CT_MEMORY" \
    --cores "$CT_CORES" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "$NET_STR" \
    --unprivileged 1 \
    --features nesting=1 \
    --start 0

# ── Start container ──────────────────────────────────────
msg "Starting container"
pct start "$CT_ID"

# Wait for container to be fully up
echo -n "    Waiting for container to boot"
for _ in $(seq 1 30); do
    if pct exec "$CT_ID" -- test -f /etc/os-release 2>/dev/null; then
        echo " ready"
        break
    fi
    echo -n "."
    sleep 1
done

# ── Push files into the container ─────────────────────────
msg "Copying files into container"
pct exec "$CT_ID" -- mkdir -p /etc/scanserv

pct push "$CT_ID" "$SCRIPT_DIR/config.env"  /etc/scanserv/config.env
pct push "$CT_ID" "$SCRIPT_DIR/scan.sh"     /etc/scanserv/scan.sh
pct push "$CT_ID" "$SCRIPT_DIR/install.sh"  /etc/scanserv/install.sh

pct exec "$CT_ID" -- chmod 755 /etc/scanserv/install.sh /etc/scanserv/scan.sh

# ── Run installation ─────────────────────────────────────
msg "Running installation inside container"
pct exec "$CT_ID" -- bash /etc/scanserv/install.sh

# ── Done ─────────────────────────────────────────────────
CT_ACTUAL_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}') || true

echo ""
msg "Container $CT_ID ($CT_HOSTNAME) is ready!"
echo ""
echo "    Container ID:  $CT_ID"
echo "    Hostname:      $CT_HOSTNAME"
[[ -n "${CT_ACTUAL_IP:-}" ]] && echo "    IP address:    $CT_ACTUAL_IP"
echo "    NAS mount:     $NAS_MOUNT"
echo ""
echo "    Shell into it:       pct enter $CT_ID"
echo "    Check service:       pct exec $CT_ID -- systemctl status scanserv"
echo "    Follow scan logs:    pct exec $CT_ID -- journalctl -t scanserv -f"
echo ""
echo "    Walk up to the printer, press Scan → File, and select '$CT_HOSTNAME'."
