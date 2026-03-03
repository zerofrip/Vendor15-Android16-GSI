#!/bin/bash
set -euo pipefail
# ============================================================
# apply_sepolicy_overlays.sh
# Vendor15 GSI — SELinux Policy Overlay Applicator
# ============================================================
#
# Copies selected SELinux policy overlay files into the AOSP
# build tree's sepolicy directory so they are compiled into
# the system image.
#
# Usage:
#   bash scripts/apply_sepolicy_overlays.sh <aosp_root> <mode>
#
# Modes:
#   minimal     — Only minimal_compat.te (survival scripts)
#   hal         — minimal + hal_relax + wifi + camera + binder
#   permissive  — No policy overlay, just flag for permissive
#   debug       — Same as permissive + AVC logging enabled
#
# Safety:
#   - Never modifies original AOSP sepolicy files
#   - Adds overlay files to a dedicated directory
#   - Reversible: delete the overlay directory to undo
# ============================================================

AOSP_ROOT="${1:?Usage: apply_sepolicy_overlays.sh <aosp_root> <mode>}"
MODE="${2:-minimal}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAY_SRC="$PROJECT_ROOT/sepolicy/overlays"
OVERLAY_DST="$AOSP_ROOT/system/sepolicy/vendor/vendor15"

echo "=== SELinux Policy Overlay Applicator ==="
echo "  AOSP root:  $AOSP_ROOT"
echo "  Mode:       $MODE"
echo "  Source:     $OVERLAY_SRC"
echo "  Target:     $OVERLAY_DST"
echo ""

# Validate source
if [ ! -d "$OVERLAY_SRC" ]; then
    echo "Error: Overlay directory not found: $OVERLAY_SRC"
    exit 1
fi

# Validate AOSP root
if [ ! -d "$AOSP_ROOT/system/sepolicy" ]; then
    echo "Error: AOSP sepolicy directory not found: $AOSP_ROOT/system/sepolicy"
    exit 1
fi

# Clean previous overlays
if [ -d "$OVERLAY_DST" ]; then
    echo "Cleaning previous overlays..."
    rm -rf "$OVERLAY_DST"
fi
mkdir -p "$OVERLAY_DST"

# Copy overlays based on mode
case "$MODE" in
    minimal)
        echo "Applying MINIMAL overlay (survival scripts only)..."
        cp -v "$OVERLAY_SRC/minimal_compat.te" "$OVERLAY_DST/"
        echo ""
        echo "SELinux: ENFORCING with minimal compatibility overlay"
        ;;

    hal)
        echo "Applying HAL overlay (minimal + all HAL relaxations)..."
        for te in minimal_compat.te hal_relax.te wifi_relax.te camera_relax.te binder_relax.te; do
            if [ -f "$OVERLAY_SRC/$te" ]; then
                cp -v "$OVERLAY_SRC/$te" "$OVERLAY_DST/"
            else
                echo "  WARNING: $te not found, skipping"
            fi
        done
        echo ""
        echo "SELinux: ENFORCING with HAL relaxation overlays"
        echo "  ⚠  binder_relax.te is HIGH risk — review rules carefully"
        ;;

    permissive)
        echo "SELinux: PERMISSIVE mode"
        echo ""
        echo "  ⚠  WARNING: This disables SELinux enforcement entirely."
        echo "  ⚠  This is UNSAFE and should only be used for debugging."
        echo "  ⚠  The system will set 'androidboot.selinux=permissive'"
        echo ""
        # No policy files needed — permissive is set via kernel cmdline
        # or build property
        ;;

    debug)
        echo "SELinux: DEBUG mode (permissive + AVC logging)"
        echo ""
        echo "  ⚠  WARNING: Same as permissive but enables verbose AVC logging."
        echo "  ⚠  After booting, run: scripts/parse_avc_denials.sh"
        echo ""
        ;;

    *)
        echo "Error: Unknown mode '$MODE'"
        echo "Valid modes: minimal, hal, permissive, debug"
        exit 1
        ;;
esac

# Validate .te file syntax (basic check)
echo ""
echo "Validating overlay syntax..."
VALID=0
TOTAL=0
for te in "$OVERLAY_DST"/*.te; do
    if [ -f "$te" ]; then
        TOTAL=$((TOTAL + 1))
        basename="$(basename "$te")"
        # Check for obvious syntax errors
        if grep -qE '^[[:space:]]*(allow|neverallow|type|attribute|typeattribute)' "$te" 2>/dev/null; then
            echo "  PASS: $basename"
            VALID=$((VALID + 1))
        else
            echo "  WARN: $basename — no standard policy statements found"
        fi
    fi
done

if [ "$TOTAL" -gt 0 ]; then
    echo ""
    echo "Validated $VALID/$TOTAL overlay files."
fi

echo ""
echo "=== Overlay application complete ==="
echo "  Files installed to: $OVERLAY_DST"
echo "  To undo: rm -rf $OVERLAY_DST"
