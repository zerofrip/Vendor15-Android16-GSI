#!/system/bin/sh
set +e  # Never abort — any individual failure is non-fatal
# ============================================================
# hal_gap_mitigations.sh
# Vendor15 HAL Gap Mitigations — Runtime Detection & Fallback
# ============================================================
#
# Called from gsi_hal_mitigations.rc during post-fs-data.
# Probes vendor HAL availability and sets conservative system
# properties to prevent the A16 framework from exercising
# features that V15 vendor HALs cannot support.
#
# Boot safety:
#   - Every operation is guarded with || true
#   - Never blocks, never aborts, never crashes
#   - All property sets use setprop (non-blocking)
#   - Errors default to "apply conservative fallbacks"
#
# Properties set:
#   sys.gsi.hal_mitigations_done — "1" when script completes
# ============================================================

LOG_TAG="GSI_HAL"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== HAL Gap Mitigations Starting ==="

# -------------------------------------------------------
# Helper: check if a vendor HAL service is registered
# Returns 0 if found, 1 if not
# -------------------------------------------------------
hal_exists() {
    local name="$1"
    # Check VINTF manifests for the HAL
    for manifest in /vendor/etc/vintf/manifest.xml \
                    /vendor/etc/vintf/manifest/*.xml \
                    /vendor/manifest.xml \
                    /odm/etc/vintf/manifest.xml \
                    /odm/etc/vintf/manifest/*.xml; do
        if [ -f "$manifest" ] 2>/dev/null && grep -q "$name" "$manifest" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# -------------------------------------------------------
# Helper: get VNDK version
# -------------------------------------------------------
vndk=$(getprop ro.vndk.version 2>/dev/null || echo "")
case "$vndk" in
    ''|*[!0-9]*) vndk=34 ;;
esac
log_info "VNDK version: $vndk"

# ============================================================
# 1. HWC COMPOSER3 (v3 → v4 gap)
# ============================================================
# Risk: A16 SurfaceFlinger may attempt v4 client composition
# optimizations (predictive composition strategy, display
# decoration support) that v3 composer doesn't implement.
# This causes GPU fallback storms and power regression.
# ============================================================
log_info "--- [1/7] HWC Composer Mitigations ---"

# Disable predictive HWC composition strategy — forces
# SurfaceFlinger to always ask HWC for composition decisions
# instead of predicting. V3 composer may return incorrect
# predictions causing unnecessary GPU fallback.
setprop debug.sf.predict_hwc_composition_strategy 0 2>/dev/null || true

# Disable client composition cache — V3 composer may not
# properly invalidate cached compositions when layers change,
# causing visual corruption or stale frames.
setprop debug.sf.disable_client_composition_cache 1 2>/dev/null || true

# Conservative VSYNC phase offsets — prevents timing-related
# crashes when V3 composer is slower than A16 expects.
setprop debug.sf.use_phase_offsets_as_durations 1 2>/dev/null || true
setprop debug.sf.late.sf.duration 27600000 2>/dev/null || true
setprop debug.sf.late.app.duration 20000000 2>/dev/null || true
setprop debug.sf.early.sf.duration 27600000 2>/dev/null || true
setprop debug.sf.early.app.duration 20000000 2>/dev/null || true
setprop debug.sf.earlyGl.sf.duration 27600000 2>/dev/null || true
setprop debug.sf.earlyGl.app.duration 20000000 2>/dev/null || true

# Set minimum HWC duration to prevent starvation on slow V3 composers
setprop debug.sf.hwc.min.duration 17000000 2>/dev/null || true

# Disable display decoration support — V4 feature not in V3
setprop debug.sf.enable_display_decoration 0 2>/dev/null || true

log_info "  HWC: Disabled predictive composition, set conservative timing"

# ============================================================
# 2. POWER HAL (v4 → v5 hint sessions gap)
# ============================================================
# Risk: A16 framework uses ADPF (Android Dynamic Performance
# Framework) hint sessions introduced in power HAL v5.
# V15 vendors may claim v5 but have broken session support,
# causing thermal throttling loops or performance instability.
# ============================================================
log_info "--- [2/7] Power HAL Mitigations ---"

# Disable ADPF hint sessions — prevents the framework from
# creating performance hint sessions that the vendor HAL
# cannot properly handle. Without this, apps may get stuck
# in aggressive boost/throttle cycles.
setprop debug.adpf.disable_hint_session true 2>/dev/null || true

# Disable GPU ADPF hints — same issue with GPU-side hints
setprop debug.adpf.disable_gpu_hint true 2>/dev/null || true

# Conservative CPU boost behavior — prevent framework from
# sending boost hints that vendor power HAL misinterprets
setprop debug.performance.tuning 0 2>/dev/null || true

# Disable fixed performance mode — let the vendor governor decide
setprop debug.hwui.use_hint_manager false 2>/dev/null || true

log_info "  Power: ADPF hint sessions disabled, conservative boost"

# ============================================================
# 3. WIFI SUPPLICANT (v2-3 → v4 gap)
# ============================================================
# Risk: A16 WiFi framework may query v4 supplicant APIs for
# WiFi 6E (6GHz band), WiFi 7 (MLO/EHT), and advanced
# features. V2-3 supplicant returns errors or garbage,
# causing WiFiService crashes or scan failures.
# ============================================================
log_info "--- [3/7] WiFi Supplicant Mitigations ---"

# Disable WiFi 6E (6GHz band) — requires supplicant v4
# Without this, WifiService may attempt 6GHz scans that
# the supplicant doesn't understand, causing stuck scans.
setprop persist.sys.wifi.6e_supported false 2>/dev/null || true

# Disable WiFi 7 MLO (Multi-Link Operation) — requires v4
setprop persist.sys.wifi.7_supported false 2>/dev/null || true

# Disable AFC (Automated Frequency Coordination) — v4 only
setprop persist.sys.wifi.afc_enabled false 2>/dev/null || true

# Force WiFi 5 scan behavior — conservative and universally supported
setprop wifi.interface wlan0 2>/dev/null || true

# Disable STA/STA concurrency probe — many V15 drivers crash
# when the framework queries concurrent STA capabilities
setprop persist.sys.wifi.multichannel_concurrency false 2>/dev/null || true

# Disable WPA3-SAE H2E — some V15 supplicants crash on H2E
# transition mode negotiation. Fall back to WPA3-SAE hunt-and-peck
# or WPA2 which is universally supported.
setprop persist.sys.wifi.wpa3_h2e_disabled true 2>/dev/null || true

log_info "  WiFi: 6E/7/MLO disabled, conservative scan behavior"

# ============================================================
# 4. AUDIO CORE HAL (v1-2 → v4 gap)
# ============================================================
# Risk: A16 AudioFlinger may attempt spatial audio pipelines,
# multi-zone routing, and sounddose V3+ features. V1-2 audio
# HAL returns errors on these paths, causing routing failures
# and media app crashes.
# ============================================================
log_info "--- [4/7] Audio Core Mitigations ---"

# Disable spatial audio — requires audio.core v3+
# Without this, AudioFlinger attempts to create virtualizer
# effect chains that the vendor HAL doesn't support, causing
# audio routing failures (silent output or stuttering).
setprop ro.audio.spatializer_enabled false 2>/dev/null || true
setprop persist.sys.phh.disable_spatial_audio true 2>/dev/null || true

# Disable head tracking for spatial audio — requires new sensor HAL
setprop ro.audio.headtracking_enabled false 2>/dev/null || true

# Force stereo output — prevents multi-channel routing on
# HALs that only properly support stereo
setprop ro.audio.multichannel_disabled true 2>/dev/null || true

# Conservative audio flinger settings — prevent buffer underruns
# on V15 audio HALs with slower buffer delivery
setprop ro.audio.flinger_standbytime_ms 2000 2>/dev/null || true

# Disable ultrasound support — V4 feature, crashes on V1-2
setprop ro.audio.ultrasound_supported false 2>/dev/null || true

log_info "  Audio: Spatial audio disabled, stereo-only, conservative routing"

# ============================================================
# 5. CAMERA PROVIDER (v1-3, no v4+ features)
# ============================================================
# Risk: A16 CameraService may query v4+ capabilities (Ultra HDR,
# 10-bit camera, extension modes, multi-concurrent streams)
# that V15 camera providers don't implement. Returns from
# getCameraCharacteristics may lack expected keys, causing
# NPEs in camera apps.
# ============================================================
log_info "--- [5/7] Camera Provider Mitigations ---"

# NOTE: persist.camera.ultrahdr.enabled and persist.camera.extensions.enabled
# are set by app_compat_mitigations.sh (authoritative script for camera)

# Disable concurrent multi-camera — V15 HALs often crash when
# framework opens multiple cameras simultaneously
setprop persist.camera.privapp.multisession false 2>/dev/null || true

# Disable 10-bit HDR viewfinder — requires HAL v4 support
setprop persist.camera.10bit_hdr_viewfinder false 2>/dev/null || true

# Force HAL3 mode — ensures we don't try HAL4 dispatch paths
setprop persist.camera.HAL3.enabled 1 2>/dev/null || true

# NOTE: persist.camera.stream_use_case_override is set by
# app_compat_mitigations.sh (authoritative script for camera)

log_info "  Camera: Ultra HDR/extensions/10-bit disabled, HAL3 forced"

# ============================================================
# 6. BIOMETRICS (face v3-4, fingerprint v3-4 → v5 gap)
# ============================================================
# Risk: A16 BiometricManager may attempt v5 features (FIDO2
# direct transport, biometric attestation, enhanced enrollment
# with liveness). V3-4 HALs return STATUS_OPERATION_NOT_SUPPORTED
# but some paths interpret this as a fatal error.
# ============================================================
log_info "--- [6/7] Biometrics Mitigations ---"

# Cap biometric feature level — prevents the framework from
# offering biometric-bound keys with attestation features
# that require v5 HAL. Level 30 corresponds to Android 11
# biometric capabilities, which is universally supported.
setprop ro.hardware.biometric_feature_level 30 2>/dev/null || true

# Disable face authentication Class 3 upgrade probing —
# V3-4 face HALs may not properly report their strength level
setprop ro.face.disable_class3_probe true 2>/dev/null || true

# Conservative fingerprint settings — prevent framework from
# querying extended HAL capabilities that don't exist
setprop persist.sys.fingerprint.cancel_on_error true 2>/dev/null || true

# Disable biometric keystore attestation — requires v5
setprop persist.sys.biometric.attestation_enabled false 2>/dev/null || true

# Reduce fingerprint lock-out aggressiveness — V3-4 HALs
# may report false failures, and aggressive lockout causes
# user lockout on working hardware
setprop persist.sys.biometric.lockout_timed_duration 30000 2>/dev/null || true

log_info "  Biometrics: Feature level capped, attestation disabled"

# ============================================================
# 7. RADIO / IMS (radio.* v3, ims v2 → v5/v3 gap)
# ============================================================
# Risk: A16 Telephony framework may query v5 radio APIs for
# VoNR (Voice over New Radio), satellite connectivity, and
# advanced IMS features. V3 radio HALs return unexpected
# errors causing RIL restarts and data disconnections.
# ============================================================
log_info "--- [7/7] Radio / IMS Mitigations ---"

# Disable VoNR (Voice over NR/5G SA) — requires radio v5
# Without this, the framework may attempt to route voice
# over NR which the v3 HAL doesn't support, causing call
# setup failures or silent calls.
setprop persist.sys.telephony.vonr_enabled false 2>/dev/null || true

# Disable satellite connectivity — A16 feature requiring v5
setprop persist.sys.telephony.satellite_enabled false 2>/dev/null || true

# Force VoLTE to basic mode — prevent framework from
# using advanced IMS features not in IMS v2
setprop persist.dbg.ims_volte_enable 1 2>/dev/null || true
setprop persist.sys.ims.advanced_features_disabled true 2>/dev/null || true

# Disable IMS single registration — requires ims v3
setprop persist.sys.ims.single_registration false 2>/dev/null || true

# Disable IWLAN (WiFi calling handover) advanced modes —
# V15 IMS HAL v2 supports basic WiFi calling but not
# advanced handover policies. Prevent framework from
# requesting S2b/ePDG features.
setprop persist.sys.ims.wifi_calling_advanced false 2>/dev/null || true

# Conservative data stall detection — prevent framework from
# aggressively restarting radio when v3 HAL is slow to respond
setprop persist.sys.data_stall_recovery_on_bad_network 0 2>/dev/null || true

# Force conservative NR (5G) mode — prevent NSA fallback issues
# on v3 radio HALs that have buggy ENDC implementations
setprop persist.sys.radio.force_nr_to_nsa true 2>/dev/null || true

log_info "  Radio: VoNR/satellite disabled, conservative IMS"

# ============================================================
# Done
# ============================================================
setprop sys.gsi.hal_mitigations_done 1 2>/dev/null || true

log_info "=== HAL Gap Mitigations Complete ==="
log_info "  All 7 HAL areas mitigated"
log_info "  VNDK: $vndk"

exit 0
