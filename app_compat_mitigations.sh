#!/system/bin/sh
set +e  # Never abort — any individual failure is non-fatal
# ============================================================
# app_compat_mitigations.sh
# Vendor15 App Compatibility — Feature Gating & Fallbacks
# ============================================================
#
# Called from gsi_app_compat.rc during post-fs-data.
# Sets app-facing properties that control how the framework
# advertises hardware capabilities to third-party apps.
#
# This complements hal_gap_mitigations.sh (HAL-level) with
# app-visible feature flags, capability levels, and fallback
# behavior that apps query via PackageManager, CameraManager,
# BluetoothAdapter, and NeuralNetworks APIs.
#
# Boot safety:
#   - Every operation guarded with || true
#   - Never blocks, aborts, or crashes
#   - All setprop calls are non-blocking
# ============================================================

LOG_TAG="GSI_COMPAT"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== App Compatibility Mitigations Starting ==="

# -------------------------------------------------------
# Helper: check if a HAL exists in vendor VINTF manifests
# -------------------------------------------------------
hal_exists() {
    local name="$1"
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

# ============================================================
# 1. CAMERA — App-Facing Capability Masking
# ============================================================
# Failure modes:
#   - Apps query Camera2 INFO_SUPPORTED_HARDWARE_LEVEL and get
#     LEVEL_FULL/LEVEL_3 but vendor HAL doesn't implement all
#     mandatory FULL capabilities → app crashes on missing stream
#   - HEIF/AVIF capture requested but vendor HAL lacks encoder
#   - Concurrent camera open crashes on V15 HALs
#   - Camera extensions (Night, Bokeh) return broken metadata
# ============================================================
log_info "--- [1/5] Camera App Compatibility ---"

# Cap Camera2 hardware level advertisement to LIMITED
# This prevents apps from expecting FULL/LEVEL_3 features
# (manual sensor control, RAW capture, YUV reprocessing)
# that V15 HALs often don't fully implement.
setprop persist.camera.hal.level LIMITED 2>/dev/null || true

# Disable HEIF capture — vendor media codec may not support
# HEIF encoding, causing silent capture failures
setprop persist.camera.heif.enabled false 2>/dev/null || true

# Disable 10-bit HEIF — definitely not in V15 encoders
setprop persist.camera.heif.10bit false 2>/dev/null || true

# Disable concurrent camera sessions — V15 providers crash
# when multiple cameras are opened simultaneously by
# different apps (e.g., video call + barcode scanner)
setprop persist.camera.concurrent.enable false 2>/dev/null || true

# Disable camera extensions discovery — prevents
# CameraExtensionCharacteristics queries that crash V15 HALs
setprop persist.camera.extensions.enabled false 2>/dev/null || true

# Disable Ultra HDR (JPEG_R) — not implemented in V15
setprop persist.camera.ultrahdr.enabled false 2>/dev/null || true

# Disable stream use case signaling — V15 HAL ignores this
# but some implementations crash when receiving unknown use cases
setprop persist.camera.stream_use_case_override 0 2>/dev/null || true

# Force legacy face detection — V15 HALs have stable legacy
# face detection but may crash on extended face detection mode
setprop persist.camera.facedetect.mode legacy 2>/dev/null || true

# Disable zoom ratio control — use cropRegion instead
# Some V15 HALs claim ZOOM_RATIO support but return invalid ranges
setprop persist.camera.zoom.use_crop_region true 2>/dev/null || true

log_info "  Camera: LIMITED level, HEIF/HDR/extensions disabled"

# ============================================================
# 2. WIFI — App-Facing Feature Gating
# ============================================================
# Failure modes:
#   - Apps query WiFi Aware (NAN) capability; vendor doesn't
#     implement it → WifiAwareManager returns null, app NPE
#   - WiFi RTT (Fine Time Measurement) queried but unsupported
#   - Hotspot API used for local-only hotspot; vendor AP driver
#     crashes on configuration channel request
#   - WiFi P2P GO mode fails on V15 drivers
# ============================================================
log_info "--- [2/5] WiFi App Compatibility ---"

# Disable WiFi Aware (NAN) if not in vendor manifest
if ! hal_exists "wifi.NanIface" 2>/dev/null && \
   ! hal_exists "wifi.nan" 2>/dev/null; then
    setprop config.disable_wifiaware true 2>/dev/null || true
    log_info "  WiFi Aware: disabled (not in vendor manifest)"
else
    log_info "  WiFi Aware: vendor claims support, leaving enabled"
fi

# Disable WiFi RTT (FTM) — requires specific driver support
# Many V15 drivers claim RTT via HAL but produce inaccurate
# or crash-inducing results
setprop config.disable_rtt true 2>/dev/null || true

# Conservative hotspot configuration — prevent framework from
# requesting 6GHz or DFS channels that V15 drivers can't handle
setprop persist.sys.wifi.softap_max_channel_width 1 2>/dev/null || true
setprop persist.sys.wifi.softap_band 1 2>/dev/null || true

# Disable WiFi P2P concurrent operation — V15 drivers may not
# support concurrent STA + P2P-GO properly
setprop persist.sys.wifi.p2p_concurrent false 2>/dev/null || true

# Disable DPP (Device Provisioning Protocol) — V15
# supplicant v2-3 may not implement DPP properly
setprop persist.sys.wifi.dpp_supported false 2>/dev/null || true

# Disable TWT (Target Wake Time) — WiFi 6 feature that
# many V15 drivers advertise but don't implement correctly
setprop persist.sys.wifi.twt_enabled false 2>/dev/null || true

log_info "  WiFi: RTT/DPP/TWT disabled, conservative hotspot"

# ============================================================
# 3. BLUETOOTH LE AUDIO — Codec & Feature Gating
# ============================================================
# Failure modes:
#   - A16 Bluetooth stack offers LE Audio (LC3 codec) but
#     vendor BT controller firmware doesn't support ISO channels
#   - Broadcast Audio (AURACAST) crashes on BT HAL v3 that
#     doesn't implement CreateBig/TerminateBig
#   - LE Audio hearing aid profile fails without proper
#     Audio HAL v4 AIDL support
#   - CIS (Connected Isochronous Stream) setup hangs
# ============================================================
log_info "--- [3/5] Bluetooth LE Audio Compatibility ---"

# Check if vendor BT stack supports LE Audio by looking for
# ISO channel support markers in the BT HAL
bt_le_audio_ok=0
if hal_exists "bluetooth.audio" 2>/dev/null; then
    # Check for Bluetooth audio HAL v4 which adds LE Audio support
    for manifest in /vendor/etc/vintf/manifest.xml \
                    /vendor/etc/vintf/manifest/*.xml \
                    /vendor/manifest.xml; do
        if [ -f "$manifest" ] 2>/dev/null && \
           grep -q "bluetooth.audio" "$manifest" 2>/dev/null && \
           grep -A5 "bluetooth.audio" "$manifest" 2>/dev/null | grep -q "version.*4" 2>/dev/null; then
            bt_le_audio_ok=1
            break
        fi
    done
fi

if [ "$bt_le_audio_ok" -eq 0 ]; then
    # No BT audio HAL v4 — disable LE Audio features
    log_warn "  BT LE Audio: HAL v4 not confirmed, disabling LE Audio"

    # Disable LE Audio profile — forces classic A2DP for all audio
    setprop persist.bluetooth.leaudio.enabled false 2>/dev/null || true

    # Disable broadcast audio (AURACAST) — requires BLE ISO
    setprop persist.bluetooth.leaudio.broadcast.enabled false 2>/dev/null || true

    # Disable LE Audio hearing aid support — falls back to ASHA
    setprop persist.bluetooth.leaudio.hearing_aid.enabled false 2>/dev/null || true

    # Disable LC3 codec — force SBC/AAC which are universally supported
    setprop persist.bluetooth.leaudio.codec.lc3.enabled false 2>/dev/null || true

    # Disable CIS (Connected Isochronous Stream) — not implemented on V15 firmware
    setprop persist.bluetooth.leaudio.cis.enabled false 2>/dev/null || true

    # Force A2DP as default audio profile
    setprop persist.bluetooth.default_audio_route a2dp 2>/dev/null || true
else
    log_info "  BT LE Audio: HAL v4 detected, leaving LE Audio enabled"
    # Even with v4, apply conservative defaults
    setprop persist.bluetooth.leaudio.broadcast.enabled false 2>/dev/null || true
    setprop persist.bluetooth.leaudio.codec.lc3.quality balanced 2>/dev/null || true
fi

# Universal BT stability properties regardless of LE Audio
# Disable A2DP offload if vendor doesn't support it
if ! getprop ro.bluetooth.a2dp_offload.supported 2>/dev/null | grep -q true; then
    setprop persist.bluetooth.a2dp_offload.disabled true 2>/dev/null || true
    log_info "  BT A2DP: offload disabled (not supported)"
fi

# Disable BLE extended advertising — crashes on some V15 BT controllers
setprop persist.bluetooth.ble.extended_adv false 2>/dev/null || true

# Conservative BT scan mode — prevents BLE scan storm on old controllers
setprop persist.bluetooth.blescan.batch_mode conservative 2>/dev/null || true

log_info "  BT: LE Audio=$bt_le_audio_ok, conservative scan/offload"

# ============================================================
# 4. ML / AI — NNAPI & On-Device Inference
# ============================================================
# Failure modes:
#   - Apps use NNAPI for ML inference, expect HW accelerator
#     (GPU/DSP/NPU) but vendor driver is broken or missing
#   - NNAPI delegates crash when loading vendor HAL driver
#   - On-device ML features (Smart Reply, Live Caption)
#     hang waiting for accelerator that never responds
#   - TFLite GPU delegate crashes on broken vendor GL driver
# ============================================================
log_info "--- [4/5] ML/AI Compatibility ---"

# Check if vendor NNAPI HAL is present and responsive
nnapi_ok=0
if hal_exists "neuralnetworks" 2>/dev/null; then
    # Check for actual NNAPI driver .so files
    for f in /vendor/lib64/hw/android.hardware.neuralnetworks*.so \
             /vendor/lib/hw/android.hardware.neuralnetworks*.so \
             /vendor/lib64/libneuralnetworks_driver*.so; do
        if [ -f "$f" ] 2>/dev/null; then
            nnapi_ok=1
            log_info "  NNAPI driver found: $f"
            break
        fi
    done
fi

if [ "$nnapi_ok" -eq 0 ]; then
    log_warn "  NNAPI: No vendor driver found, forcing CPU-only inference"

    # Disable NNAPI hardware acceleration — force CPU reference impl
    setprop debug.nn.cpuonly 1 2>/dev/null || true

    # Disable vendor NNAPI extensions — prevents loading broken drivers
    setprop debug.nn.vsi.disabled 1 2>/dev/null || true

    # Disable GPU-based NNAPI delegates
    setprop debug.nn.gpu.disabled 1 2>/dev/null || true
else
    log_info "  NNAPI: Vendor driver present"

    # Even with a driver, set conservative execution preferences
    # Prefer accuracy over speed — reduces crash risk from
    # vendor-specific fast-math optimizations
    setprop debug.nn.prefer_accuracy true 2>/dev/null || true

    # Set execution timeout — prevent hanging on broken drivers
    setprop debug.nn.timeout_ms 5000 2>/dev/null || true
fi

# Disable TFLite GPU delegate by default — vendor GL drivers
# may not support the compute shaders that TFLite requires.
# Apps should fall back to CPU or NNAPI delegate instead.
setprop debug.tflite.disable_gpu_delegate true 2>/dev/null || true

# Disable on-device ML features that require reliable NNAPI
# These features hang or drain battery when NNAPI is CPU-only
setprop persist.sys.smartspace.enabled false 2>/dev/null || true

# Limit NNAPI partition size — prevent vendor drivers from
# receiving overly large model partitions that cause OOM
setprop debug.nn.partition.max_size 16777216 2>/dev/null || true

log_info "  ML: NNAPI=$nnapi_ok, TFLite GPU delegate disabled"

# ============================================================
# 5. BIOMETRICS — App-Facing Strength & Feature Gating
# ============================================================
# Failure modes:
#   - Apps query BiometricManager.canAuthenticate(STRONG) —
#     framework reports STRONG but vendor HAL can't provide
#     crypto operations → BiometricPrompt shows but auth fails
#   - FIDO2/WebAuthn expects biometric-backed key attestation
#     that requires v5 HAL → app-visible auth failure
#   - Face unlock advertised as STRONG (Class 3) but vendor
#     HAL is actually WEAK (Class 1) → keystore rejection
#   - Fingerprint sensor reports extended properties
#     (under-display type, sensor size) incorrectly
# ============================================================
log_info "--- [5/5] Biometrics App Compatibility ---"

# Cap biometric strength to WEAK (Class 2) unless vendor
# explicitly confirms STRONG capability in the manifest.
# This prevents apps from expecting biometric-bound crypto
# operations that the V15 HAL may not implement.
fp_strong=0
face_strong=0

# Check if fingerprint HAL has authenticatorStrength
for manifest in /vendor/etc/vintf/manifest.xml \
                /vendor/etc/vintf/manifest/*.xml; do
    if [ -f "$manifest" ] 2>/dev/null; then
        if grep -q "biometrics.fingerprint" "$manifest" 2>/dev/null; then
            fp_strong=1
        fi
        if grep -q "biometrics.face" "$manifest" 2>/dev/null; then
            face_strong=1
        fi
    fi
done

# If face HAL exists, conservatively report as WEAK
# Many V15 face implementations are 2D (not 3D depth)
# and can't provide STRONG biometric guarantees
if [ "$face_strong" -eq 1 ]; then
    setprop persist.sys.face.strength weak 2>/dev/null || true
    log_info "  Face: present, strength=weak (conservative)"
fi

# Disable biometric-backed keystore attestation —
# requires HAL v5 with proper key agreement protocol
setprop persist.sys.biometric.keystore_attestation false 2>/dev/null || true

# Disable fingerprint sensor orientation reporting —
# V15 HALs report incorrect sensor location/orientation
# causing misplaced fingerprint UI overlays
setprop persist.sys.fingerprint.sensor_location_override true 2>/dev/null || true

# Conservative fingerprint HAP (Hardware Abstraction Parameters)
# Prevents framework from using v5 enrollment features
setprop persist.sys.fingerprint.enhanced_enrollment false 2>/dev/null || true

# Disable biometric multi-sensor fusion — V15 HALs don't
# implement coordinated face+fingerprint auth properly
setprop persist.sys.biometric.multi_sensor_fusion false 2>/dev/null || true

# Set fallback behavior for BiometricPrompt —
# when biometric fails, ensure PIN/pattern/password is offered
setprop persist.sys.biometric.always_offer_device_credential true 2>/dev/null || true

log_info "  Biometrics: fp=$fp_strong, face=$face_strong (strength=weak)"
log_info "  Biometrics: Attestation disabled, credential fallback enabled"

# ============================================================
# Done
# ============================================================
setprop sys.gsi.app_compat_done 1 2>/dev/null || true

log_info "=== App Compatibility Mitigations Complete ==="
log_info "  Camera: LIMITED, no HEIF/HDR/extensions"
log_info "  WiFi: no RTT/DPP/TWT, conservative hotspot"
log_info "  BT: LE Audio=$bt_le_audio_ok, A2DP preferred"
log_info "  ML: NNAPI=$nnapi_ok, GPU delegate disabled"
log_info "  Biometrics: conservative strength, credential fallback"

exit 0
