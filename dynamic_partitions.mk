# ============================================================
# dynamic_partitions.mk
# Vendor15 GSI — Dynamic Partition Support
# ============================================================
#
# Split into two tiers:
#
# ALWAYS INCLUDED (via vendor15_survival.mk):
#   - Detection script installed to /system/bin/
#   - Informational property ro.gsi.dp.aware=true
#   These are read-only and zero-risk.
#
# OPT-IN ONLY (via --dynamic flag):
#   - PRODUCT_USE_DYNAMIC_PARTITIONS
#   - BOARD_SUPER_PARTITION_SIZE
#   - BOARD_BUILD_SYSTEM_ROOT_IMAGE
#   These are device-specific and should NOT be set
#   unconditionally in a GSI build.
#
# Rationale:
#   A GSI system.img is partition-scheme-agnostic. The partition
#   layout (dynamic vs static) is a DEVICE property determined by
#   the bootloader, fstab, and init first-stage. Setting
#   PRODUCT_USE_DYNAMIC_PARTITIONS in a GSI build only affects
#   super.img generation (which we don't ship) and
#   BOARD_BUILD_SYSTEM_ROOT_IMAGE (which can break legacy mounts).
# ============================================================

# --- Tier 1: Always safe (unconditional) ---
# Informational property — tells runtime scripts DP handling is available
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.gsi.dp.aware=true

# Detection script — read-only, runs on-device, never modifies partitions
PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/dynamic_partition_detect.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/dynamic_partition_detect.sh

# --- Tier 2: Device-specific (only with --dynamic) ---
# These flags are set by build.sh when --dynamic is passed.
# They export ENABLE_DYNAMIC_PARTITIONS=1 which triggers the
# conditional block below.
ifeq ($(ENABLE_DYNAMIC_PARTITIONS),1)

# GSI does not generate super.img, but some build paths
# require this to be set for logical partition awareness
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Post-system-as-root (all V15 devices are Android 15+)
BOARD_BUILD_SYSTEM_ROOT_IMAGE := false

# Default super size — override per-device if needed
BOARD_SUPER_PARTITION_SIZE ?= 8589934592

# Partition group definitions
BOARD_SUPER_PARTITION_GROUPS ?= vendor15_dynamic_partitions
BOARD_VENDOR15_DYNAMIC_PARTITIONS_PARTITION_LIST ?= system
BOARD_VENDOR15_DYNAMIC_PARTITIONS_SIZE ?= $(BOARD_SUPER_PARTITION_SIZE)

endif # ENABLE_DYNAMIC_PARTITIONS
