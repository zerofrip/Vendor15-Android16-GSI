# ============================================================
# gpu_stability.mk
# Vendor15 GPU Stability — Build Integration
# ============================================================
#
# This makefile installs GPU stability files into the GSI
# system image. It is included from vendor15_survival.mk.
#
# Files installed:
#   gpu_stability.sh
#       → system/bin/gpu_stability.sh
#   gsi_gpu_stability.rc
#       → system/etc/init/gsi_gpu_stability.rc
#   gpu_vulkan_blocklist.cfg
#       → system/etc/gpu_vulkan_blocklist.cfg
# ============================================================

# -----------------------------------------------------------
# 1. GPU stability runtime script + init trigger
# -----------------------------------------------------------
PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/gpu_stability.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/gpu_stability.sh \
    device/phh/treble/vendor15/gsi_gpu_stability.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_gpu_stability.rc \
    device/phh/treble/vendor15/gpu_vulkan_blocklist.cfg:$(TARGET_COPY_OUT_SYSTEM)/etc/gpu_vulkan_blocklist.cfg

# -----------------------------------------------------------
# 2. Conservative GPU system properties
#    These are build-time defaults. The gpu_stability.sh
#    script may override them at runtime based on detection.
# -----------------------------------------------------------
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.opengles.version=196609 \
    ro.hardware.vulkan.level=0 \
    ro.hardware.vulkan.version=4198400 \
    debug.sf.latch_unsignaled=1 \
    ro.surface_flinger.max_frame_buffer_acquired_buffers=3 \
    ro.surface_flinger.enable_frame_rate_override=false \
    debug.egl.force_msaa=false \
    debug.egl.recordable=0
