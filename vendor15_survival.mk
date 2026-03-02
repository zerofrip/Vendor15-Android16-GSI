# ============================================================
# vendor15_survival.mk
# Vendor15 Compatibility Lifetime Extension — Build Integration
# ============================================================
#
# This makefile installs the survival mode files into the GSI
# system image. It is included from device/phh/treble/base.mk
# via a patch applied during the build process.
#
# Files installed:
#   compatibility_matrix_vendor15_frozen.xml
#       → system/etc/vintf/compatibility_matrix.xml (override)
#   gsi_survival.rc
#       → system/etc/init/gsi_survival.rc
#   gsi_survival_check.sh
#       → system/bin/gsi_survival_check.sh
# ============================================================

# -----------------------------------------------------------
# 1. Frozen Compatibility Matrix (FCM override)
#    Replaces the stock framework compatibility matrix so that
#    VINTF checks pass against Vendor15 HAL versions.
# -----------------------------------------------------------
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += \
    device/phh/treble/vendor15/compatibility_matrix_vendor15_frozen.xml

# -----------------------------------------------------------
# 2. Survival init script + boot gate shell script
#    gsi_survival.rc is auto-discovered by init from
#    /system/etc/init/ — no explicit import needed.
# -----------------------------------------------------------
PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/gsi_survival.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_survival.rc \
    device/phh/treble/vendor15/gsi_survival_check.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/gsi_survival_check.sh

# -----------------------------------------------------------
# 3. System properties for survival mode
# -----------------------------------------------------------
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.gsi.compat.vendor_level=15 \
    ro.gsi.compat.survival_mode=true \
    persist.sys.disable_rescue=true

# -----------------------------------------------------------
# 4. Disable VINTF enforcement at build level
# -----------------------------------------------------------
PRODUCT_ENFORCE_VINTF_MANIFEST := false

# -----------------------------------------------------------
# 5. GPU Stability — conservative GPU fallbacks
# -----------------------------------------------------------
include device/phh/treble/vendor15/gpu_stability.mk

# -----------------------------------------------------------
# 6. HAL Gap Mitigations — conservative HAL fallbacks
# -----------------------------------------------------------
include device/phh/treble/vendor15/hal_gap_mitigations.mk

# -----------------------------------------------------------
# 7. App Compatibility — conservative app-facing defaults
# -----------------------------------------------------------
include device/phh/treble/vendor15/app_compat_mitigations.mk
