#!/system/bin/sh
set +e
# ============================================================
# dynamic_partition_detect.sh
# Vendor15 GSI — Dynamic Partition Environment Detection
# ============================================================
#
# Detects the device's partition scheme and layout to determine
# flashing strategy. Runs on-device (ADB or boot chain).
#
# Properties set:
#   sys.gsi.dp.detected      = true|false
#   sys.gsi.dp.slot_scheme   = ab|a_only
#   sys.gsi.dp.super_device  = <block device path>
#   sys.gsi.dp.super_size_mb = <size in MB>
#   sys.gsi.dp.retrofit      = true|false
#   sys.gsi.dp.partitions    = <comma-separated list>
#
# Safety:
#   - Read-only detection; never modifies partitions
#   - All operations guarded with || true
#   - Sets sys.gsi.dp.detected=false on any failure
# ============================================================

LOG_TAG="GSI_DYNPART"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== Dynamic Partition Detection Starting ==="

# ============================================================
# 1. Check ro.boot.dynamic_partitions
# ============================================================
DP_ENABLED=$(getprop ro.boot.dynamic_partitions 2>/dev/null || echo "")
DP_RETROFIT=$(getprop ro.boot.dynamic_partitions_retrofit 2>/dev/null || echo "")

if [ "$DP_ENABLED" = "true" ]; then
    log_info "  Dynamic partitions: ENABLED (boot property)"
    setprop sys.gsi.dp.detected true 2>/dev/null || true
else
    log_info "  Dynamic partitions: NOT DETECTED"
    setprop sys.gsi.dp.detected false 2>/dev/null || true
    log_info "=== Dynamic Partition Detection Complete (legacy) ==="
    exit 0
fi

# ============================================================
# 2. Detect A/B vs A-only
# ============================================================
AB_UPDATE=$(getprop ro.build.ab_update 2>/dev/null || echo "")
SLOT_SUFFIX=$(getprop ro.boot.slot_suffix 2>/dev/null || echo "")

if [ "$AB_UPDATE" = "true" ] || [ -n "$SLOT_SUFFIX" ]; then
    SLOT_SCHEME="ab"
    log_info "  Slot scheme: A/B (suffix=$SLOT_SUFFIX)"
else
    SLOT_SCHEME="a_only"
    log_info "  Slot scheme: A-only"
fi
setprop sys.gsi.dp.slot_scheme "$SLOT_SCHEME" 2>/dev/null || true

# ============================================================
# 3. Detect retrofit dynamic partitions
# ============================================================
if [ "$DP_RETROFIT" = "true" ]; then
    log_info "  Retrofit dynamic partitions: YES"
    setprop sys.gsi.dp.retrofit true 2>/dev/null || true
else
    setprop sys.gsi.dp.retrofit false 2>/dev/null || true
fi

# ============================================================
# 4. Find super partition device
# ============================================================
SUPER_DEVICE=""
for candidate in \
    /dev/block/by-name/super \
    /dev/block/bootdevice/by-name/super \
    /dev/block/platform/*/by-name/super; do
    if [ -b "$candidate" ] 2>/dev/null; then
        SUPER_DEVICE="$candidate"
        break
    fi
done

if [ -n "$SUPER_DEVICE" ]; then
    log_info "  Super device: $SUPER_DEVICE"
    setprop sys.gsi.dp.super_device "$SUPER_DEVICE" 2>/dev/null || true

    # Get super partition size
    SUPER_SIZE_BYTES=$(blockdev --getsize64 "$SUPER_DEVICE" 2>/dev/null || echo "0")
    SUPER_SIZE_MB=$((SUPER_SIZE_BYTES / 1048576))
    log_info "  Super size: ${SUPER_SIZE_MB}MB"
    setprop sys.gsi.dp.super_size_mb "$SUPER_SIZE_MB" 2>/dev/null || true
else
    log_warn "  Super device: NOT FOUND"
    setprop sys.gsi.dp.super_device "" 2>/dev/null || true
    setprop sys.gsi.dp.super_size_mb "0" 2>/dev/null || true
fi

# ============================================================
# 5. Enumerate dynamic partitions via lpdump
# ============================================================
PARTITION_LIST=""
if command -v lpdump >/dev/null 2>&1; then
    log_info "  lpdump: available"
    # Extract partition names from lpdump output
    PARTITION_LIST=$(lpdump 2>/dev/null | grep "Name:" | awk '{print $2}' | \
        tr '\n' ',' | sed 's/,$//' 2>/dev/null || echo "")

    if [ -n "$PARTITION_LIST" ]; then
        log_info "  Partitions: $PARTITION_LIST"
    else
        log_warn "  lpdump returned no partitions"
    fi
elif [ -f /proc/device-tree/firmware/android/super_partition ]; then
    # Fallback: check device tree
    log_info "  lpdump: not available, checking device-tree"
    PARTITION_LIST="system,vendor"
fi
setprop sys.gsi.dp.partitions "$PARTITION_LIST" 2>/dev/null || true

# ============================================================
# 6. Check if system partition is large enough for GSI
# ============================================================
# Typical A16 GSI system.img is ~2GB. Warn if system partition
# in super is smaller than 2.5GB.
SYSTEM_SIZE_BYTES=0
if command -v lpdump >/dev/null 2>&1; then
    SYSTEM_SIZE_BYTES=$(lpdump 2>/dev/null | grep -A5 "Name: system" | \
        grep "Size:" | awk '{print $2}' 2>/dev/null || echo "0")
fi

SYSTEM_SIZE_MB=$((SYSTEM_SIZE_BYTES / 1048576))
if [ "$SYSTEM_SIZE_MB" -gt 0 ] 2>/dev/null; then
    log_info "  System partition size: ${SYSTEM_SIZE_MB}MB"
    if [ "$SYSTEM_SIZE_MB" -lt 2560 ]; then
        log_warn "  WARNING: System partition may be too small for A16 GSI (need ~2.5GB)"
        setprop sys.gsi.dp.system_too_small true 2>/dev/null || true
    fi
fi

# ============================================================
# Summary
# ============================================================
log_info "=== Dynamic Partition Detection Complete ==="
log_info "  detected=$DP_ENABLED scheme=$SLOT_SCHEME retrofit=$DP_RETROFIT"
log_info "  super=${SUPER_SIZE_MB}MB partitions=$PARTITION_LIST"

exit 0
