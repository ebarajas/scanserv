#!/usr/bin/env bash
# install.sh — runs inside the LXC container to install and configure everything.
set -euo pipefail

CONFIG="/etc/scanserv/config.env"
[[ -f "$CONFIG" ]] || { echo "ERROR: $CONFIG not found"; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

BRSCAN4_URL="https://download.brother.com/welcome/dlf105200/brscan4-0.4.11-1.amd64.deb"
BRSCAN_SKEY_URL="https://download.brother.com/pub/com/linux/linux/packages/brscan-skey-0.3.2-0.amd64.deb"

echo "==> Updating packages"
apt-get update -qq
apt-get install -y -qq sane-utils libtiff-tools curl

# NAS mount dependencies
case "$NAS_TYPE" in
    cifs) apt-get install -y -qq cifs-utils ;;
    nfs)  apt-get install -y -qq nfs-common ;;
esac

# ── Brother drivers ──────────────────────────────────────
echo "==> Installing Brother brscan4 driver"
TMPDIR=$(mktemp -d)
curl -fsSL -o "$TMPDIR/brscan4.deb" "$BRSCAN4_URL"
curl -fsSL -o "$TMPDIR/brscan-skey.deb" "$BRSCAN_SKEY_URL"
dpkg -i --force-all "$TMPDIR/brscan4.deb" "$TMPDIR/brscan-skey.deb" || true
apt-get install -f -y -qq
rm -rf "$TMPDIR"

# ── Register scanner ────────────────────────────────────
echo "==> Registering scanner at $PRINTER_IP"
brsaneconfig4 -a name="$PRINTER_MODEL" model="$PRINTER_MODEL" ip="$PRINTER_IP"

# ── NAS mount ────────────────────────────────────────────
echo "==> Configuring NAS mount ($NAS_TYPE)"
mkdir -p "$NAS_MOUNT"

# Remove any previous scanserv fstab entry
sed -i '/# scanserv/d' /etc/fstab

case "$NAS_TYPE" in
    cifs)
        CRED_FILE="/etc/scanserv/.nascredentials"
        mkdir -p "$(dirname "$CRED_FILE")"
        cat > "$CRED_FILE" <<EOF
username=$NAS_USER
password=$NAS_PASS
EOF
        chmod 600 "$CRED_FILE"
        echo "//${NAS_HOST}/${NAS_SHARE} ${NAS_MOUNT} cifs credentials=${CRED_FILE},x-systemd.automount,vers=3.0,uid=0,gid=0,iocharset=utf8,_netdev 0 0 # scanserv" \
            >> /etc/fstab
        ;;
    nfs)
        echo "${NAS_HOST}:/${NAS_SHARE} ${NAS_MOUNT} nfs defaults,x-systemd.automount,_netdev 0 0 # scanserv" \
            >> /etc/fstab
        ;;
esac

systemctl daemon-reload
mount "$NAS_MOUNT" || echo "WARN: NAS mount failed — verify NAS settings and retry with 'mount $NAS_MOUNT'"

# ── Install scan script ─────────────────────────────────
echo "==> Installing scan handler"
mkdir -p /opt/scanserv
cp /etc/scanserv/scan.sh /opt/scanserv/scan.sh
chmod 755 /opt/scanserv/scan.sh

# ── Configure brscan-skey ────────────────────────────────
echo "==> Configuring brscan-skey"
SKEY_CONFIG="/opt/brother/scanner/brscan-skey/brscan-skey.config"
if [[ -f "$SKEY_CONFIG" ]]; then
    cp "$SKEY_CONFIG" "${SKEY_CONFIG}.bak"
fi
mkdir -p "$(dirname "$SKEY_CONFIG")"
cat > "$SKEY_CONFIG" <<EOF
FILE="bash /opt/scanserv/scan.sh ${BUTTON_FILE}"
IMAGE="bash /opt/scanserv/scan.sh ${BUTTON_IMAGE}"
EMAIL="bash /opt/scanserv/scan.sh ${BUTTON_EMAIL}"
OCR="bash /opt/scanserv/scan.sh ${BUTTON_OCR}"
EOF

# ── Systemd service ──────────────────────────────────────
echo "==> Creating systemd service"
cat > /etc/systemd/system/scanserv.service <<'EOF'
[Unit]
Description=Brother Scan-to-NAS service (brscan-skey)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/opt/brother/scanner/brscan-skey/brscan-skey
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable scanserv.service
systemctl start scanserv.service || echo "WARN: Service failed to start — will start on next boot"

# ── Verify ───────────────────────────────────────────────
echo ""
echo "==> Verifying scanner detection..."
if scanimage -L 2>/dev/null | grep -qi brother; then
    echo "    Scanner detected!"
    scanimage -L 2>/dev/null | grep -i brother
else
    echo "    WARN: Scanner not detected yet."
    echo "    Make sure the printer is powered on and reachable at $PRINTER_IP"
    echo "    Then run: scanimage -L"
fi

echo ""
echo "==> Installation complete."
echo "    NAS mount:   $NAS_MOUNT"
echo "    Scan script: /opt/scanserv/scan.sh"
echo "    Service:     scanserv.service"
echo "    Logs:        journalctl -u scanserv -f"
echo ""
echo "    Press 'Scan to File' on the printer panel to test."
