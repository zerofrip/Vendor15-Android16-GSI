#!/system/bin/sh
set +e  # Never abort — any individual failure is non-fatal
# ============================================================
# forward_compat.sh
# Vendor15 Forward Compatibility — Android 17/18 Proofing
# ============================================================
#
# Called from gsi_forward_compat.rc during post-fs-data.
# Addresses Android 17/18 framework assumptions that are
# incompatible with V15 vendor images. Sets properties that
# gate new framework features, negotiate AIDL versions
# downward, and prevent fatal assertions on missing
# capabilities.
#
# Design for the future:
#   - Version-agnostic capability probing (not version checks)
#   - Conservative capability reporting
#   - Stub/disable for all post-V15 features
#   - Lazy optional service tolerance
#
# Boot safety:
#   - Every operation guarded with || true
#   - Never blocks, aborts, or crashes
# ============================================================

LOG_TAG="GSI_FWDCOMPAT"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== Forward Compatibility Mitigations Starting ==="

# -------------------------------------------------------
# Helper: probe vendor AIDL HAL version from VINTF manifest
# Returns the max version found, or 0 if not present
# -------------------------------------------------------
get_hal_version() {
    local hal_name="$1"
    local max_ver=0
    for manifest in /vendor/etc/vintf/manifest.xml \
                    /vendor/etc/vintf/manifest/*.xml \
                    /vendor/manifest.xml \
                    /odm/etc/vintf/manifest.xml; do
        if [ -f "$manifest" ] 2>/dev/null; then
            # Extract version numbers for this HAL
            local vers=$(sed -n "/$hal_name/,/<\/hal>/p" "$manifest" 2>/dev/null | \
                         grep '<version>' 2>/dev/null | \
                         sed 's/.*>\([0-9]*\).*/\1/' 2>/dev/null | \
                         sort -rn 2>/dev/null | head -1)
            if [ -n "$vers" ] && [ "$vers" -gt "$max_ver" ] 2>/dev/null; then
                max_ver=$vers
            fi
        fi
    done
    echo "$max_ver"
}

# ============================================================
# 1. AIDL VERSION NEGOTIATION
# ============================================================
# A17/18 framework assumes latest AIDL versions. V15 vendors
# provide older versions. Set properties that tell the
# framework to negotiate downward instead of asserting.
# ============================================================
log_info "--- [1/7] AIDL Version Negotiation ---"

# Detect actual vendor HAL versions
health_ver=$(get_hal_version "android.hardware.health")
power_ver=$(get_hal_version "android.hardware.power")
camera_ver=$(get_hal_version "android.hardware.camera.provider")
keymint_ver=$(get_hal_version "android.hardware.security.keymint")
audio_ver=$(get_hal_version "android.hardware.audio.core")
thermal_ver=$(get_hal_version "android.hardware.thermal")

log_info "  Vendor HAL versions detected:"
log_info "    health=$health_ver power=$power_ver camera=$camera_ver"
log_info "    keymint=$keymint_ver audio=$audio_ver thermal=$thermal_ver"

# Tell framework to accept any AIDL version the vendor offers
# rather than asserting on a minimum version
setprop ro.gsi.aidl.version_negotiation true 2>/dev/null || true

# Set version ceiling properties — framework should not attempt
# to use APIs above these versions
if [ "$health_ver" -gt 0 ] 2>/dev/null; then
    setprop ro.gsi.hal.health.version "$health_ver" 2>/dev/null || true
fi
if [ "$power_ver" -gt 0 ] 2>/dev/null; then
    setprop ro.gsi.hal.power.version "$power_ver" 2>/dev/null || true
fi
if [ "$camera_ver" -gt 0 ] 2>/dev/null; then
    setprop ro.gsi.hal.camera.version "$camera_ver" 2>/dev/null || true
fi
if [ "$keymint_ver" -gt 0 ] 2>/dev/null; then
    setprop ro.gsi.hal.keymint.version "$keymint_ver" 2>/dev/null || true
fi

log_info "  AIDL: version ceilings published for framework"

