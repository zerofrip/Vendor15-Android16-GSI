#!/bin/bash
# ============================================================
# validate_patches.sh
# Pre-flight validation of all patches against the AOSP tree
# ============================================================
#
# Usage:
#   validate_patches.sh <AOSP_ROOT> <PATCHES_DIR>
#
# Performs a dry-run (--check) of every .patch file to detect
# stale or broken patches before committing to a full build.
#
# Exit codes:
#   0 = all patches apply cleanly
#   1 = one or more patches failed
# ============================================================

set -euo pipefail

ROOT_DIR="${1:-}"
PATCHES_DIR="${2:-}"

if [ -z "$ROOT_DIR" ] || [ -z "$PATCHES_DIR" ]; then
    echo "Usage: validate_patches.sh <AOSP_ROOT> <PATCHES_DIR>"
    exit 1
fi

if [ ! -d "$ROOT_DIR" ]; then
    echo "Error: AOSP root '$ROOT_DIR' does not exist."
    exit 1
fi

if [ ! -d "$PATCHES_DIR" ]; then
    echo "Error: Patches directory '$PATCHES_DIR' does not exist."
    exit 1
fi

echo "=== Patch Validation (dry-run) ==="
echo "AOSP Root  : $ROOT_DIR"
echo "Patches Dir: $PATCHES_DIR"
echo ""

TOTAL=0
PASS=0
FAIL=0
SKIP=0

while IFS= read -r patch_file; do
    TOTAL=$((TOTAL + 1))
    rel_path="${patch_file#$PATCHES_DIR/}"
    project_path=$(dirname "$rel_path")
    target_dir="$ROOT_DIR/$project_path"

    if [ ! -d "$target_dir" ]; then
        echo "  SKIP: $rel_path (target dir '$project_path' not in tree)"
        SKIP=$((SKIP + 1))
        continue
    fi

    if (cd "$target_dir" && git apply --check "$patch_file" 2>/dev/null); then
        echo "  PASS: $rel_path"
        PASS=$((PASS + 1))
    else
        # Try patch --dry-run as fallback
        if (cd "$target_dir" && patch -p1 --dry-run < "$patch_file" >/dev/null 2>&1); then
            echo "  PASS: $rel_path (via patch --dry-run)"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $rel_path"
            FAIL=$((FAIL + 1))
        fi
    fi
done < <(find "$PATCHES_DIR" -type f -name "*.patch" | sort)

echo ""
echo "=== Validation Summary ==="
echo "  Total : $TOTAL"
echo "  Pass  : $PASS"
echo "  Fail  : $FAIL"
echo "  Skip  : $SKIP"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "ERROR: $FAIL patch(es) failed validation."
    echo "These patches may be stale or incompatible with the current AOSP tree."
    exit 1
fi

if [ "$TOTAL" -eq 0 ]; then
    echo ""
    echo "WARNING: No .patch files found in $PATCHES_DIR"
    exit 0
fi

echo ""
echo "All patches validated successfully."
exit 0
