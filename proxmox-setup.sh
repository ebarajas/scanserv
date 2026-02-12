#!/usr/bin/env bash
# scanserv.sh — Run on the Proxmox host to create and configure an LXC container
#               that acts as a Brother scan-to-NAS bridge.
#
# Usage: bash scanserv.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.env"

# ── Helpers ───────────────────────────────────────────────
msg()  { echo -e "\e[1;32m==> $*\e[0m"; }
warn() { echo -e "\e[1;33m    WARN: $*\e[0m"; }
die()  { echo -e "\e[1;31mERROR: $*\e[0m" >&2; exit 1; }

# Prompt for a value with a default. Empty input accepts the default.
# Usage: ask VAR_NAME "Prompt text" "default_value"
ask() {
    local var="$1" prompt="$2" default="${3:-}"
    local input
    if [[ -n "$default" ]]; then
        read -rp "    $prompt [$default]: " input
        printf -v "$var" '%s' "${input:-$default}"
    else
        while true; do
            read -rp "    $prompt: " input
            if [[ -n "$input" ]]; then
                printf -v "$var" '%s' "$input"
                return
            fi
            echo "    (required)"
        done
    fi
}

# Prompt for a choice from a list. Returns the selected value.
# Usage: choose VAR_NAME "Prompt text" "opt1|opt2|opt3" "default"
choose() {
    local var="$1" prompt="$2" options_str="$3" default="${4:-}"
    IFS='|' read -ra options <<< "$options_str"
    echo "    $prompt"
    local i=1 default_idx=1
    for opt in "${options[@]}"; do
        [[ "$opt" == "$default" ]] && default_idx=$i
        echo "      $i) $opt"
        ((i++))
    done
    local input
    read -rp "    Choice [$default_idx]: " input
    input="${input:-$default_idx}"
    if [[ "$input" -ge 1 && "$input" -le "${#options[@]}" ]] 2>/dev/null; then
        printf -v "$var" '%s' "${options[$((input-1))]}"
    else
        printf -v "$var" '%s' "$default"
    fi
}

# ── Preflight checks ─────────────────────────────────────
command -v pct  >/dev/null || die "pct not found — this script must run on a Proxmox host."
command -v pveam >/dev/null || die "pveam not found — this script must run on a Proxmox host."

[[ -f "$SCRIPT_DIR/install.sh" ]] || die "install.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_DIR/scan.sh" ]]    || die "scan.sh not found in $SCRIPT_DIR"

# ── Interactive configuration ─────────────────────────────
echo ""
msg "Scanserv Setup"
echo ""

# -- Printer --
echo -e "\e[1;36m  Printer\e[0m"
ask PRINTER_IP    "Printer IP address" ""
ask PRINTER_MODEL "Printer model"      "MFC-L2717DW"
echo ""

# -- NAS --
echo -e "\e[1;36m  NAS\e[0m"
choose NAS_TYPE "Mount type:" "cifs|nfs" "cifs"
ask NAS_HOST  "NAS IP/hostname" ""
ask NAS_SHARE "Share name or export path" "scans"
if [[ "$NAS_TYPE" == "cifs" ]]; then
    ask NAS_USER "SMB username" "scanner"
    ask NAS_PASS "SMB password" ""
else
    NAS_USER=""
    NAS_PASS=""
fi
ask NAS_MOUNT "Mount path inside container" "/mnt/nas/scans"
echo ""

# -- Scan defaults --
echo -e "\e[1;36m  Scan Defaults\e[0m"
choose SCAN_RESOLUTION "Resolution:" "150|300|600" "300"
choose SCAN_MODE       "Color mode:" "Gray|Black & White|24bit Color" "Gray"
choose PAGE_SIZE       "Page size:"  "Letter|A4" "Letter"
case "$PAGE_SIZE" in
    Letter) SCAN_WIDTH="215.9"; SCAN_HEIGHT="279.4" ;;
    A4)     SCAN_WIDTH="210";   SCAN_HEIGHT="297" ;;
esac

# Button mapping — keep the sensible defaults, no need to prompt for these
BUTTON_FILE="adf"
BUTTON_IMAGE="flatbed"
BUTTON_EMAIL="duplex"
BUTTON_OCR="adf"
echo ""

# -- LXC container --
echo -e "\e[1;36m  LXC Container\e[0m"