# ============================================================
# 2. SERVICE MANAGER RESILIENCE
# ============================================================
# A17/18 ServiceManager may reject HAL registrations with
# wrong AIDL version or missing interface hash. Set properties
# that make ServiceManager more tolerant.
# ============================================================
log_info "--- [2/7] ServiceManager Resilience ---"

# Disable strict interface hash checking — V15 vendor HALs
# may have been compiled against older AIDL interface hashes
setprop ro.gsi.sm.skip_hash_check true 2>/dev/null || true

# Allow unversioned AIDL service registration — some V15
# vendors register services without AIDL version metadata
setprop ro.gsi.sm.allow_unversioned true 2>/dev/null || true

# Increase service lookup timeout — V15 vendor HAL services
# may start slower than A17/18 framework expects
setprop ro.gsi.sm.lookup_timeout_ms 10000 2>/dev/null || true

# Disable lazy HAL assertion — A17/18 lazy HAL framework
# may assert if a lazy HAL doesn't respond within timeout
setprop ro.gsi.hal.lazy_assert_disabled true 2>/dev/null || true

log_info "  ServiceManager: tolerant mode enabled"

# ============================================================
# 3. HEALTH HAL VERSION GATING
# ============================================================
# A17/18 may require health v4+ for boot. V15 provides v3.
# Health v4 adds battery health snapshots and charging policy
# that aren't needed for basic boot.
# ============================================================
log_info "--- [3/7] Health HAL Gating ---"

if [ "$health_ver" -lt 4 ] 2>/dev/null; then
    log_warn "  Health HAL v$health_ver < v4 — gating new features"

    # Disable battery health snapshots — v4 feature
    setprop persist.sys.health.battery_snapshots false 2>/dev/null || true

    # Disable charging policy control — v4 feature
    setprop persist.sys.health.charging_policy false 2>/dev/null || true

    # Disable Health Connect integration — requires v4 health
    setprop persist.sys.health_connect.enabled false 2>/dev/null || true

    # Tell system_server to not block on health v4 methods
    setprop ro.gsi.health.version_cap 3 2>/dev/null || true
else
    log_info "  Health HAL v$health_ver >= v4 — no gating needed"
fi

# ============================================================
# 4. CREDENTIAL MANAGER & KEYMINT GATING
# ============================================================
# A17/18 Credential Manager requires keymint v4+ for remote
# key provisioning and credential binding. V15 keymint v1-3
# cannot satisfy these requirements.
# ============================================================
log_info "--- [4/7] Credential Manager Gating ---"

if [ "$keymint_ver" -lt 4 ] 2>/dev/null; then
    log_warn "  KeyMint v$keymint_ver < v4 — disabling Credential Manager features"

    # Disable Credential Manager remote provisioning
    setprop persist.sys.credman.remote_provisioning false 2>/dev/null || true

    # Disable identity credential binding — requires keymint v4
    setprop persist.sys.credman.identity_binding false 2>/dev/null || true

    # Disable remote key provisioning service
    setprop persist.sys.rkpd.enabled false 2>/dev/null || true

    # Cap keymint attestation to what V15 supports
    setprop ro.gsi.keymint.version_cap "$keymint_ver" 2>/dev/null || true

    # Disable device-level key attestation — V15 keymint may
    # not implement getAttestationIds correctly
    setprop persist.sys.keymint.device_attestation false 2>/dev/null || true
else
    log_info "  KeyMint v$keymint_ver >= v4 — Credential Manager enabled"
fi

# ============================================================
# 5. VIRTUALIZATION / pVM MASKING
# ============================================================
# A17/18 adds Android Virtualization Framework (AVF) with
# pVM support. V15 vendors have no virtualization HAL, no
# pKVM hypervisor, and no crosvm binaries.
# ============================================================
log_info "--- [5/7] Virtualization Masking ---"

# Disable AVF (Android Virtualization Framework) entirely
setprop ro.gsi.avf.enabled false 2>/dev/null || true
setprop persist.sys.virtualization.enabled false 2>/dev/null || true

