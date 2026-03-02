#!/bin/bash
set -e

# ============================================================
# Android 16 GSI Builder — Vendor15 Compatibility Extension
# ============================================================
# Build acceleration: ccache, local AOSP source, local TrebleDroid
# Survival design: frozen FCM, upgrade-only, VINTF bypass
# ============================================================

# ======================== Error Handler ========================
BUILD_START=$(date +%s)

on_error() {
    local exit_code=$?
    local line_no=$1
    local duration=$(( $(date +%s) - BUILD_START ))
    echo ""
    echo "=== BUILD FAILED ==="
    echo "  Exit code : $exit_code"
    echo "  Failed at : line $line_no"
    echo "  Duration  : $((duration / 60))m $((duration % 60))s"
    echo "  Script    : $0"
    echo ""
    echo "  Hint: Review the output above for the actual error."
    echo "  Common causes:"
    echo "    - Patch failed to apply (stale patch vs. AOSP revision)"
    echo "    - Missing build dependencies"
    echo "    - Source sync failure"
    echo "    - Lunch target mismatch"
    echo "==================="
    exit $exit_code
}

trap 'on_error $LINENO' ERR

# ======================== Configuration ========================
ANDROID_VERSION="android-16.0.0_r1"
ANDROID_MAJOR_VERSION="16"
WORK_DIR=$(pwd)
PATCHES_DIR="$WORK_DIR/patches"
SCRIPTS_DIR="$WORK_DIR/scripts"
LUNCH_TARGET="${LUNCH_TARGET:-treble_arm64_bvN-userdebug}"

# ccache: configurable size (default 50G), auto-enabled if present
CCACHE_SIZE="${CCACHE_SIZE:-50G}"
CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"

# Local source overrides (set externally or auto-detected)
#   ANDROID_SRC  — path to existing AOSP checkout
#   TREBLEDROID_SRC — path to existing TrebleDroid repos
ANDROID_SRC="${ANDROID_SRC:-}"
TREBLEDROID_SRC="${TREBLEDROID_SRC:-}"

echo "=== Android $ANDROID_MAJOR_VERSION GSI Builder ==="
echo "Work Directory: $WORK_DIR"
echo "Lunch Target : $LUNCH_TARGET"
echo ""

# ======================== VNDK Compat =========================
export TARGET_ENABLE_VNDK_COMPAT=true
export TARGET_VENDOR_API_LEVEL=15
export TARGET_SYSTEM_API_LEVEL=$ANDROID_MAJOR_VERSION
export TARGET_VENDOR_PATH="$WORK_DIR/vendor"
echo "VNDK Compat: Enabled (v$TARGET_VENDOR_API_LEVEL -> v$TARGET_SYSTEM_API_LEVEL)"

# ======================== Part 1: ccache ======================

setup_ccache() {
    echo ""
    echo "=== Configuring ccache ==="

    # Find ccache binary
    local ccache_bin
    ccache_bin=$(command -v ccache 2>/dev/null || true)

    if [ -z "$ccache_bin" ]; then
        echo "ccache: not found in PATH. Compilation will proceed without cache."
        echo "  Install with: sudo apt-get install ccache"
        export USE_CCACHE=0
        return
    fi

    echo "ccache: found at $ccache_bin"

    # Enable for AOSP build system
    export USE_CCACHE=1
    export CCACHE_EXEC="$ccache_bin"
    export CCACHE_DIR
    export CCACHE_COMPRESS=1
    export CCACHE_COMPRESSLEVEL=1
    # Use content hash, not mtime — deterministic across git operations
    export CCACHE_SLOPPINESS="file_macro,time_macros,include_file_mtime,include_file_ctime"
    # Do NOT set CCACHE_HARDLINK — unsafe with AOSP's build system
    # Do NOT set CCACHE_NODIRECT — direct mode is safe and faster

    # Set cache size
    "$ccache_bin" -M "$CCACHE_SIZE" >/dev/null 2>&1 || true
    mkdir -p "$CCACHE_DIR" 2>/dev/null || true

    echo "ccache: enabled"
    echo "  CCACHE_DIR  = $CCACHE_DIR"
    echo "  CCACHE_SIZE = $CCACHE_SIZE"
    echo "  CCACHE_EXEC = $CCACHE_EXEC"

    # Print stats baseline (for CI diffing)
    echo "  Stats (pre-build):"
    "$ccache_bin" -s 2>/dev/null | grep -E "cache hit|cache miss|cache size" | sed 's/^/    /' || true
}

