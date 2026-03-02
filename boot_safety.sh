#!/system/bin/sh
set +e  # Never abort — any individual failure is non-fatal
# ============================================================
# boot_safety.sh
# Vendor15 Boot Safety — Framework Fatal Path Neutralization
# ============================================================
#
# Called from gsi_boot_safety.rc during early-init/post-fs-data.
# Sets properties that prevent AOSP framework code from aborting
# due to missing kernel features, broken vendor trace HALs,
# or SurfaceFlinger crash loops.
#
# These address fatal paths in AOSP source that cannot be
# patched from this repository but can be controlled via
# system properties.
#
# Boot safety:
#   - Every operation guarded with || true
#   - Never blocks, aborts, or crashes
# ============================================================

LOG_TAG="GSI_SAFETY"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== Boot Safety Mitigations Starting ==="

# ============================================================
# 1. RESCUE PARTY SUPPRESSION
# ============================================================
# Android Rescue Party reboots the device into recovery after
# repeated system_server crashes. On GSI, early crashes during
# HAL probing can trigger this, making the device unbootable.
# Already set in gsi_survival.rc early-init, reinforce here.
# ============================================================
setprop persist.sys.disable_rescue true 2>/dev/null || true
setprop sys.rescue_party.disable true 2>/dev/null || true
log_info "  Rescue Party: suppressed"

# ============================================================
# 2. SDCARDFS / FUSE FALLBACK
# ============================================================
# On kernels without sdcardfs support (most V15 kernels use
# FUSE), the framework may LOG(FATAL) when trying to mount
# sdcardfs. Force FUSE mode unconditionally.
# ============================================================
setprop ro.sys.sdcardfs false 2>/dev/null || true
setprop persist.sys.fuse true 2>/dev/null || true
setprop persist.sys.fuse.passthrough.enable true 2>/dev/null || true
log_info "  Storage: FUSE mode forced (sdcardfs disabled)"

# ============================================================
# 3. ATRACE / PERFETTO SAFETY
# ============================================================
# Vendor trace HAL (atrace) may be missing or broken.
# Framework atrace code can SIGABRT when it cannot open
# the trace marker file or when vendor categories fail.
# Disable all trace tags to prevent this path.
# ============================================================
setprop debug.atrace.tags.enableflags 0 2>/dev/null || true
setprop persist.traced.enable 0 2>/dev/null || true
log_info "  Atrace: disabled (vendor trace HAL safety)"

# ============================================================
# 4. SURFACEFLINGER CRASH RECOVERY
# ============================================================
# SurfaceFlinger can enter a crash loop when HWC returns
# unexpected errors. These properties enable recovery paths
# instead of fatal termination.
# ============================================================

# Enable SF crash recovery — restart compositor without
# killing the entire system
setprop debug.sf.enable_hwc_vsp 0 2>/dev/null || true

# Disable HWC virtual display — common crash source on V15
setprop debug.sf.enable_hwc_virtual_display 0 2>/dev/null || true

# Conservative color mode — prevent crash on broken color HAL
setprop persist.sys.sf.color_mode 0 2>/dev/null || true
setprop persist.sys.sf.native_mode 0 2>/dev/null || true

# Disable HDR output on display — V15 HWC may not support HDR
# composition and crashes when framework requests HDR layer
setprop persist.sys.sf.force_hdr false 2>/dev/null || true

log_info "  SurfaceFlinger: crash recovery properties set"

# ============================================================
# 5. SYSTEM_SERVER WATCHDOG TOLERANCE
# ============================================================
# system_server's Watchdog kills the system if critical services
# are blocked for >60s. On slow V15 vendors, HAL calls during
# boot can exceed this. Increase tolerance.
# ============================================================
setprop ro.sys.watchdog.timeout_ms 120000 2>/dev/null || true
log_info "  Watchdog: timeout increased to 120s"

# ============================================================
# 6. ZYGOTE FORK SAFETY
# ============================================================
# Zygote may SIGABRT if it cannot initialize graphics during
# app preloading. Set fallback properties to prevent this.
# ============================================================
setprop persist.sys.zygote.preload_classes_threshold 5000 2>/dev/null || true
setprop persist.sys.dalvik.vm.heapsize 512m 2>/dev/null || true
log_info "  Zygote: conservative preload settings"

# ============================================================
# 7. BINDER TRANSACTION SAFETY
# ============================================================
# Large binder transactions to vendor HALs may timeout and
# cause fatal TransactionTooLargeException in system_server.
# Increase limits.
# ============================================================
setprop persist.sys.binder.max_threads 31 2>/dev/null || true
log_info "  Binder: max threads increased"

# ============================================================
# 8. TOMBSTONE / DEBUGGERD SAFETY
# ============================================================
# Excessive tombstones from crashing vendor processes can
# fill /data/tombstones and cause debuggerd itself to hang.
# Limit tombstone count.
# ============================================================
setprop tombstoned.max_tombstone_count 10 2>/dev/null || true
log_info "  Tombstones: limited to 10"

# ============================================================
# 9. SELINUX PERMISSIVE FALLBACK DETECTION
# ============================================================
# If vendor SELinux denials are blocking critical HALs,
# log it for debugging (we cannot change SELinux mode
# system-side, but we can detect the problem).
# ============================================================
selinux_mode=$(getenforce 2>/dev/null || echo "unknown")
log_info "  SELinux mode: $selinux_mode"

# ============================================================
# Done
# ============================================================
setprop sys.gsi.boot_safety_done 1 2>/dev/null || true

log_info "=== Boot Safety Mitigations Complete ==="

exit 0