# Disable pVM (protected VM) support
setprop ro.gsi.pvm.supported false 2>/dev/null || true

# Disable Microdroid (lightweight VM for isolated computation)
setprop persist.sys.microdroid.enabled false 2>/dev/null || true

# Disable VM Binder — not available without hypervisor
setprop ro.gsi.vmbinder.supported false 2>/dev/null || true

# Disable isolated compilation in VM
setprop persist.sys.isolated_compilation_in_vm false 2>/dev/null || true

log_info "  Virtualization: AVF/pVM/Microdroid fully disabled"

# ============================================================
# 6. COMPOSITOR FORWARD-COMPAT (A18 Display API)
# ============================================================
# A18 may introduce display compositor API v2 with new layer
# types, HDR vivid, and refresh rate control. V15 composer3
# v3 cannot support these.
# ============================================================
log_info "--- [6/7] Compositor Forward-Compat ---"

# Disable display API v2 features — ensure SurfaceFlinger
# uses only v1/v3 compositor paths
setprop ro.gsi.sf.compositor_version 1 2>/dev/null || true

# Disable HDR Vivid — A18 feature not in V15 HWC
setprop persist.sys.sf.hdr_vivid false 2>/dev/null || true

# Disable refresh rate voting — A18 framework may expect
# HWC to participate in refresh rate decisions
setprop persist.sys.sf.refresh_rate_voting false 2>/dev/null || true

# Disable display dimming API — requires HWC support
setprop persist.sys.sf.display_dimming false 2>/dev/null || true

# Disable Auto Low Latency Mode — V15 HWC may crash
setprop persist.sys.sf.allm_enabled false 2>/dev/null || true

# Disable game mode compositor optimization — A18 feature
setprop persist.sys.sf.game_mode_composition false 2>/dev/null || true

log_info "  Compositor: pinned to v1 API, A18 features disabled"

# ============================================================
# 7. FRAMEWORK VERSION AND FEATURE MASKING
# ============================================================
# Set properties that prevent the framework from advertising
# capabilities it cannot deliver on V15 vendors. This ensures
# apps don't attempt to use A17/18 APIs that depend on
# vendor-side implementations.
# ============================================================
log_info "--- [7/7] Framework Feature Masking ---"

# Disable on-device AI/GenAI features — A17/18 adds
# system-level GenAI that requires NPU + NNAPI v5+
setprop persist.sys.ondevice_ai.enabled false 2>/dev/null || true
setprop persist.sys.genai.enabled false 2>/dev/null || true

# Disable UWB ranging — A17 makes UWB more integrated;
# V15 UWB HAL v1 may not support new ranging modes
setprop persist.sys.uwb.advanced_ranging false 2>/dev/null || true

# Disable satellite messaging — A17/18 feature
setprop persist.sys.satellite.messaging false 2>/dev/null || true

# Disable private space enhancement — A17 adds new APIs
# for private space that may depend on keymint v4
setprop persist.sys.private_space.enhanced false 2>/dev/null || true

# Disable lossless USB audio — A17/18 feature requiring
# audio HAL v4+ and USB HAL v3+
setprop persist.sys.usb.lossless_audio false 2>/dev/null || true

# Disable haptic-coupled audio — A17/18 feature
setprop persist.sys.haptic_coupled_audio false 2>/dev/null || true

# Disable screen-off display — A18 AOD-related feature
setprop persist.sys.screen_off_display false 2>/dev/null || true

# Disable predictive back with HAL animations — A17 feature
# but V15 HWC may not handle back predictive surfaces
setprop persist.sys.predictive_back_hal false 2>/dev/null || true

log_info "  Framework: A17/18 features masked, conservative capability"

# ============================================================
# Done
# ============================================================
setprop sys.gsi.forward_compat_done 1 2>/dev/null || true

log_info "=== Forward Compatibility Mitigations Complete ==="
log_info "  Detected vendor versions: health=$health_ver power=$power_ver"
log_info "    camera=$camera_ver keymint=$keymint_ver audio=$audio_ver"

exit 0
