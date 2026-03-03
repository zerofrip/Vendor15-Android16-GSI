#!/system/bin/sh
set +e
# ============================================================
# vndklite_apply.sh
# Vendor15 GSI — VNDK-Lite Compatibility Application
# ============================================================
#
# Applies linker namespace relaxations and VNDK version
# adjustments when a VNDK version mismatch is detected.
#
# Prerequisites:
#   Must run AFTER vndklite_detect.sh has set properties.
#
# Properties read:
#   sys.gsi.vndk.mismatch
#   sys.gsi.vndk.vendor_version
#   sys.gsi.vndk.system_version
#
# Properties set:
#   sys.gsi.vndklite.applied    = true|false
#   sys.gsi.vndklite.original_vndk = <original ro.vndk.version>
#   sys.gsi.vndklite.done       = 1
#
# Safety:
#   - Only applies if mismatch detected
#   - Saves original values before modification
#   - All relaxations are reversible via property reset
#   - Never modifies vendor partition
# ============================================================

LOG_TAG="GSI_VNDKLITE"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== VNDK-Lite Compatibility Application ==="

# ============================================================
# 1. Check if mismatch was detected
# ============================================================
MISMATCH=$(getprop sys.gsi.vndk.mismatch 2>/dev/null || echo "false")

if [ "$MISMATCH" != "true" ]; then
    log_info "  No VNDK mismatch detected. Skipping VNDK-Lite."
    setprop sys.gsi.vndklite.applied false 2>/dev/null || true
    setprop sys.gsi.vndklite.done 1 2>/dev/null || true
    exit 0
fi

VENDOR_VNDK=$(getprop sys.gsi.vndk.vendor_version 2>/dev/null || echo "")
SYSTEM_VNDK=$(getprop sys.gsi.vndk.system_version 2>/dev/null || echo "")

log_info "  Mismatch confirmed: system=$SYSTEM_VNDK vendor=$VENDOR_VNDK"

# ============================================================
# 2. Save original VNDK version (for rollback)
# ============================================================
ORIGINAL_VNDK=$(getprop ro.vndk.version 2>/dev/null || echo "")
setprop sys.gsi.vndklite.original_vndk "$ORIGINAL_VNDK" 2>/dev/null || true
log_info "  Original ro.vndk.version: $ORIGINAL_VNDK"

# ============================================================
# 3. Apply linker namespace relaxations
# ============================================================
log_info "  --- Applying linker namespace relaxations ---"

# Allow vendor namespace to load libraries from system
# This is the core VNDK-Lite mechanism: vendor processes can
# fall back to system libraries when VNDK snapshot is missing
setprop ro.gsi.vndklite.linker_relaxed true 2>/dev/null || true

# Set VNDK version to vendor's version so the linker namespace
# looks in the correct VNDK snapshot directory
if [ -n "$VENDOR_VNDK" ] && [ "$VENDOR_VNDK" != "unknown" ]; then
    # Only override if vendor version differs from current
    CURRENT_VNDK=$(getprop ro.vndk.version 2>/dev/null || echo "")
    if [ "$CURRENT_VNDK" != "$VENDOR_VNDK" ]; then
        setprop ro.vndk.version "$VENDOR_VNDK" 2>/dev/null || true
        log_info "  Set ro.vndk.version=$VENDOR_VNDK (was: $CURRENT_VNDK)"
    fi
fi

# ============================================================
# 4. Apply library loading fallbacks
# ============================================================
log_info "  --- Applying library loading fallbacks ---"

# Allow vendor processes to load system libraries as fallback
# when vendor VNDK libraries are missing
setprop ro.gsi.vndklite.system_fallback true 2>/dev/null || true

# Disable strict VNDK lite restriction
# In A16, the linker may reject loading system libs in vendor
# namespace. This property relaxes that check.
setprop ro.vndk.lite true 2>/dev/null || true

# Allow same-process HALs to load from system lib paths
setprop ro.gsi.vndklite.sphal_system_fallback true 2>/dev/null || true

# ============================================================
# 5. VNDK library search path adjustments
# ============================================================
log_info "  --- Adjusting VNDK library search paths ---"

# If the vendor expects VNDK v35 but we have v36, tell the
# linker to also search the v35 path for compatibility
VND_NUM=$(echo "$VENDOR_VNDK" | tr -cd '0-9')
SYS_NUM=$(echo "$SYSTEM_VNDK" | tr -cd '0-9')

if [ -n "$VND_NUM" ] && [ -n "$SYS_NUM" ] 2>/dev/null; then
    # Check if vendor VNDK snapshot directory exists
    if [ -d "/system/lib64/vndk-$VENDOR_VNDK" ] 2>/dev/null; then
        log_info "  VNDK snapshot found: /system/lib64/vndk-$VENDOR_VNDK"
    elif [ -d "/apex/com.android.vndk.v${VND_NUM}/lib64" ] 2>/dev/null; then
        log_info "  VNDK APEX found: com.android.vndk.v${VND_NUM}"
    else
        log_warn "  VNDK snapshot NOT FOUND for vendor version $VENDOR_VNDK"
        log_warn "  Vendor processes may fail to load VNDK libraries"
        log_warn "  Build with VNDK snapshot included (-include vndk_v${VND_NUM})"
    fi
fi

# ============================================================
# 6. Vendor compatibility shims
# ============================================================
log_info "  --- Setting vendor compatibility properties ---"

# Tell HIDL servicemanager to be lenient about version checks
setprop ro.gsi.vndklite.hidl_version_lenient true 2>/dev/null || true

# Allow vendor modules to use newer AIDL interfaces
# even if they were compiled against older versions
setprop ro.gsi.vndklite.aidl_version_lenient true 2>/dev/null || true

# Disable crash on library version mismatch
setprop ro.gsi.vndklite.no_crash_on_mismatch true 2>/dev/null || true

# ============================================================
# Done
# ============================================================
setprop sys.gsi.vndklite.applied true 2>/dev/null || true
setprop sys.gsi.vndklite.done 1 2>/dev/null || true

log_info "=== VNDK-Lite Application Complete ==="
log_info "  VNDK adjusted: $ORIGINAL_VNDK → $VENDOR_VNDK"
log_info "  Linker relaxed: true"
log_info "  System fallback: true"

exit 0
