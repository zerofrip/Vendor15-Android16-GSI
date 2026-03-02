# ============================================================
# app_compat_mitigations.mk
# Vendor15 App Compatibility — Build Integration
# ============================================================
#
# Installs app compatibility mitigation files into the GSI
# system image. Included from vendor15_survival.mk.
# ============================================================

# -----------------------------------------------------------
# 1. App compatibility script + init trigger
# -----------------------------------------------------------
PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/app_compat_mitigations.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/app_compat_mitigations.sh \
    device/phh/treble/vendor15/gsi_app_compat.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_app_compat.rc

# -----------------------------------------------------------
# 2. Build-time app compatibility defaults
# -----------------------------------------------------------
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.camera.hal.level=LIMITED \
    persist.camera.heif.enabled=false \
    persist.camera.concurrent.enable=false \
    persist.bluetooth.leaudio.broadcast.enabled=false \
    persist.sys.biometric.always_offer_device_credential=true \
    persist.sys.biometric.keystore_attestation=false \
    config.disable_rtt=true \
    debug.tflite.disable_gpu_delegate=true
