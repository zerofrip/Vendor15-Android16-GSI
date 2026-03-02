#!/bin/bash
# ============================================================
# verify_aidl_only.sh
# Post-patch verification: AIDL-only compliance check
# ============================================================
#
# Scans the TrebleDroid device tree (after patches are applied)
# to verify no HIDL, hwbinder, or hwservicemanager dependencies
# remain in configuration files.
#
# Usage:
#   verify_aidl_only.sh [DEVICE_TREE_ROOT]
#
# If DEVICE_TREE_ROOT is not specified, auto-detects from
# device/phh/treble/ relative to CWD.
#
# Exit codes:
#   0 = all checks pass (AIDL-only compliant)
#   1 = one or more HIDL references found
# ============================================================

set -euo pipefail

DEVICE_TREE="${1:-}"

# Auto-detect device tree root
if [ -z "$DEVICE_TREE" ]; then
    if [ -d "device/phh/treble" ]; then
        DEVICE_TREE="device/phh/treble"
    elif [ -d "trebledroid/device_phh_treble" ]; then
        DEVICE_TREE="trebledroid/device_phh_treble"
    else
        echo "Error: Could not find device tree."
        echo "Usage: verify_aidl_only.sh [DEVICE_TREE_ROOT]"
        exit 1
    fi
fi

echo "=== AIDL-Only Compliance Verification ==="
echo "Device tree: $DEVICE_TREE"
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

# --- 1. No hwbinder transport in manifest XMLs ---
echo "--- Checking manifest XMLs for hwbinder transport ---"
hwbinder_hits=$(grep -rl '<transport>hwbinder</transport>' "$DEVICE_TREE" \
    --include="*.xml" 2>/dev/null || true)
if [ -z "$hwbinder_hits" ]; then
    check "No <transport>hwbinder</transport> in manifest XMLs" 0
else
    check "No <transport>hwbinder</transport> in manifest XMLs" 1
    echo "    Found in:"
    echo "$hwbinder_hits" | sed 's/^/      /'
fi

# --- 2. No format="hidl" in any XML ---
echo "--- Checking for format=\"hidl\" in XMLs ---"
hidl_format_hits=$(grep -rl 'format="hidl"' "$DEVICE_TREE" \
    --include="*.xml" 2>/dev/null || true)
if [ -z "$hidl_format_hits" ]; then
    check "No format=\"hidl\" in any XML" 0
else
    check "No format=\"hidl\" in any XML" 1
    echo "    Found in:"
    echo "$hidl_format_hits" | sed 's/^/      /'
fi

# --- 3. No HIDL fqname references (@N.N::) in manifests ---
echo "--- Checking for HIDL fqname references (@N.N::) ---"
fqname_hits=$(grep -rn '@[0-9]\+\.[0-9]\+::' "$DEVICE_TREE" \
    --include="*.xml" 2>/dev/null || true)
if [ -z "$fqname_hits" ]; then
    check "No HIDL fqname references (@N.N::) in XMLs" 0
else
    check "No HIDL fqname references (@N.N::) in XMLs" 1
    echo "    Found:"
    echo "$fqname_hits" | sed 's/^/      /'
fi

# --- 4. No android.hidl.manager in PRODUCT_PACKAGES ---
echo "--- Checking base.mk for HIDL manager package ---"
if [ -f "$DEVICE_TREE/base.mk" ]; then
    hidl_pkg=$(grep -n 'android\.hidl\.manager' "$DEVICE_TREE/base.mk" 2>/dev/null || true)
    if [ -z "$hidl_pkg" ]; then
        check "No android.hidl.manager in PRODUCT_PACKAGES" 0
    else
        check "No android.hidl.manager in PRODUCT_PACKAGES" 1
        echo "    Found: $hidl_pkg"
    fi
else
    check "No android.hidl.manager in PRODUCT_PACKAGES (base.mk not found — skipped)" 0
fi

# --- 5. No HIDL fingerprint compat services ---
echo "--- Checking base.mk for HIDL fingerprint compat services ---"
if [ -f "$DEVICE_TREE/base.mk" ]; then
    fp_compat=$(grep -n 'fingerprint@2\.1-service.*compat' "$DEVICE_TREE/base.mk" 2>/dev/null || true)
    if [ -z "$fp_compat" ]; then
        check "No HIDL fingerprint compat services in base.mk" 0
    else
        check "No HIDL fingerprint compat services in base.mk" 1
        echo "    Found: $fp_compat"
    fi
else
    check "No HIDL fingerprint compat services (base.mk not found — skipped)" 0
fi

# --- 6. No HIDL library registrations in interfaces.xml ---
echo "--- Checking interfaces.xml for HIDL library registrations ---"
if [ -f "$DEVICE_TREE/interfaces.xml" ]; then
    hidl_libs=$(grep -n 'android\.hidl\.' "$DEVICE_TREE/interfaces.xml" 2>/dev/null || true)
    if [ -z "$hidl_libs" ]; then
        check "No android.hidl.* in interfaces.xml" 0
    else
        check "No android.hidl.* in interfaces.xml" 1
        echo "    Found: $hidl_libs"
    fi
else
    check "No android.hidl.* in interfaces.xml (file not found — OK)" 0
fi

# --- 7. No mandatory HALs in compatibility matrix (if present) ---
echo "--- Checking compatibility matrix for mandatory HALs ---"
compat_matrix=""
for candidate in \
    "compatibility_matrix_vendor15_frozen.xml" \
    "$DEVICE_TREE/vendor15/compatibility_matrix_vendor15_frozen.xml"; do
    if [ -f "$candidate" ]; then
        compat_matrix="$candidate"
        break
    fi
done

if [ -n "$compat_matrix" ]; then
    # Check for <hal> entries without optional="true"
    # Match <hal format="aidl"> (no optional) but exclude comment lines
    mandatory_hals=$(grep -n '<hal ' "$compat_matrix" | grep -v 'optional="true"' | grep -v '<!--' || true)
    if [ -z "$mandatory_hals" ]; then
        check "All HALs in compatibility matrix are optional" 0
    else
        # Native/passthrough HALs may legitimately lack optional — check
        non_native=$(echo "$mandatory_hals" | grep -v 'format="native"' || true)
        if [ -z "$non_native" ]; then
            check "All binder HALs in compatibility matrix are optional (native HALs excluded)" 0
        else
            check "All binder HALs in compatibility matrix are optional" 1
            echo "    Mandatory HALs found:"
            echo "$non_native" | sed 's/^/      /'
        fi
    fi
else
    check "Compatibility matrix check (file not found — skipped)" 0
fi

# --- Summary ---
echo ""
echo "=== AIDL-Only Compliance Summary ==="
echo "  Total : $TOTAL"
echo "  Pass  : $PASS"
echo "  Fail  : $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "WARNING: $FAIL check(s) failed. HIDL/hwbinder references remain."
    echo "These may cause boot failures on AIDL-only Vendor15 targets."
    exit 1
fi

echo ""
echo "All checks passed. Device tree is AIDL-only compliant."
exit 0
