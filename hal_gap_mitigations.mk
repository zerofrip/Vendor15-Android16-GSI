# ============================================================
# hal_gap_mitigations.mk
# Vendor15 HAL Gap Mitigations — Build Integration
# ============================================================
#
# Installs HAL gap mitigation files into the GSI system image.
# Included from vendor15_survival.mk.
#
# Files installed:
#   hal_gap_mitigations.sh
#       → system/bin/hal_gap_mitigations.sh
#   gsi_hal_mitigations.rc
#       → system/etc/init/gsi_hal_mitigations.rc
# ============================================================

# -----------------------------------------------------------
# 1. HAL mitigation script + init trigger
# -----------------------------------------------------------
PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/hal_gap_mitigations.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/hal_gap_mitigations.sh \
    device/phh/treble/vendor15/gsi_hal_mitigations.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_hal_mitigations.rc

# -----------------------------------------------------------
# 2. Build-time HAL fallback properties
#    These are conservative defaults. The runtime script
#    further adjusts based on detected vendor HAL state.
# -----------------------------------------------------------
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.audio.spatializer_enabled=false \
    ro.audio.headtracking_enabled=false \
    persist.camera.ultrahdr.enabled=false \
    persist.camera.extensions.enabled=false \
    persist.sys.wifi.6e_supported=false \
    persist.sys.wifi.7_supported=false \
    persist.sys.telephony.vonr_enabled=false \
    persist.sys.telephony.satellite_enabled=false \
    debug.adpf.disable_hint_session=true \
    debug.sf.predict_hwc_composition_strategy=0 \
    debug.sf.disable_client_composition_cache=1
