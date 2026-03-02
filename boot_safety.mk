# ============================================================
# boot_safety.mk
# Vendor15 Boot Safety — Build Integration
# ============================================================

PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/boot_safety.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/boot_safety.sh \
    device/phh/treble/vendor15/gsi_boot_safety.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_boot_safety.rc

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.sys.disable_rescue=true \
    ro.sys.sdcardfs=false \
    persist.sys.fuse=true \
    debug.atrace.tags.enableflags=0 \
    persist.sys.sf.color_mode=0 \
    tombstoned.max_tombstone_count=10
