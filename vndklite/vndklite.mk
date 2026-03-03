# ============================================================
# vndklite.mk
# Vendor15 GSI — VNDK-Lite Build Configuration
# ============================================================
#
# Included ONLY when build.sh is invoked with --vndklite.
# Configures the VNDK-Lite compatibility mode which allows
# vendor processes to load system libraries as fallback.
#
# Risks:
#   MEDIUM — Relaxing linker namespaces can cause symbol
#   conflicts if vendor and system provide different versions
#   of the same library. Monitor logcat for linker errors.
#
# When to enable:
#   When vendor partition's VNDK version doesn't match the
#   system's, and vendor processes crash with "library not found"
#   or "cannot locate symbol" errors.
#
# Reversible:
#   Remove this include from vendor15_survival.mk to disable.
# ============================================================

# --- Build-time VNDK properties ---
# These properties tell the system to be lenient about VNDK
# version mismatches at runtime.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.vndk.lite=true \
    ro.gsi.vndklite.enabled=true

# --- Install VNDK-Lite scripts ---
PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/vndklite_detect.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/vndklite_detect.sh \
    device/phh/treble/vendor15/vndklite_apply.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/vndklite_apply.sh

# --- Linker namespace configuration ---
# Install the relaxed linker config that allows vendor→system
# library loading. This is the VNDK-Lite linker namespace.
PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/ld.config.vndk_lite.txt:$(TARGET_COPY_OUT_SYSTEM)/etc/ld.config.vndk_lite.txt

# --- Ensure VNDK compat engine is enabled ---
# The existing VNDK compat module handles the heavy lifting;
# VNDK-Lite adds the linker namespace relaxation on top.
TARGET_ENABLE_VNDK_COMPAT ?= true