setup_ccache

# ======================== Part 2: Local AOSP Source ============

detect_local_aosp() {
    echo ""
    echo "=== Detecting Android Source ==="

    # Auto-detect candidates if ANDROID_SRC is not set
    if [ -z "$ANDROID_SRC" ]; then
        for candidate in \
            "../android-$ANDROID_MAJOR_VERSION" \
            "../android-${ANDROID_MAJOR_VERSION}.0" \
            "$HOME/android-$ANDROID_MAJOR_VERSION" \
            "$HOME/aosp-$ANDROID_MAJOR_VERSION"; do
            if [ -d "$candidate/.repo" ] || [ -f "$candidate/build/envsetup.sh" ]; then
                ANDROID_SRC="$(cd "$candidate" && pwd)"
                echo "Auto-detected local AOSP at: $ANDROID_SRC"
                break
            fi
        done
    fi

    # Validate the local source if found
    if [ -n "$ANDROID_SRC" ] && [ -d "$ANDROID_SRC" ]; then
        echo "Checking local AOSP: $ANDROID_SRC"

        # Must have build/envsetup.sh (basic sanity)
        if [ ! -f "$ANDROID_SRC/build/envsetup.sh" ]; then
            echo "  REJECTED: $ANDROID_SRC/build/envsetup.sh not found."
            echo "  Falling back to repo sync."
            ANDROID_SRC=""
            return
        fi

        # Version check: read PLATFORM_SDK_VERSION from build/core/version_defaults.mk
        local local_sdk=""
        if [ -f "$ANDROID_SRC/build/core/version_defaults.mk" ]; then
            local_sdk=$(grep -m1 'PLATFORM_SDK_VERSION\s*:=' \
                "$ANDROID_SRC/build/core/version_defaults.mk" 2>/dev/null \
                | sed 's/.*:=\s*//' | tr -d ' ' || true)
        fi

        if [ -z "$local_sdk" ]; then
            echo "  WARNING: Could not determine SDK version from local tree."
            echo "  Proceeding with local source (user explicitly set ANDROID_SRC)."
        else
            # Android 16 = SDK 36 (projected). Accept if in the right range.
            echo "  Local SDK version: $local_sdk"
        fi

        echo "  ACCEPTED: Using local AOSP at $ANDROID_SRC"
        echo ""
        USE_LOCAL_AOSP=1
    else
        echo "No local AOSP source detected."
        echo "Will use repo init / sync from network."
        USE_LOCAL_AOSP=0
    fi
}

detect_local_aosp

# ======================== Part 3: Local TrebleDroid Source ======

detect_local_trebledroid() {
    echo ""
    echo "=== Detecting TrebleDroid Source ==="

    # Auto-detect if TREBLEDROID_SRC is not set
    if [ -z "$TREBLEDROID_SRC" ]; then
        for candidate in \
            "../trebledroid" \
            "../device_phh_treble" \
            "$HOME/trebledroid"; do
            if [ -d "$candidate/device_phh_treble" ] || \
               [ -d "$candidate" ] && [ -f "$candidate/generate.sh" ]; then
                TREBLEDROID_SRC="$(cd "$candidate" && pwd)"
                echo "Auto-detected local TrebleDroid at: $TREBLEDROID_SRC"
                break
            fi
        done
    fi

    if [ -n "$TREBLEDROID_SRC" ] && [ -d "$TREBLEDROID_SRC" ]; then
        echo "Checking local TrebleDroid: $TREBLEDROID_SRC"

        # Determine layout: monorepo (has device_phh_treble subdir) vs single repo
        if [ -d "$TREBLEDROID_SRC/device_phh_treble" ]; then
            echo "  Layout: monorepo (device_phh_treble/, vendor_hardware_overlay/, treble_app/)"
            USE_LOCAL_TREBLEDROID=1
        elif [ -f "$TREBLEDROID_SRC/generate.sh" ]; then
            echo "  Layout: single device_phh_treble repo"
            # Wrap it so the rest of the script can use consistent paths
            USE_LOCAL_TREBLEDROID=2  # single-repo mode
        else
            echo "  REJECTED: No recognizable TrebleDroid structure."
            echo "  Falling back to git submodule."
            USE_LOCAL_TREBLEDROID=0
        fi
    else
        echo "No local TrebleDroid source detected."
        echo "Will use git submodule (bundled in repo)."
        USE_LOCAL_TREBLEDROID=0
    fi
}

