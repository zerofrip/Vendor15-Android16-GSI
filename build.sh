#!/bin/bash
set -e

# Configuration
ANDROID_VERSION="android-16.0.0_r1" # Replace with actual tag when available, or master
WORK_DIR=$(pwd)
PATCHES_DIR="$WORK_DIR/patches"
SCRIPTS_DIR="$WORK_DIR/scripts"

echo "=== Android 16 GSI Builder ==="
echo "Work Directory: $WORK_DIR"

# VNDK Compatibility Framework Configuration
export TARGET_ENABLE_VNDK_COMPAT=true
export TARGET_VENDOR_API_LEVEL=15
export TARGET_SYSTEM_API_LEVEL=16
export TARGET_VENDOR_PATH="$WORK_DIR/vendor" # Adjust as needed for analysis

echo "VNDK Compat: Enabled (v$TARGET_VENDOR_API_LEVEL -> v$TARGET_SYSTEM_API_LEVEL)"

# 1. Initialize Repo
if [ ! -d ".repo" ]; then
    echo "Initializing repo for $ANDROID_VERSION..."
    # Using specific manifest for GSI if needed, or default AOSP
    repo init -u https://android.googlesource.com/platform/manifest -b master --depth=1
    # Note: 'master' is used as placeholder until android-16.0.0_rX is released.
    # Once released, change -b master to -b $ANDROID_VERSION
fi

# 2. Sync Source Code
echo "Syncing source code..."
repo sync -c -j$(nproc) --force-sync --no-clone-bundle --no-tags

# 2.5. Initialize Submodules
echo "Initializing TrebleDroid submodules..."
git submodule update --init --recursive

# 3. Link TrebleDroid Repos & Apply Patches
echo "Linking TrebleDroid repositories..."

# device/phh/treble
mkdir -p device/phh
rm -rf device/phh/treble
ln -sfn "$(pwd)/trebledroid/device_phh_treble" device/phh/treble

# vendor/hardware_overlay
mkdir -p vendor
rm -rf vendor/hardware_overlay
ln -sfn "$(pwd)/trebledroid/vendor_hardware_overlay" vendor/hardware_overlay

# packages/apps/TrebleApp
mkdir -p packages/apps
rm -rf packages/apps/TrebleApp
ln -sfn "$(pwd)/trebledroid/treble_app" packages/apps/TrebleApp

# Generate TrebleDroid Makefiles
echo "Generating TrebleDroid makefiles..."
if [ -f "device/phh/treble/generate.sh" ]; then
    bash device/phh/treble/generate.sh
else
    echo "Warning: device/phh/treble/generate.sh not found!"
fi

echo "Applying patches..."
if [ -f "$SCRIPTS_DIR/apply_patches.sh" ]; then
    bash "$SCRIPTS_DIR/apply_patches.sh" "$WORK_DIR" "$PATCHES_DIR"
else
    echo "Error: apply_patches.sh not found!"
    exit 1
fi

# 4. Environment Setup
echo "Setting up build environment..."
source build/envsetup.sh

# 5. Build GSI
# Usage: treble_arm64_bvN-userdebug
# b = arm64
# v = vanilla
# N = no su
LUNCH_TARGET="treble_arm64_bvN-userdebug" 

echo "Lunching $LUNCH_TARGET..."
lunch $LUNCH_TARGET

echo "Starting Build..."
m systemimage

echo "Build Complete!"
ls -lh out/target/product/treble_arm64_bvN/system.img
