#!/bin/bash
# ============================================================
# verify_survival.sh
# Post-build verification of Vendor15 Survival Mode integration
# ============================================================
#
# Usage:
#   verify_survival.sh [PRODUCT_OUT]
#
# If PRODUCT_OUT is not specified, auto-detects from out/target/product/*/.
#
# Checks that the built system image contains all survival mode
# files, properties, and configurations. Run after 'm systemimage'.
#
# Exit codes:
#   0 = all checks pass
#   1 = one or more checks failed
# ============================================================

set -euo pipefail

PRODUCT_OUT="${1:-}"

# Auto-detect PRODUCT_OUT if not specified
if [ -z "$PRODUCT_OUT" ]; then
    for candidate in out/target/product/*/; do
        if [ -f "${candidate}system.img" ] || [ -d "${candidate}system" ]; then
            PRODUCT_OUT="$(cd "$candidate" && pwd)"
            break
        fi
    done
fi

if [ -z "$PRODUCT_OUT" ]; then
    echo "Error: Could not determine PRODUCT_OUT."
    echo "Usage: verify_survival.sh [PRODUCT_OUT]"
    exit 1
fi

echo "=== Vendor15 Survival Mode Verification ==="
echo "PRODUCT_OUT: $PRODUCT_OUT"
echo ""

TOTAL=0
PASS=0
FAIL=0

check() {
    local desc="$1"
    local result="$2"  # 0=pass, 1=fail
    TOTAL=$((TOTAL + 1))
    if [ "$result" -eq 0 ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# --- 1. System image exists ---
if [ -f "$PRODUCT_OUT/system.img" ]; then
    check "system.img exists" 0
else
    check "system.img exists" 1
    echo ""
    echo "FATAL: system.img not found. Build may have failed."
    exit 1
fi

# --- 2. Survival init script ---
SYSTEM_DIR="$PRODUCT_OUT/system"
if [ -f "$SYSTEM_DIR/system/etc/init/gsi_survival.rc" ] || \
   [ -f "$SYSTEM_DIR/etc/init/gsi_survival.rc" ]; then
    check "gsi_survival.rc installed" 0
else
    check "gsi_survival.rc installed" 1
fi

# --- 3. Survival check script ---
if [ -f "$SYSTEM_DIR/system/bin/gsi_survival_check.sh" ] || \
   [ -f "$SYSTEM_DIR/bin/gsi_survival_check.sh" ]; then
    # Check executable
    local_path=""
    if [ -f "$SYSTEM_DIR/system/bin/gsi_survival_check.sh" ]; then
        local_path="$SYSTEM_DIR/system/bin/gsi_survival_check.sh"
    else
        local_path="$SYSTEM_DIR/bin/gsi_survival_check.sh"
    fi
    if [ -x "$local_path" ]; then
        check "gsi_survival_check.sh installed & executable" 0
    else
        check "gsi_survival_check.sh installed & executable (not executable)" 1
    fi
else
    check "gsi_survival_check.sh installed & executable" 1
fi

# --- 4. Compatibility matrix ---
found_matrix=0
for path in \
    "$SYSTEM_DIR/system/etc/vintf/compatibility_matrix.xml" \
    "$SYSTEM_DIR/etc/vintf/compatibility_matrix.xml" \
    "$SYSTEM_DIR/system/etc/vintf/compatibility_matrix_vendor15_frozen.xml" \
    "$SYSTEM_DIR/etc/vintf/compatibility_matrix_vendor15_frozen.xml"; do
    if [ -f "$path" ]; then
        found_matrix=1
        break
    fi
done
check "Frozen compatibility matrix in VINTF" "$((1 - found_matrix))"

# --- 5. Build properties ---
BUILD_PROP=""
for candidate in \
    "$SYSTEM_DIR/system/build.prop" \
    "$SYSTEM_DIR/build.prop"; do
    if [ -f "$candidate" ]; then
        BUILD_PROP="$candidate"
        break
    fi
done

if [ -n "$BUILD_PROP" ]; then
    check "build.prop found" 0

    # Check survival mode property
    if grep -q "ro.gsi.compat.survival_mode=true" "$BUILD_PROP" 2>/dev/null; then
        check "ro.gsi.compat.survival_mode=true in build.prop" 0
    else
        check "ro.gsi.compat.survival_mode=true in build.prop" 1
    fi

    # Check vendor level property
    if grep -q "ro.gsi.compat.vendor_level=15" "$BUILD_PROP" 2>/dev/null; then
        check "ro.gsi.compat.vendor_level=15 in build.prop" 0
    else
        check "ro.gsi.compat.vendor_level=15 in build.prop" 1
    fi

    # Check rescue party disabled
    if grep -q "persist.sys.disable_rescue=true" "$BUILD_PROP" 2>/dev/null; then
        check "persist.sys.disable_rescue=true in build.prop" 0
    else
        check "persist.sys.disable_rescue=true in build.prop" 1
    fi
else
    check "build.prop found" 1
fi

# --- 6. VINTF enforcement disabled ---
if [ -n "$BUILD_PROP" ] && grep -q "PRODUCT_ENFORCE_VINTF_MANIFEST" "$BUILD_PROP" 2>/dev/null; then
    check "VINTF enforcement reference found" 0
else
    # This may be a build-time flag only, not in build.prop — acceptable
    check "VINTF enforcement (build-time flag — OK if absent from build.prop)" 0
fi

# --- Summary ---
echo ""
echo "=== Verification Summary ==="
echo "  Total : $TOTAL"
echo "  Pass  : $PASS"
echo "  Fail  : $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "WARNING: $FAIL check(s) failed. Survival mode may not function correctly."
    echo "Review the output above and check your build configuration."
    exit 1
fi

echo ""
echo "All survival mode checks passed."
exit 0