detect_local_trebledroid

# ============================================================
# 1. AOSP Source — acquire or reuse
# ============================================================
echo ""
echo "=== Step 1: Android Source ==="

if [ "$USE_LOCAL_AOSP" = "1" ]; then
    echo "Using local AOSP at: $ANDROID_SRC"
    echo "Skipping repo init / repo sync."

    # Symlink (or verify we're already in) the AOSP tree
    # If build.sh is run from the builder repo and AOSP is elsewhere,
    # we need to operate inside the AOSP tree for the build.
    if [ "$ANDROID_SRC" != "$WORK_DIR" ]; then
        echo "Switching working directory to local AOSP: $ANDROID_SRC"
        cd "$ANDROID_SRC"
    fi
else
    # Standard repo init + sync
    if [ ! -d ".repo" ]; then
        echo "Initializing repo for $ANDROID_VERSION..."
        repo init -u https://android.googlesource.com/platform/manifest -b master --depth=1
    fi

    echo "Syncing source code..."
    repo sync -c -j$(nproc) --force-sync --no-clone-bundle --no-tags
fi

# ============================================================
# 2. TrebleDroid — acquire or reuse
# ============================================================
echo ""
echo "=== Step 2: TrebleDroid Setup ==="

if [ "$USE_LOCAL_TREBLEDROID" = "1" ]; then
    # Monorepo layout: link each sub-project
    echo "Using local TrebleDroid (monorepo): $TREBLEDROID_SRC"

    mkdir -p device/phh
    rm -rf device/phh/treble
    ln -sfn "$TREBLEDROID_SRC/device_phh_treble" device/phh/treble
    echo "  Linked: device/phh/treble -> $TREBLEDROID_SRC/device_phh_treble"

    mkdir -p vendor
    rm -rf vendor/hardware_overlay
    if [ -d "$TREBLEDROID_SRC/vendor_hardware_overlay" ]; then
        ln -sfn "$TREBLEDROID_SRC/vendor_hardware_overlay" vendor/hardware_overlay
        echo "  Linked: vendor/hardware_overlay"
    fi

    mkdir -p packages/apps
    rm -rf packages/apps/TrebleApp
    if [ -d "$TREBLEDROID_SRC/treble_app" ]; then
        ln -sfn "$TREBLEDROID_SRC/treble_app" packages/apps/TrebleApp
        echo "  Linked: packages/apps/TrebleApp"
    fi

elif [ "$USE_LOCAL_TREBLEDROID" = "2" ]; then
    # Single device_phh_treble repo
    echo "Using local TrebleDroid (single repo): $TREBLEDROID_SRC"

    mkdir -p device/phh
    rm -rf device/phh/treble
    ln -sfn "$TREBLEDROID_SRC" device/phh/treble
    echo "  Linked: device/phh/treble -> $TREBLEDROID_SRC"

else
    # Default: use bundled git submodules
    echo "Using bundled TrebleDroid submodules..."
    (cd "$WORK_DIR" && git submodule update --init --recursive)

    mkdir -p device/phh
    rm -rf device/phh/treble
    ln -sfn "$WORK_DIR/trebledroid/device_phh_treble" device/phh/treble

    mkdir -p vendor
    rm -rf vendor/hardware_overlay
    ln -sfn "$WORK_DIR/trebledroid/vendor_hardware_overlay" vendor/hardware_overlay

    mkdir -p packages/apps
    rm -rf packages/apps/TrebleApp
    ln -sfn "$WORK_DIR/trebledroid/treble_app" packages/apps/TrebleApp
fi

# Generate TrebleDroid Makefiles
echo "Generating TrebleDroid makefiles..."
if [ -f "device/phh/treble/generate.sh" ]; then
    bash device/phh/treble/generate.sh
else
    echo "Warning: device/phh/treble/generate.sh not found!"
fi

# ============================================================
# 3. Stage Vendor15 Survival Mode Files (UNCONDITIONAL)
# ============================================================
# These files are always installed regardless of ccache or
# local source settings. The survival design must not be
# bypassable.
# ============================================================
echo ""
echo "=== Step 3: Staging Vendor15 Survival Mode Files ==="
SURVIVAL_DIR="device/phh/treble/vendor15"
mkdir -p "$SURVIVAL_DIR"

