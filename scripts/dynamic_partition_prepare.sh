#!/bin/bash
set -euo pipefail
# ============================================================
# dynamic_partition_prepare.sh
# Vendor15 GSI — Dynamic Partition Flashing Preparation
# ============================================================
#
# Host-side script. Probes a connected device via ADB and
# generates the correct fastboot flashing commands for the
# device's partition layout.
#
# Usage:
#   bash scripts/dynamic_partition_prepare.sh [system.img path]
#
# Output:
#   Prints flashing instructions to stdout.
#   Does NOT execute any flashing commands.
#
# Safety:
#   - Read-only: only queries device, never writes
#   - Generates instructions for manual execution
#   - Warns on insufficient partition space
# ============================================================

ADB="${ADB:-adb}"
SYSTEM_IMG="${1:-out/target/product/treble_arm64_bvN/system.img}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}=== Dynamic Partition Flashing Preparation ===${NC}"
echo ""

# ============================================================
# 1. Check device connectivity
# ============================================================
if ! $ADB devices 2>/dev/null | grep -q "device$"; then
    echo -e "${RED}Error: No device connected via ADB.${NC}"
    echo "Connect device with 'adb' access and try again."
    exit 2
fi

DEVICE_MODEL=$($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')
DEVICE_SDK=$($ADB shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
echo "Device: $DEVICE_MODEL (SDK $DEVICE_SDK)"

# ============================================================
# 2. Detect partition scheme
# ============================================================
DP_ENABLED=$($ADB shell getprop ro.boot.dynamic_partitions 2>/dev/null | tr -d '\r')
AB_UPDATE=$($ADB shell getprop ro.build.ab_update 2>/dev/null | tr -d '\r')
DP_RETROFIT=$($ADB shell getprop ro.boot.dynamic_partitions_retrofit 2>/dev/null | tr -d '\r')
SLOT_SUFFIX=$($ADB shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')

echo ""
echo "Partition scheme:"
echo "  Dynamic partitions: ${DP_ENABLED:-false}"
echo "  A/B: ${AB_UPDATE:-false} (suffix: ${SLOT_SUFFIX:-none})"
echo "  Retrofit: ${DP_RETROFIT:-false}"

# ============================================================
# 3. Check system.img
# ============================================================
echo ""
if [ -f "$SYSTEM_IMG" ]; then
    IMG_SIZE=$(stat -c%s "$SYSTEM_IMG" 2>/dev/null || stat -f%z "$SYSTEM_IMG" 2>/dev/null || echo "0")
    IMG_SIZE_MB=$((IMG_SIZE / 1048576))
    echo -e "System image: ${GREEN}$SYSTEM_IMG${NC} (${IMG_SIZE_MB}MB)"
else
    echo -e "${YELLOW}Warning: $SYSTEM_IMG not found.${NC}"
    echo "  Build with: ./build.sh"
    echo "  Or specify path: bash $0 <path/to/system.img>"
    IMG_SIZE_MB=0
fi

# ============================================================
# 4. Generate flashing instructions
# ============================================================
echo ""
echo -e "${BOLD}=== Flashing Instructions ===${NC}"
echo ""

if [ "$DP_ENABLED" = "true" ]; then
    # --- Dynamic partition device ---
    echo -e "${CYAN}Device uses DYNAMIC PARTITIONS.${NC}"
    echo ""

    if [ "$DP_RETROFIT" = "true" ]; then
        # --- Retrofit dynamic partitions ---
        echo -e "${YELLOW}NOTE: Retrofit dynamic partitions detected.${NC}"
        echo "This device was originally MBR/GPT and uses super as a container."
        echo ""
        echo "Flashing commands (reboot to fastbootd first):"
        echo ""
        echo "  # Step 1: Reboot to fastbootd (NOT bootloader fastboot)"
        echo "  adb reboot fastboot"
        echo ""
        echo "  # Step 2: Delete existing system partition in super"
        echo "  fastboot delete-logical-partition system${SLOT_SUFFIX}"
        echo ""
        echo "  # Step 3: Create new system partition"
        if [ "$IMG_SIZE_MB" -gt 0 ]; then
            echo "  fastboot create-logical-partition system${SLOT_SUFFIX} $IMG_SIZE"
        else
            echo "  fastboot create-logical-partition system${SLOT_SUFFIX} <SIZE_BYTES>"
        fi
        echo ""
        echo "  # Step 4: Flash system image"
        echo "  fastboot flash system${SLOT_SUFFIX} $SYSTEM_IMG"
        echo ""
    else
        # --- Native dynamic partitions ---
        echo "Flashing commands (reboot to fastbootd first):"
        echo ""
        echo "  # Step 1: Reboot to fastbootd"
        echo "  adb reboot fastboot"
        echo ""

        if [ "$AB_UPDATE" = "true" ]; then
            # A/B device
            echo "  # Step 2: Flash system (A/B — uses current slot)"
            echo "  fastboot flash system $SYSTEM_IMG"
            echo ""
            echo "  # Step 3: Disable verity (required for GSI)"
            echo "  fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img"
            echo ""
            echo "  # Step 4: Wipe userdata (required on first GSI flash)"
            echo "  fastboot -w"
            echo ""
            echo "  # Step 5: Reboot"
            echo "  fastboot reboot"
        else
            # A-only device
            echo "  # Step 2: Delete and recreate system partition"
            echo "  fastboot delete-logical-partition system"
            if [ "$IMG_SIZE_MB" -gt 0 ]; then
                echo "  fastboot create-logical-partition system $IMG_SIZE"
            else
                echo "  fastboot create-logical-partition system <SIZE_BYTES>"
            fi
            echo ""
            echo "  # Step 3: Flash system"
            echo "  fastboot flash system $SYSTEM_IMG"
            echo ""
            echo "  # Step 4: Disable verity"
            echo "  fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img"
            echo ""
            echo "  # Step 5: Wipe userdata"
            echo "  fastboot -w"
            echo ""
            echo "  # Step 6: Reboot"
            echo "  fastboot reboot"
        fi
    fi
else
    # --- Legacy partition device ---
    echo -e "${CYAN}Device uses LEGACY (non-dynamic) partitions.${NC}"
    echo ""
    echo "Flashing commands (reboot to bootloader):"
    echo ""
    echo "  # Step 1: Reboot to bootloader"
    echo "  adb reboot bootloader"
    echo ""
    echo "  # Step 2: Flash system"
    echo "  fastboot flash system $SYSTEM_IMG"
    echo ""
    echo "  # Step 3: Disable verity"
    echo "  fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img"
    echo ""
    echo "  # Step 4: Wipe userdata"
    echo "  fastboot -w"
    echo ""
    echo "  # Step 5: Reboot"
    echo "  fastboot reboot"
fi

# ============================================================
# 5. Safety warnings
# ============================================================
echo ""
echo -e "${BOLD}=== Safety Notes ===${NC}"
echo ""
echo -e "  ${YELLOW}⚠${NC}  Vendor partition is NEVER modified by these commands"
echo -e "  ${YELLOW}⚠${NC}  First GSI flash requires userdata wipe (-w)"
echo -e "  ${YELLOW}⚠${NC}  Subsequent GSI updates do NOT need -w (data preserved)"
echo -e "  ${YELLOW}⚠${NC}  Always have stock firmware available for recovery"
echo ""

if [ "$IMG_SIZE_MB" -gt 4096 ]; then
    echo -e "  ${RED}⚠  WARNING: system.img is ${IMG_SIZE_MB}MB — may exceed super capacity${NC}"
fi

echo "Done. Review commands above before executing."
