#!/usr/bin/env bash
# scan.sh — called by brscan-skey when a scan is initiated from the printer panel.
# Usage: scan.sh <adf|duplex|flatbed>
set -euo pipefail

CONFIG="/etc/scanserv/config.env"
LOG_TAG="scanserv"

log()  { logger -t "$LOG_TAG" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

# ── Load config ───────────────────────────────────────────
[[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"
# shellcheck source=/dev/null
source "$CONFIG"

SCAN_TYPE="${1:-adf}"

# ── Discover scanner ─────────────────────────────────────
DEVICE=$(scanimage -L 2>/dev/null \
    | grep -i brother \
    | head -1 \
    | sed "s/.*\`\(.*\)'.*/\1/") \
    || true

[[ -n "$DEVICE" ]] || die "No Brother scanner found on the network"
log "Using device: $DEVICE"

# ── Map scan type to source string ───────────────────────
case "$SCAN_TYPE" in
    adf)     SOURCE="Automatic Document Feeder(left aligned)" ;;
    duplex)  SOURCE="Automatic Document Feeder(left aligned,Duplex)" ;;
    flatbed) SOURCE="FlatBed" ;;
    *)       die "Unknown scan type: $SCAN_TYPE" ;;
esac

# ── Prepare workspace ────────────────────────────────────
WORKDIR=$(mktemp -d /tmp/scanserv.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log "Starting $SCAN_TYPE scan (${SCAN_RESOLUTION}dpi, $SCAN_MODE)"

# ── Scan ─────────────────────────────────────────────────
COMMON_ARGS=(
    -d "$DEVICE"
    --mode "$SCAN_MODE"
    --resolution "$SCAN_RESOLUTION"
    --source "$SOURCE"
    -l 0 -t 0
    -x "$SCAN_WIDTH" -y "$SCAN_HEIGHT"
    --format=tiff
)

if [[ "$SCAN_TYPE" == "flatbed" ]]; then
    scanimage "${COMMON_ARGS[@]}" -o "$WORKDIR/page_001.tiff"
else
    # --batch scans all pages in the ADF until empty
    scanimage "${COMMON_ARGS[@]}" --batch="$WORKDIR/page_%03d.tiff" || {
        # scanimage returns non-zero when ADF runs out of paper after
        # scanning at least one page — that's expected, not an error.
        true
    }
fi

# ── Count pages ──────────────────────────────────────────
shopt -s nullglob
PAGES=("$WORKDIR"/page_*.tiff)
shopt -u nullglob
PAGE_COUNT=${#PAGES[@]}

[[ "$PAGE_COUNT" -gt 0 ]] || die "No pages scanned"
log "Scanned $PAGE_COUNT page(s)"

# ── Convert to PDF ───────────────────────────────────────
if [[ "$PAGE_COUNT" -eq 1 ]]; then
    tiff2pdf -j -o "$WORKDIR/scan.pdf" "${PAGES[0]}"
else
    tiffcp "${PAGES[@]}" "$WORKDIR/combined.tiff"
    tiff2pdf -j -o "$WORKDIR/scan.pdf" "$WORKDIR/combined.tiff"
fi

# ── Deliver to output directory ──────────────────────────
OUTPUT_DIR="${NAS_MOUNT}"
if ! mountpoint -q "$OUTPUT_DIR" 2>/dev/null; then
    # Try to remount in case it was disconnected
    mount "$OUTPUT_DIR" 2>/dev/null || true
    mountpoint -q "$OUTPUT_DIR" || die "NAS not mounted at $OUTPUT_DIR"
fi

OUTPUT_FILE="${OUTPUT_DIR}/scan_${TIMESTAMP}.pdf"
mv "$WORKDIR/scan.pdf" "$OUTPUT_FILE"

log "Done: $OUTPUT_FILE ($PAGE_COUNT page(s))"
