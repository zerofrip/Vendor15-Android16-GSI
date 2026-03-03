#!/system/bin/sh
set +e
# ============================================================
# vndklite_detect.sh
# Vendor15 GSI — VNDK Version Mismatch Detection
# ============================================================
#
# On-device script. Detects VNDK version mismatch between the
# system (Android 16) and vendor (Android 15) partitions.
#
# Properties set:
#   sys.gsi.vndk.system_version  = <detected system VNDK version>
#   sys.gsi.vndk.vendor_version  = <detected vendor VNDK version>
#   sys.gsi.vndk.mismatch        = true|false
#   sys.gsi.vndk.version_delta   = <numeric difference>
#
# Safety:
#   - Read-only detection; never modifies any VNDK config
#   - All operations guarded with || true
# ============================================================

LOG_TAG="GSI_VNDK"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== VNDK Version Mismatch Detection ==="

# ============================================================
# 1. Detect system VNDK version
# ============================================================
# System VNDK version comes from the system image's build props
SYSTEM_VNDK=""

# Try multiple sources (different AOSP versions use different props)
for prop in \
    ro.vndk.version \
    ro.build.version.vndk \
    ro.product.vndk.version; do
    val=$(getprop "$prop" 2>/dev/null || echo "")
    if [ -n "$val" ] && [ "$val" != "" ]; then
        SYSTEM_VNDK="$val"
        log_info "  System VNDK: $val (from $prop)"
        break
    fi
done

# Fallback: derive from SDK version
if [ -z "$SYSTEM_VNDK" ]; then
    SDK_VER=$(getprop ro.build.version.sdk 2>/dev/null || echo "")
    if [ -n "$SDK_VER" ]; then
        SYSTEM_VNDK="$SDK_VER"
        log_info "  System VNDK: $SDK_VER (derived from SDK)"
    else
        SYSTEM_VNDK="unknown"
        log_warn "  System VNDK: UNKNOWN"
    fi
fi

setprop sys.gsi.vndk.system_version "$SYSTEM_VNDK" 2>/dev/null || true

# ============================================================
# 2. Detect vendor VNDK version
# ============================================================
VENDOR_VNDK=""

# Read directly from vendor build.prop (most reliable)
for vendor_prop_file in \
    /vendor/build.prop \
    /vendor/default.prop \
    /vendor/etc/build.prop; do
    if [ -f "$vendor_prop_file" ]; then
        val=$(grep -m1 'ro.vndk.version=' "$vendor_prop_file" 2>/dev/null | \
              cut -d'=' -f2 | tr -d '[:space:]' || echo "")
        if [ -n "$val" ]; then
            VENDOR_VNDK="$val"
            log_info "  Vendor VNDK: $val (from $vendor_prop_file)"
            break
        fi
    fi
done

# Fallback: check vendor API level
if [ -z "$VENDOR_VNDK" ]; then
    for prop in \
        ro.vendor.build.version.sdk \
        ro.board.api_level \
        ro.product.first_api_level; do
        val=$(getprop "$prop" 2>/dev/null || echo "")
        if [ -n "$val" ] && [ "$val" != "" ]; then
            VENDOR_VNDK="$val"
            log_info "  Vendor VNDK: $val (from $prop fallback)"
            break
        fi
    done
fi

if [ -z "$VENDOR_VNDK" ]; then
    VENDOR_VNDK="unknown"
    log_warn "  Vendor VNDK: UNKNOWN"
fi

setprop sys.gsi.vndk.vendor_version "$VENDOR_VNDK" 2>/dev/null || true

# ============================================================
# 3. Compare versions
# ============================================================
MISMATCH="false"
DELTA=0

# Strip non-numeric characters for comparison
SYS_NUM=$(echo "$SYSTEM_VNDK" | tr -cd '0-9')
VND_NUM=$(echo "$VENDOR_VNDK" | tr -cd '0-9')

if [ -n "$SYS_NUM" ] && [ -n "$VND_NUM" ] 2>/dev/null; then
    if [ "$SYS_NUM" -ne "$VND_NUM" ] 2>/dev/null; then
        MISMATCH="true"
        DELTA=$((SYS_NUM - VND_NUM))
        log_warn "  VNDK MISMATCH: system=$SYSTEM_VNDK vendor=$VENDOR_VNDK (delta=$DELTA)"
    else
        log_info "  VNDK versions match: $SYSTEM_VNDK"
    fi
else
    if [ "$SYSTEM_VNDK" != "$VENDOR_VNDK" ]; then
        MISMATCH="true"
        log_warn "  VNDK MISMATCH (non-numeric): system=$SYSTEM_VNDK vendor=$VENDOR_VNDK"
    fi
fi

setprop sys.gsi.vndk.mismatch "$MISMATCH" 2>/dev/null || true
setprop sys.gsi.vndk.version_delta "$DELTA" 2>/dev/null || true

# ============================================================
# 4. Check VNDK library availability
# ============================================================
VNDK_LIB_DIR=""
for candidate in \
    "/system/lib64/vndk-$VENDOR_VNDK" \
    "/system/lib64/vndk-sp-$VENDOR_VNDK" \
    "/apex/com.android.vndk.v${VND_NUM}/lib64"; do
    if [ -d "$candidate" ] 2>/dev/null; then
        VNDK_LIB_DIR="$candidate"
        break
    fi
done

if [ -n "$VNDK_LIB_DIR" ]; then
    LIB_COUNT=$(ls -1 "$VNDK_LIB_DIR"/*.so 2>/dev/null | wc -l || echo "0")
    log_info "  VNDK libs: $LIB_COUNT in $VNDK_LIB_DIR"
else
    log_warn "  VNDK libs: directory not found for vendor version $VENDOR_VNDK"
fi

# ============================================================
# Summary
# ============================================================
log_info "=== VNDK Detection Complete ==="
log_info "  system=$SYSTEM_VNDK vendor=$VENDOR_VNDK mismatch=$MISMATCH delta=$DELTA"

exit 0
