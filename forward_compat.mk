# ============================================================
# forward_compat.mk
# Vendor15 Forward Compatibility — Build Integration
# ============================================================

PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/forward_compat.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/forward_compat.sh \
    device/phh/treble/vendor15/gsi_forward_compat.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_forward_compat.rc

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.gsi.aidl.version_negotiation=true \
    ro.gsi.avf.enabled=false \
    ro.gsi.pvm.supported=false \
    persist.sys.virtualization.enabled=false \
    persist.sys.microdroid.enabled=false \
    persist.sys.ondevice_ai.enabled=false \
    persist.sys.genai.enabled=false \
    persist.sys.satellite.messaging=false \
    persist.sys.health_connect.enabled=false \
    ro.gsi.sf.compositor_version=1