cp -v "$WORK_DIR/compatibility_matrix_vendor15_frozen.xml" \
      "$SURVIVAL_DIR/compatibility_matrix_vendor15_frozen.xml"

cp -v "$WORK_DIR/gsi_survival.rc" \
      "$SURVIVAL_DIR/gsi_survival.rc"

cp -v "$WORK_DIR/gsi_survival_check.sh" \
      "$SURVIVAL_DIR/gsi_survival_check.sh"
chmod 755 "$SURVIVAL_DIR/gsi_survival_check.sh"

cp -v "$WORK_DIR/vendor15_survival.mk" \
      "$SURVIVAL_DIR/vendor15_survival.mk"

echo "Survival files staged to $SURVIVAL_DIR"

# --- GPU Stability files ---
echo ""
echo "--- Staging GPU Stability Files ---"

cp -v "$WORK_DIR/gpu_stability.sh" \
      "$SURVIVAL_DIR/gpu_stability.sh"
chmod 755 "$SURVIVAL_DIR/gpu_stability.sh"

cp -v "$WORK_DIR/gsi_gpu_stability.rc" \
      "$SURVIVAL_DIR/gsi_gpu_stability.rc"

cp -v "$WORK_DIR/gpu_vulkan_blocklist.cfg" \
      "$SURVIVAL_DIR/gpu_vulkan_blocklist.cfg"

cp -v "$WORK_DIR/gpu_stability.mk" \
      "$SURVIVAL_DIR/gpu_stability.mk"

echo "GPU stability files staged to $SURVIVAL_DIR"

# --- HAL Gap Mitigation files ---
echo ""
echo "--- Staging HAL Gap Mitigation Files ---"

cp -v "$WORK_DIR/hal_gap_mitigations.sh" \
      "$SURVIVAL_DIR/hal_gap_mitigations.sh"
chmod 755 "$SURVIVAL_DIR/hal_gap_mitigations.sh"

cp -v "$WORK_DIR/gsi_hal_mitigations.rc" \
      "$SURVIVAL_DIR/gsi_hal_mitigations.rc"

cp -v "$WORK_DIR/hal_gap_mitigations.mk" \
      "$SURVIVAL_DIR/hal_gap_mitigations.mk"

echo "HAL gap mitigation files staged to $SURVIVAL_DIR"

# ============================================================
# 4. Apply Patches (unconditional)
# ============================================================
echo ""
echo "=== Step 4: Applying Patches ==="
if [ -f "$SCRIPTS_DIR/apply_patches.sh" ]; then
    bash "$SCRIPTS_DIR/apply_patches.sh" "$(pwd)" "$PATCHES_DIR"
else
    echo "Error: apply_patches.sh not found!"
    exit 1
fi

# ============================================================
# 5. Build
# ============================================================
echo ""
echo "=== Step 5: Building GSI ==="
echo "Setting up build environment..."
source build/envsetup.sh

echo "Lunching $LUNCH_TARGET..."
lunch $LUNCH_TARGET

echo "Starting Build..."
m systemimage

BUILD_END=$(date +%s)
BUILD_DURATION=$(( BUILD_END - BUILD_START ))

echo ""
echo "=== Build Complete! ==="
echo "  Duration: $((BUILD_DURATION / 60))m $((BUILD_DURATION % 60))s"
echo "  Started : $(date -d @$BUILD_START '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $BUILD_START '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
ls -lh out/target/product/*/system.img 2>/dev/null || \
    ls -lh out/target/product/treble_arm64_bvN/system.img

# Print ccache stats delta if enabled
if [ "${USE_CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
    echo ""
    echo "=== ccache stats (post-build) ==="
    ccache -s 2>/dev/null | grep -E "cache hit|cache miss|cache size" | sed 's/^/  /' || true
fi

# ============================================================
# 6. Post-Build Verification
# ============================================================
echo ""
echo "=== Step 6: Verifying Survival Mode Integration ==="
if [ -f "$SCRIPTS_DIR/verify_survival.sh" ]; then
    bash "$SCRIPTS_DIR/verify_survival.sh" || \
        echo "WARNING: Survival mode verification reported issues. Review output above."
else
    echo "Warning: verify_survival.sh not found. Skipping post-build verification."
fi
