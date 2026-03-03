#!/bin/bash
# ============================================================
# verify_survival.sh
# Post-build verification of Vendor15 Survival Mode integration
# ============================================================
#
# Usage:
#   verify_survival.sh [PRODUCT_OUT]
#
# Validates that the built system image contains all survival
# mode files, properties, chain signals, and configurations.
# Run after 'm systemimage'.
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

# Resolve system directory (handles nested or flat layout)
SYSTEM_DIR="$PRODUCT_OUT/system"
find_file() {
    local fname="$1"
    for path in "$SYSTEM_DIR/system/$fname" "$SYSTEM_DIR/$fname"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# ============================================================
# 1. System Image
# ============================================================
echo "--- [1/7] System Image ---"
if [ -f "$PRODUCT_OUT/system.img" ]; then
    check "system.img exists" 0
else
    check "system.img exists" 1
    echo ""
    echo "FATAL: system.img not found. Build may have failed."
    exit 1
fi

# ============================================================
# 2. Boot Gate Files
# ============================================================
echo ""
echo "--- [2/7] Boot Gate Files ---"

if find_file "etc/init/gsi_survival.rc" >/dev/null 2>&1; then
    check "gsi_survival.rc installed" 0
else
    check "gsi_survival.rc installed" 1
fi

local_path=$(find_file "bin/gsi_survival_check.sh" 2>/dev/null || echo "")
if [ -n "$local_path" ]; then
    if [ -x "$local_path" ]; then
        check "gsi_survival_check.sh installed & executable" 0
    else
        check "gsi_survival_check.sh installed & executable (not executable)" 1
    fi
else
    check "gsi_survival_check.sh installed" 1
fi

# ============================================================
# 3. Compatibility Matrix
# ============================================================
echo ""
echo "--- [3/7] Compatibility Matrix ---"

found_matrix=0
for path in \
    "$SYSTEM_DIR/system/etc/vintf/compatibility_matrix.xml" \
    "$SYSTEM_DIR/etc/vintf/compatibility_matrix.xml" \
    "$SYSTEM_DIR/system/etc/vintf/compatibility_matrix_vendor15_frozen.xml" \
    "$SYSTEM_DIR/etc/vintf/compatibility_matrix_vendor15_frozen.xml"; do
    if [ -f "$path" ]; then
        found_matrix=1

        # Validate XML is parseable
        python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$path')
root = tree.getroot()
# Check all HALs are optional
hals = root.findall('hal')
non_optional = [h.find('name').text for h in hals if h.get('optional') != 'true' and h.find('name') is not None]
if non_optional:
    print(f'  WARNING: {len(non_optional)} non-optional HALs: {non_optional[:5]}')
else:
    print(f'  {len(hals)} HALs, all optional')
" 2>/dev/null || echo "  WARNING: Could not parse matrix XML"

        break
    fi
done
check "Frozen compatibility matrix in VINTF" "$((1 - found_matrix))"

# ============================================================
# 4. 7-Layer Mitigation Chain (init.rc + scripts)
# ============================================================
echo ""
echo "--- [4/7] Mitigation Chain Files ---"

# All 8 .rc files that must be present
RC_FILES=(
    "gsi_survival.rc"
    "gsi_boot_safety.rc"
    "gsi_gpu_stability.rc"
    "gsi_hal_mitigations.rc"
    "gsi_app_compat.rc"
    "gsi_forward_compat.rc"
    "gsi_hal_probe.rc"
    "gsi_diagnostics.rc"
)

for rc in "${RC_FILES[@]}"; do
    if find_file "etc/init/$rc" >/dev/null 2>&1; then
        check "$rc installed" 0
    else
        check "$rc installed" 1
    fi
done

# All 7 runtime scripts
SCRIPTS=(
    "boot_safety.sh"
    "gpu_stability.sh"
    "hal_gap_mitigations.sh"
    "app_compat_mitigations.sh"
    "forward_compat.sh"
    "hal_probe.sh"
    "survival_diagnostics.sh"
)

for script in "${SCRIPTS[@]}"; do
    local_path=$(find_file "bin/$script" 2>/dev/null || echo "")
    if [ -n "$local_path" ]; then
        if [ -x "$local_path" ]; then
            check "$script installed & executable" 0
        else
            check "$script installed (NOT executable)" 1
        fi
    else
        check "$script installed" 1
    fi
done

# ============================================================
# 5. Chain Integrity (signal validation)
# ============================================================
echo ""
echo "--- [5/7] Chain Signal Integrity ---"

# Verify each .rc triggers the correct next service
verify_chain_link() {
    local rc_file="$1"
    local trigger_prop="$2"
    local next_action="$3"
    local rc_path
    rc_path=$(find_file "etc/init/$rc_file" 2>/dev/null || echo "")
    if [ -n "$rc_path" ]; then
        if grep -q "$trigger_prop" "$rc_path" 2>/dev/null && \
           grep -q "$next_action" "$rc_path" 2>/dev/null; then
            check "$rc_file: $trigger_prop → $next_action" 0
        else
            check "$rc_file: chain signal broken" 1
        fi
    else
        check "$rc_file: file missing (cannot verify chain)" 1
    fi
}

verify_chain_link "gsi_boot_safety.rc"    "boot_safety_done"    "gsi_gpu_stability"
verify_chain_link "gsi_gpu_stability.rc"   "gpu_stability_done"  "gsi_hal_mitigations"
verify_chain_link "gsi_hal_mitigations.rc" "hal_mitigations_done" "gsi_app_compat"
verify_chain_link "gsi_app_compat.rc"      "app_compat_done"     "gsi_forward_compat"
verify_chain_link "gsi_forward_compat.rc"  "forward_compat_done" "gsi_hal_probe"
verify_chain_link "gsi_hal_probe.rc"       "hal_probe_done"      "gsi_diagnostics"
verify_chain_link "gsi_diagnostics.rc"     "diagnostics_done"    "all_mitigations_done"

# ============================================================
# 6. Build Properties
# ============================================================
echo ""
echo "--- [6/7] Build Properties ---"

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

    for prop_check in \
        "ro.gsi.compat.survival_mode=true" \
        "ro.gsi.compat.vendor_level=15" \
        "persist.sys.disable_rescue=true"; do
        if grep -q "$prop_check" "$BUILD_PROP" 2>/dev/null; then
            check "$prop_check" 0
        else
            check "$prop_check" 1
        fi
    done
else
    check "build.prop found" 1
fi

# ============================================================
# 7. Supporting Files
# ============================================================
echo ""
echo "--- [7/7] Supporting Files ---"

# GPU Vulkan blocklist
if find_file "etc/gpu_vulkan_blocklist.cfg" >/dev/null 2>&1 || \
   find_file "bin/gpu_vulkan_blocklist.cfg" >/dev/null 2>&1; then
    check "GPU Vulkan blocklist installed" 0
else
    check "GPU Vulkan blocklist installed" 1
fi

# ============================================================
# Summary
# ============================================================
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
