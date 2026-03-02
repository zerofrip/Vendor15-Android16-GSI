#!/system/bin/sh
# ============================================================
# gsi_survival_check.sh
# Vendor15 Compatibility Lifetime Extension — Boot Gate
# ============================================================
#
# Called from gsi_survival.rc during post-fs-data.
# Performs upgrade/downgrade detection, SDK version tracking,
# and cache sanitation for safe userdata-preserving upgrades.
#
# Boot safety:
#   - All operations are guarded against missing/corrupt values
#   - All comparisons validate numeric input
#   - Errors default to "continue boot" (never block on error)
#   - Cache cleanup only touches regenerable directories
#
# Properties set:
#   persist.sys.prev_sdk    — last successfully booted SDK version
#   persist.sys.gsi_upgrade — "1" during the one upgrade boot
#   sys.gsi.boot_decision   — "normal" | "upgrade" | "downgrade"
# ============================================================

LOG_TAG="GSI_SURVIVAL"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null; }
log_fatal() { log -t "$LOG_TAG" -p f "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null; }

# -------------------------------------------------------
# Helper: validate that a string is a positive integer
# -------------------------------------------------------
is_numeric() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# -------------------------------------------------------
# 1. Read current and previous SDK versions
# -------------------------------------------------------
CURRENT_SDK=$(getprop ro.build.version.sdk 2>/dev/null)
PREV_SDK=$(getprop persist.sys.prev_sdk 2>/dev/null)

log_info "=== GSI Survival Boot Gate ==="
log_info "Current SDK : ${CURRENT_SDK:-(empty)}"
log_info "Previous SDK: ${PREV_SDK:-(empty/first boot)}"

# Guard: if current SDK is unreadable or non-numeric, CONTINUE BOOT.
# Never block boot due to a property read failure.
if ! is_numeric "$CURRENT_SDK"; then
    log_warn "WARNING: ro.build.version.sdk='${CURRENT_SDK}' is not numeric."
    log_warn "Cannot determine OS version. Continuing boot (fail-open)."
    setprop sys.gsi.boot_decision "normal"
    exit 0
fi

# -------------------------------------------------------
# 2. First-ever boot (no previous SDK recorded)
# -------------------------------------------------------
if [ -z "$PREV_SDK" ]; then
    log_info "First boot detected (no persist.sys.prev_sdk)."
    log_info "Recording SDK ${CURRENT_SDK} as baseline."
    setprop persist.sys.prev_sdk "$CURRENT_SDK"
    setprop sys.gsi.boot_decision "first_boot"
    exit 0
fi

# Guard: if prev_sdk is non-numeric (corrupt property), treat as first boot
if ! is_numeric "$PREV_SDK"; then
    log_warn "WARNING: persist.sys.prev_sdk='${PREV_SDK}' is not numeric."
    log_warn "Treating as first boot (resetting baseline)."
    setprop persist.sys.prev_sdk "$CURRENT_SDK"
    setprop sys.gsi.boot_decision "first_boot"
    exit 0
fi

# -------------------------------------------------------
# 3. Downgrade detection (FATAL — signal to halt boot)
# -------------------------------------------------------
if [ "$CURRENT_SDK" -lt "$PREV_SDK" ]; then
    log_fatal "=== DOWNGRADE DETECTED ==="
    log_fatal "Current SDK ${CURRENT_SDK} < Previous SDK ${PREV_SDK}"
    log_fatal "Downgrade is FORBIDDEN: database schemas, keystore, and"
    log_fatal "FBE metadata are forward-migrated and cannot be rolled back."
    log_fatal "Options:"
    log_fatal "  1. Flash the same or newer GSI (SDK >= ${PREV_SDK})"
    log_fatal "  2. Factory reset (wipe userdata) to use this GSI"
    log_fatal "==========================="
    setprop sys.gsi.boot_decision "downgrade"
    exit 1
fi

# -------------------------------------------------------
# 4. Same-version boot (normal)
# -------------------------------------------------------
if [ "$CURRENT_SDK" -eq "$PREV_SDK" ]; then
    log_info "Same SDK version (${CURRENT_SDK}). Normal boot."
    setprop sys.gsi.boot_decision "normal"
    # Clear stale upgrade flag if present
    if [ "$(getprop persist.sys.gsi_upgrade 2>/dev/null)" = "1" ]; then
        log_warn "Clearing stale persist.sys.gsi_upgrade."
        setprop persist.sys.gsi_upgrade "0"
    fi
    exit 0
fi

# -------------------------------------------------------
# 5. Upgrade detected (current > previous)
# -------------------------------------------------------
log_info "=== UPGRADE DETECTED ==="
log_info "SDK ${PREV_SDK} -> ${CURRENT_SDK}"
setprop sys.gsi.boot_decision "upgrade"

# One-shot guard: don't re-run cleanup
if [ "$(getprop persist.sys.gsi_upgrade 2>/dev/null)" = "1" ]; then
    log_warn "Cleanup already ran. Updating baseline only."
    setprop persist.sys.prev_sdk "$CURRENT_SDK"
    setprop persist.sys.gsi_upgrade "0"
    exit 0
fi

setprop persist.sys.gsi_upgrade "1"

# -------------------------------------------------------
# 6. Cache sanitation (regenerable items ONLY)
# -------------------------------------------------------
log_info "--- Cache sanitation ---"

for dir in /data/dalvik-cache /data/resource-cache /data/system/package_cache; do
    if [ -d "$dir" ]; then
        rm -rf "${dir:?}"/* 2>/dev/null
        log_info "Cleared $dir"
    fi
done

log_info "--- Cache sanitation complete ---"

# -------------------------------------------------------
# 7. Record the new SDK as high-water mark
# -------------------------------------------------------
setprop persist.sys.prev_sdk "$CURRENT_SDK"
log_info "Updated persist.sys.prev_sdk to ${CURRENT_SDK}"
log_info "=== Upgrade complete. Continuing boot. ==="

exit 0
