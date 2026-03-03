#!/bin/bash
# ============================================================
# survival_test.sh
# Vendor15 Survival Mode — Runtime Test Harness
# ============================================================
#
# Comprehensive runtime validation suite for a booted GSI.
# Requires an adb-connected device with the Vendor15 GSI flashed.
#
# Test categories:
#   1. Boot completion
#   2. Survival mode activation
#   3. Mitigation chain completion
#   4. Critical process health
#   5. HAL service status
#   6. Binder error scanning
#   7. Fatal pattern detection
#   8. Property validation
#   9. Display/Graphics health
#  10. Diagnostics summary
#
# Usage:
#   bash survival_test.sh [--timeout BOOT_TIMEOUT_SECS]
#
# Exit codes:
#   0 = all tests pass
#   1 = test failures
#   2 = device not reachable / boot failure
# ============================================================

set -euo pipefail

BOOT_TIMEOUT="${1:-300}"
ADB="adb"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL=0
PASS=0
FAIL=0
WARN=0

pass() {
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

warn() {
    TOTAL=$((TOTAL + 1))
    WARN=$((WARN + 1))
    echo -e "  ${YELLOW}WARN${NC}: $1"
}

skip() {
    TOTAL=$((TOTAL + 1))
    echo -e "  ${CYAN}SKIP${NC}: $1"
}

getprop() {
    $ADB shell "getprop $1" 2>/dev/null | tr -d '\r\n'
}

# ============================================================
# 0. Device Connectivity
# ============================================================
echo ""
echo "=== Vendor15 Survival Mode — Runtime Test Harness ==="
echo "Boot timeout: ${BOOT_TIMEOUT}s"
echo ""

echo "--- [0/10] Device Connectivity ---"

# Wait for device
echo "  Waiting for device..."
if ! timeout 30 $ADB wait-for-device 2>/dev/null; then
    echo -e "  ${RED}FATAL${NC}: No device found after 30s. Is USB debugging enabled?"
    exit 2
fi
pass "Device connected via adb"

# Get device info
DEVICE_MODEL=$($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')
SDK_VERSION=$($ADB shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
echo "  Device: $DEVICE_MODEL (SDK $SDK_VERSION)"

# ============================================================
# 1. Boot Completion
# ============================================================
echo ""
echo "--- [1/10] Boot Completion ---"

BOOT_COMPLETED=$(getprop sys.boot_completed)
if [ "$BOOT_COMPLETED" = "1" ]; then
    pass "sys.boot_completed=1"
else
    echo "  Waiting for boot completion (timeout: ${BOOT_TIMEOUT}s)..."
    ELAPSED=0
    while [ "$ELAPSED" -lt "$BOOT_TIMEOUT" ]; do
        BOOT_COMPLETED=$(getprop sys.boot_completed)
        if [ "$BOOT_COMPLETED" = "1" ]; then
            pass "sys.boot_completed=1 (after ${ELAPSED}s)"
            break
        fi
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    if [ "$BOOT_COMPLETED" != "1" ]; then
        fail "Boot did not complete within ${BOOT_TIMEOUT}s"
        echo -e "  ${RED}FATAL${NC}: Device did not finish booting. Remaining tests may be unreliable."
    fi
fi

# ============================================================
# 2. Survival Mode Activation
# ============================================================
echo ""
echo "--- [2/10] Survival Mode Activation ---"

SURVIVAL_MODE=$(getprop ro.gsi.compat.survival_mode)
if [ "$SURVIVAL_MODE" = "true" ]; then
    pass "ro.gsi.compat.survival_mode=true"
else
    fail "ro.gsi.compat.survival_mode != true (got: '$SURVIVAL_MODE')"
fi

VENDOR_LEVEL=$(getprop ro.gsi.compat.vendor_level)
if [ "$VENDOR_LEVEL" = "15" ]; then
    pass "ro.gsi.compat.vendor_level=15"
else
    fail "ro.gsi.compat.vendor_level != 15 (got: '$VENDOR_LEVEL')"
fi

RESCUE_DISABLED=$(getprop persist.sys.disable_rescue)
if [ "$RESCUE_DISABLED" = "true" ]; then
    pass "Rescue Party disabled"
else
    warn "Rescue Party not disabled (persist.sys.disable_rescue='$RESCUE_DISABLED')"
fi

# ============================================================
# 3. Mitigation Chain Completion
# ============================================================
echo ""
echo "--- [3/10] Mitigation Chain Completion ---"

check_mitigation_done() {
    local prop="$1"
    local label="$2"
    local val
    val=$(getprop "$prop")
    if [ "$val" = "1" ]; then
        pass "$label completed ($prop=1)"
    else
        fail "$label NOT completed ($prop='$val')"
    fi
}

check_mitigation_done "sys.gsi.boot_safety_done"     "Boot Safety"
check_mitigation_done "sys.gsi.gpu_stability_done"    "GPU Stability"
check_mitigation_done "sys.gsi.hal_mitigations_done"  "HAL Gap Mitigations"
check_mitigation_done "sys.gsi.app_compat_done"       "App Compatibility"
check_mitigation_done "sys.gsi.forward_compat_done"   "Forward Compatibility"
check_mitigation_done "sys.gsi.all_mitigations_done"  "All Mitigations Chain"

# ============================================================
# 4. Critical Process Health
# ============================================================
echo ""
echo "--- [4/10] Critical Process Health ---"

check_process() {
    local proc_name="$1"
    local pid
    pid=$($ADB shell pidof "$proc_name" 2>/dev/null | tr -d '\r')
    if [ -n "$pid" ] && [ "$pid" != "" ]; then
        pass "$proc_name alive (PID: $pid)"
    else
        fail "$proc_name NOT running"
    fi
}

check_process "system_server"
check_process "surfaceflinger"
check_process "servicemanager"
check_process "hwservicemanager"
check_process "vold"
check_process "installd"
check_process "zygote64"

# ============================================================
# 5. HAL Service Status
# ============================================================
echo ""
echo "--- [5/10] HAL Service Status ---"

# If HAL prober was run, check its results
PROBE_DONE=$(getprop sys.gsi.probe.done)
if [ "$PROBE_DONE" = "1" ]; then
    PROBE_SUMMARY=$(getprop sys.gsi.probe.summary)
    pass "HAL probing completed (summary: $PROBE_SUMMARY)"

    # Check critical HALs
    for hal in composer allocator power health gatekeeper; do
        HAL_STATUS=$(getprop "sys.gsi.probe.$hal")
        if [ "$HAL_STATUS" = "alive" ]; then
            pass "HAL probe: $hal = alive"
        elif [ "$HAL_STATUS" = "timeout" ]; then
            warn "HAL probe: $hal = timeout"
        else
            if [ "$hal" = "composer" ] || [ "$hal" = "allocator" ]; then
                fail "HAL probe: $hal = $HAL_STATUS (CRITICAL)"
            else
                warn "HAL probe: $hal = $HAL_STATUS"
            fi
        fi
    done
else
    skip "HAL prober not integrated (sys.gsi.probe.done != 1)"
fi

# Fallback: check lshal
LSHAL_OUTPUT=$($ADB shell "lshal -its 2>/dev/null | head -30" 2>/dev/null || echo "")
if [ -n "$LSHAL_OUTPUT" ]; then
    pass "lshal returns data"
else
    warn "lshal returned empty output"
fi

# ============================================================
# 6. Binder Error Scanning
# ============================================================
echo ""
echo "--- [6/10] Binder Error Scanning ---"

LOGCAT=$($ADB shell "logcat -d -b all 2>/dev/null" 2>/dev/null || echo "")

DEAD_OBJ_COUNT=$(echo "$LOGCAT" | grep -c "DeadObjectException" 2>/dev/null || echo "0")
if [ "$DEAD_OBJ_COUNT" -lt 5 ]; then
    pass "DeadObjectException count: $DEAD_OBJ_COUNT (< 5)"
elif [ "$DEAD_OBJ_COUNT" -lt 20 ]; then
    warn "DeadObjectException count: $DEAD_OBJ_COUNT (5-20 range)"
else
    fail "DeadObjectException count: $DEAD_OBJ_COUNT (> 20, indicates HAL instability)"
fi

UNKNOWN_TX_COUNT=$(echo "$LOGCAT" | grep -c "UNKNOWN_TRANSACTION" 2>/dev/null || echo "0")
if [ "$UNKNOWN_TX_COUNT" -lt 3 ]; then
    pass "UNKNOWN_TRANSACTION count: $UNKNOWN_TX_COUNT (< 3)"
elif [ "$UNKNOWN_TX_COUNT" -lt 10 ]; then
    warn "UNKNOWN_TRANSACTION count: $UNKNOWN_TX_COUNT (3-10 range, likely version mismatch)"
else
    fail "UNKNOWN_TRANSACTION count: $UNKNOWN_TX_COUNT (> 10, systemic HAL version gap)"
fi

SVC_NOT_FOUND=$(echo "$LOGCAT" | grep -c "ServiceManager.*not found" 2>/dev/null || echo "0")
if [ "$SVC_NOT_FOUND" -lt 5 ]; then
    pass "Service-not-found count: $SVC_NOT_FOUND (< 5)"
else
    warn "Service-not-found count: $SVC_NOT_FOUND (missing HALs detectable)"
fi

# ============================================================
# 7. Fatal Pattern Detection
# ============================================================
echo ""
echo "--- [7/10] Fatal Pattern Detection ---"

FATAL_COUNT=$(echo "$LOGCAT" | grep -cE "LOG\(FATAL\)|SIGABRT|F DEBUG" 2>/dev/null || echo "0")
if [ "$FATAL_COUNT" -eq 0 ]; then
    pass "No fatal crashes detected"
elif [ "$FATAL_COUNT" -lt 3 ]; then
    warn "Fatal crashes detected: $FATAL_COUNT (non-critical processes may have crashed)"
else
    fail "Fatal crashes detected: $FATAL_COUNT (review: adb logcat | grep -E 'FATAL|SIGABRT')"
fi

SS_CRASH_COUNT=$(echo "$LOGCAT" | grep -c "system_server.*died" 2>/dev/null || echo "0")
if [ "$SS_CRASH_COUNT" -eq 0 ]; then
    pass "system_server: no crashes detected"
else
    fail "system_server crashed $SS_CRASH_COUNT time(s)"
fi

WATCHDOG_COUNT=$(echo "$LOGCAT" | grep -c "Watchdog.*KILLED" 2>/dev/null || echo "0")
if [ "$WATCHDOG_COUNT" -eq 0 ]; then
    pass "No watchdog kills detected"
else
    fail "Watchdog killed processes: $WATCHDOG_COUNT time(s)"
fi

# ============================================================
# 8. Property Validation
# ============================================================
echo ""
echo "--- [8/10] Key Property Validation ---"

check_prop() {
    local prop="$1"
    local expected="$2"
    local label="${3:-$prop}"
    local actual
    actual=$(getprop "$prop")
    if [ "$actual" = "$expected" ]; then
        pass "$label = $expected"
    else
        warn "$label = '$actual' (expected '$expected')"
    fi
}

check_prop "ro.power.hint_session.enabled" "false" "Power hint sessions disabled"
check_prop "debug.nn.cpuonly" "1" "NNAPI CPU-only mode"
check_prop "debug.sf.hw" "0" "HWC bypass (GPU composition)"

# VINTF
VINTF_ENFORCE=$(getprop ro.vintf.enforce)
if [ "$VINTF_ENFORCE" = "false" ] || [ -z "$VINTF_ENFORCE" ]; then
    pass "VINTF enforcement disabled or not set"
else
    warn "VINTF enforcement: '$VINTF_ENFORCE' (should be false)"
fi

# ============================================================
# 9. Display / Graphics Health
# ============================================================
echo ""
echo "--- [9/10] Display / Graphics Health ---"

SF_PID=$($ADB shell pidof surfaceflinger 2>/dev/null | tr -d '\r')
if [ -n "$SF_PID" ]; then
    pass "SurfaceFlinger running (PID: $SF_PID)"

    # Check if display is active
    DISPLAY_INFO=$($ADB shell "dumpsys SurfaceFlinger 2>/dev/null | grep -c 'Display'" 2>/dev/null || echo "0")
    DISPLAY_INFO=$(echo "$DISPLAY_INFO" | tr -d '\r')
    if [ "$DISPLAY_INFO" -gt 0 ] 2>/dev/null; then
        pass "SurfaceFlinger has active display(s)"
    else
        warn "SurfaceFlinger display info not found"
    fi
else
    fail "SurfaceFlinger NOT running (display will be black)"
fi

# ============================================================
# 10. Diagnostics Summary
# ============================================================
echo ""
echo "--- [10/10] Boot Decision ---"

BOOT_DECISION=$(getprop sys.gsi.boot_decision)
if [ "$BOOT_DECISION" = "normal" ] || [ "$BOOT_DECISION" = "first_boot" ] || [ "$BOOT_DECISION" = "upgrade" ]; then
    pass "Boot decision: $BOOT_DECISION"
elif [ "$BOOT_DECISION" = "downgrade" ]; then
    fail "Boot decision: DOWNGRADE (data corruption risk)"
else
    skip "Boot decision not set (gsi_survival_gate may not have run)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "================================================="
echo "         SURVIVAL TEST RESULTS"
echo "================================================="
echo -e "  Total:    $TOTAL"
echo -e "  ${GREEN}Passed:   $PASS${NC}"
echo -e "  ${RED}Failed:   $FAIL${NC}"
echo -e "  ${YELLOW}Warnings: $WARN${NC}"
echo "================================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}RESULT: $FAIL test(s) FAILED.${NC}"
    echo "Review failures above. Critical failures (process health, fatal crashes)"
    echo "indicate the GSI may not be fully functional."
    exit 1
fi

if [ "$WARN" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}RESULT: All tests passed with $WARN warning(s).${NC}"
    echo "Warnings are non-critical but may indicate degraded functionality."
    exit 0
fi

echo ""
echo -e "${GREEN}RESULT: All tests passed. Survival mode operational.${NC}"
exit 0