# Auto-detect available storages
AVAIL_STORAGES=$(pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 && $2=="active" {print $1}' | head -5) || true
DEFAULT_STORAGE=$(echo "$AVAIL_STORAGES" | head -1)
DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"

AVAIL_TEMPLATE_STORAGES=$(pvesm status --content vztmpl 2>/dev/null \
    | awk 'NR>1 && $2=="active" {print $1}' | head -5) || true
DEFAULT_TEMPLATE_STORAGE=$(echo "$AVAIL_TEMPLATE_STORAGES" | head -1)
DEFAULT_TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-local}"

CT_ID=$(pvesh get /cluster/nextid 2>/dev/null) || CT_ID="100"
ask CT_ID        "Container ID"       "$CT_ID"
ask CT_HOSTNAME  "Hostname"           "scanserv"
ask CT_IP        "IP (or 'dhcp')"     "dhcp"
CT_GW=""
if [[ "$CT_IP" != "dhcp" ]]; then
    ask CT_GW "Gateway" ""
fi
ask CT_BRIDGE    "Network bridge"     "vmbr0"
ask CT_STORAGE   "Rootfs storage"     "$DEFAULT_STORAGE"
ask CT_TEMPLATE_STORAGE "Template storage" "$DEFAULT_TEMPLATE_STORAGE"
ask CT_MEMORY    "Memory (MB)"        "512"
ask CT_DISK      "Disk (GB)"          "4"
ask CT_CORES     "CPU cores"          "1"
echo ""

# ── Write config.env ─────────────────────────────────────
cat > "$CONFIG" <<EOF
PRINTER_IP="$PRINTER_IP"
PRINTER_MODEL="$PRINTER_MODEL"
NAS_TYPE="$NAS_TYPE"
NAS_HOST="$NAS_HOST"
NAS_SHARE="$NAS_SHARE"
NAS_USER="$NAS_USER"
NAS_PASS="$NAS_PASS"
NAS_MOUNT="$NAS_MOUNT"
SCAN_RESOLUTION="$SCAN_RESOLUTION"
SCAN_MODE="$SCAN_MODE"
SCAN_WIDTH="$SCAN_WIDTH"
SCAN_HEIGHT="$SCAN_HEIGHT"
BUTTON_FILE="$BUTTON_FILE"
BUTTON_IMAGE="$BUTTON_IMAGE"
BUTTON_EMAIL="$BUTTON_EMAIL"
BUTTON_OCR="$BUTTON_OCR"
CT_ID="$CT_ID"
CT_HOSTNAME="$CT_HOSTNAME"
CT_MEMORY="$CT_MEMORY"
CT_DISK="$CT_DISK"
CT_CORES="$CT_CORES"
CT_BRIDGE="$CT_BRIDGE"
CT_IP="$CT_IP"
CT_GW="$CT_GW"
CT_STORAGE="$CT_STORAGE"
CT_TEMPLATE_STORAGE="$CT_TEMPLATE_STORAGE"
EOF

msg "Config saved to $CONFIG"

# ── Confirm before proceeding ─────────────────────────────
echo ""
echo "    Printer:   $PRINTER_MODEL @ $PRINTER_IP"
echo "    NAS:       $NAS_TYPE://${NAS_HOST}/${NAS_SHARE} → $NAS_MOUNT"
echo "    Scan:      ${SCAN_RESOLUTION}dpi, $SCAN_MODE, $PAGE_SIZE"
echo "    Container: CT $CT_ID ($CT_HOSTNAME) on $CT_STORAGE — ${CT_MEMORY}MB/${CT_DISK}GB/${CT_CORES}cpu"
echo ""
read -rp "    Proceed? [Y/n]: " confirm
[[ "${confirm,,}" =~ ^(y|yes|)$ ]] || { echo "Aborted."; exit 0; }
echo ""

# ── Download Debian 12 template if needed ─────────────────
msg "Checking for Debian 12 template"
TEMPLATE=$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null \
    | awk '/debian-12.*amd64/ {print $1; exit}') || true

if [[ -z "$TEMPLATE" ]]; then
    msg "Downloading Debian 12 template"
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
    --unprivileged 0 \
    --features "nesting=1,mount=cifs;nfs" \
    --start 0

# ── Start container ──────────────────────────────────────
msg "Starting container"
pct start "$CT_ID"

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

pct push "$CT_ID" "$CONFIG"                  /etc/scanserv/config.env
pct push "$CT_ID" "$SCRIPT_DIR/scan.sh"      /etc/scanserv/scan.sh
pct push "$CT_ID" "$SCRIPT_DIR/install.sh"   /etc/scanserv/install.sh

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
