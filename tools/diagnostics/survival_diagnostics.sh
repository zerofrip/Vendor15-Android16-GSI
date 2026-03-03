#!/system/bin/sh
set +e
# ============================================================
# survival_diagnostics.sh
# Vendor15 Survival Mode — Telemetry & Diagnostics Collector
# ============================================================
#
# Lightweight event logger for survival mode. Emits structured
# JSON-line entries to logcat for machine-parseable diagnostics.
#
# Privacy guarantees:
#   - No device identifiers (IMEI, serial, Android ID)
#   - No user data (accounts, contacts, messages)
#   - No network transmission (logcat ring buffer only)
#   - Only system-level survival metrics
#
# Developer utility for manual diagnostics via ADB.
# The integrated version of this script runs in the boot
# chain as /system/bin/survival_diagnostics.sh (see repo root).
#
# Usage: vendor15-cli.sh diagnose
#
# Properties set:
#   sys.gsi.diagnostics_done=1
#   sys.gsi.diagnostics.boot_time_ms=<ms>
#   sys.gsi.diagnostics.hal_alive_count=<n>
#   sys.gsi.diagnostics.mitigation_props=<n>
# ============================================================

LOG_TAG="GSI_DIAG"

diag() {
    local ts
    ts=$(date +%s 2>/dev/null || echo "0")
    log -t "$LOG_TAG" -p i "{\"ts\":$ts,$1}" 2>/dev/null || true
}

info() {
    log -t "$LOG_TAG" -p i "$1" 2>/dev/null || true
}

info "=== Survival Diagnostics Starting ==="

# ============================================================
# 1. Boot timing
# ============================================================
# Calculate approximate boot time from uptime
UPTIME_SEC=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}' || echo "0")
UPTIME_MS=$((UPTIME_SEC * 1000))

diag "\"event\":\"boot_timing\",\"uptime_sec\":$UPTIME_SEC"
setprop sys.gsi.diagnostics.boot_time_ms "$UPTIME_MS" 2>/dev/null || true

# ============================================================
# 2. Survival mode state
# ============================================================
SURVIVAL_MODE=$(getprop ro.gsi.compat.survival_mode 2>/dev/null || echo "false")
VENDOR_LEVEL=$(getprop ro.gsi.compat.vendor_level 2>/dev/null || echo "unknown")
SDK_VERSION=$(getprop ro.build.version.sdk 2>/dev/null || echo "unknown")
FIRST_API=$(getprop ro.product.first_api_level 2>/dev/null || echo "unknown")
BOOT_DECISION=$(getprop sys.gsi.boot_decision 2>/dev/null || echo "unknown")

diag "\"event\":\"survival_state\",\"mode\":\"$SURVIVAL_MODE\",\"vendor_level\":\"$VENDOR_LEVEL\",\"sdk\":\"$SDK_VERSION\",\"first_api\":\"$FIRST_API\",\"boot_decision\":\"$BOOT_DECISION\""

# ============================================================
# 3. Mitigation chain status
# ============================================================
CHAIN_PROPS="sys.gsi.boot_safety_done sys.gsi.gpu_stability_done sys.gsi.hal_mitigations_done sys.gsi.app_compat_done sys.gsi.forward_compat_done sys.gsi.all_mitigations_done"
CHAIN_COMPLETED=0
CHAIN_TOTAL=0

for prop in $CHAIN_PROPS; do
    CHAIN_TOTAL=$((CHAIN_TOTAL + 1))
    val=$(getprop "$prop" 2>/dev/null || echo "0")
    if [ "$val" = "1" ]; then
        CHAIN_COMPLETED=$((CHAIN_COMPLETED + 1))
    fi
done

diag "\"event\":\"mitigation_chain\",\"completed\":$CHAIN_COMPLETED,\"total\":$CHAIN_TOTAL"

# ============================================================
# 4. Count total mitigation properties set
# ============================================================
# Count all GSI-related properties
TOTAL_GSI_PROPS=$(getprop 2>/dev/null | grep -c "gsi\." 2>/dev/null || echo "0")
TOTAL_DEBUG_PROPS=$(getprop 2>/dev/null | grep -c "debug\." 2>/dev/null || echo "0")

diag "\"event\":\"prop_counts\",\"gsi_props\":$TOTAL_GSI_PROPS,\"debug_props\":$TOTAL_DEBUG_PROPS"
setprop sys.gsi.diagnostics.mitigation_props "$TOTAL_GSI_PROPS" 2>/dev/null || true

# ============================================================
# 5. HAL probe results (if available)
# ============================================================
PROBE_DONE=$(getprop sys.gsi.probe.done 2>/dev/null || echo "0")
if [ "$PROBE_DONE" = "1" ]; then
    PROBE_SUMMARY=$(getprop sys.gsi.probe.summary 2>/dev/null || echo "unknown")
    diag "\"event\":\"hal_probes\",\"summary\":\"$PROBE_SUMMARY\""

    # Extract alive count
    ALIVE_COUNT=$(echo "$PROBE_SUMMARY" | cut -d'/' -f1)
    setprop sys.gsi.diagnostics.hal_alive_count "$ALIVE_COUNT" 2>/dev/null || true
fi

# ============================================================
# 6. Critical process check
# ============================================================
PROCESSES="system_server surfaceflinger servicemanager vold zygote64"
ALIVE_PROCS=0
DEAD_PROCS=""

for proc in $PROCESSES; do
    pid=$(pidof "$proc" 2>/dev/null || echo "")
    if [ -n "$pid" ]; then
        ALIVE_PROCS=$((ALIVE_PROCS + 1))
    else
        DEAD_PROCS="${DEAD_PROCS}${proc},"
    fi
done

diag "\"event\":\"process_health\",\"alive\":$ALIVE_PROCS,\"total\":5,\"dead\":\"${DEAD_PROCS%,}\""

# ============================================================
# 7. SELinux state
# ============================================================
SELINUX_MODE="unknown"
if [ -f /sys/fs/selinux/enforce ]; then
    ENFORCE_VAL=$(cat /sys/fs/selinux/enforce 2>/dev/null || echo "-1")
    case "$ENFORCE_VAL" in
        0) SELINUX_MODE="permissive" ;;
        1) SELINUX_MODE="enforcing" ;;
        *) SELINUX_MODE="unknown" ;;
    esac
fi

diag "\"event\":\"selinux\",\"mode\":\"$SELINUX_MODE\""

# ============================================================
# 8. Kernel info
# ============================================================
KERNEL_VER=$(uname -r 2>/dev/null || echo "unknown")
KERNEL_ARCH=$(uname -m 2>/dev/null || echo "unknown")

diag "\"event\":\"kernel\",\"version\":\"$KERNEL_VER\",\"arch\":\"$KERNEL_ARCH\""

# ============================================================
# 9. GPU info
# ============================================================
GPU_VENDOR=$(getprop sys.gsi.gpu_vendor 2>/dev/null || echo "unknown")
GPU_MODEL=$(getprop ro.hardware.egl 2>/dev/null || echo "unknown")
GPU_COMP=$(getprop debug.sf.hw 2>/dev/null || echo "unset")

diag "\"event\":\"gpu\",\"vendor\":\"$GPU_VENDOR\",\"egl\":\"$GPU_MODEL\",\"hw_comp\":\"$GPU_COMP\""

# ============================================================
# 10. Logcat error counts (quick scan)
# ============================================================
# Only scan last 1000 lines to keep this fast
RECENT_LOG=$(logcat -d -t 1000 2>/dev/null || echo "")

FATAL_COUNT=$(echo "$RECENT_LOG" | grep -cE "FATAL|SIGABRT" 2>/dev/null || echo "0")
DEAD_OBJ=$(echo "$RECENT_LOG" | grep -c "DeadObjectException" 2>/dev/null || echo "0")
UNK_TX=$(echo "$RECENT_LOG" | grep -c "UNKNOWN_TRANSACTION" 2>/dev/null || echo "0")

diag "\"event\":\"error_counts\",\"fatal\":$FATAL_COUNT,\"dead_obj\":$DEAD_OBJ,\"unknown_tx\":$UNK_TX"

# ============================================================
# Summary
# ============================================================
diag "\"event\":\"diagnostics_complete\",\"uptime_sec\":$UPTIME_SEC,\"chain\":\"$CHAIN_COMPLETED/$CHAIN_TOTAL\",\"procs_alive\":$ALIVE_PROCS"

setprop sys.gsi.diagnostics_done 1 2>/dev/null || true

info "=== Survival Diagnostics Complete ==="
info "  Boot time: ${UPTIME_SEC}s"
info "  Mitigation chain: $CHAIN_COMPLETED/$CHAIN_TOTAL"
info "  Processes alive: $ALIVE_PROCS/5"
info "  SELinux: $SELINUX_MODE"
info "  GPU: $GPU_VENDOR ($GPU_MODEL)"
info "  Errors: fatal=$FATAL_COUNT dead_obj=$DEAD_OBJ unknown_tx=$UNK_TX"

exit 0
