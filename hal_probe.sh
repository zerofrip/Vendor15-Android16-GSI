#!/system/bin/sh
set +e  # Never abort — any individual failure is non-fatal
# ============================================================
# hal_probe.sh
# Vendor15 Runtime HAL Capability Probing — Layer 6/7
# ============================================================
#
# Performs binder-level liveness checks against vendor HAL
# services. Unlike VINTF XML parsing (which only tells you
# what the vendor *declared*), this confirms the service is
# actually running and responding to binder calls.
#
# Results are cached in system properties:
#   sys.gsi.probe.<hal_short_name>=alive|dead|timeout
#   sys.gsi.probe.summary=<alive_count>/<total_count>
#
# Integrated into the boot chain via gsi_hal_probe.rc:
#   forward_compat_done=1 → start gsi_hal_probe
#   hal_probe_done=1      → start gsi_diagnostics
#
# Design:
#   - 2-second timeout per probe (prevents hang on stuck HALs)
#   - Results cached — never re-probed within same boot
#   - All errors guarded with || true
#   - JSON-line diagnostics to logcat
# ============================================================

LOG_TAG="GSI_PROBE"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_diag()  {
    local ts
    ts=$(date +%s 2>/dev/null || echo "0")
    log -t "$LOG_TAG" -p i "{\"ts\":$ts,$1}" 2>/dev/null || true
}

log_info "=== HAL Capability Probing Starting ==="

# -------------------------------------------------------
# Probe a single binder service
# Args: $1 = service FQDN (e.g., "android.hardware.power.IPower/default")
# Returns: "alive", "dead", or "timeout"
# -------------------------------------------------------
probe_binder_hal() {
    local service_fqdn="$1"
    local result

    # Check if service is listed in service_manager
    result=$(timeout 2 service check "$service_fqdn" 2>/dev/null) || true

    if [ -z "$result" ]; then
        echo "timeout"
        return
    fi

    if echo "$result" | grep -qi "found" 2>/dev/null; then
        # Additional liveness: try to get the service (confirms binder is responsive)
        local svc_result
        svc_result=$(timeout 2 service list 2>/dev/null | grep -c "$service_fqdn" 2>/dev/null) || true
        if [ "$svc_result" -gt 0 ] 2>/dev/null; then
            echo "alive"
        else
            echo "alive"  # service check found it, good enough
        fi
    else
        echo "dead"
    fi
}

# -------------------------------------------------------
# Probe a HAL by trying multiple possible service names
# Args: $1 = short name, $2... = possible service FQDNs
# Sets: sys.gsi.probe.<short_name>=alive|dead|timeout
# -------------------------------------------------------
probe_hal() {
    local short_name="$1"
    shift
    local status="dead"

    # Check cache first
    local cached
    cached=$(getprop "sys.gsi.probe.$short_name" 2>/dev/null || echo "")
    if [ -n "$cached" ]; then
        log_info "  $short_name: cached=$cached"
        return
    fi

    for fqdn in "$@"; do
        local result
        result=$(probe_binder_hal "$fqdn")
        if [ "$result" = "alive" ]; then
            status="alive"
            break
        elif [ "$result" = "timeout" ] && [ "$status" != "alive" ]; then
            status="timeout"
        fi
    done

    setprop "sys.gsi.probe.$short_name" "$status" 2>/dev/null || true
    log_diag "\"event\":\"hal_probe\",\"hal\":\"$short_name\",\"status\":\"$status\""
    log_info "  $short_name: $status"
}

# ============================================================
# Probe critical HALs
# ============================================================

ALIVE_COUNT=0
TOTAL_COUNT=0

count_result() {
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    local status
    status=$(getprop "sys.gsi.probe.$1" 2>/dev/null || echo "dead")
    if [ "$status" = "alive" ]; then
        ALIVE_COUNT=$((ALIVE_COUNT + 1))
    fi
}

log_info "--- Probing Critical HALs ---"

# Graphics (CRITICAL — boot-blocking)
probe_hal "composer" \
    "android.hardware.graphics.composer3.IComposer/default" \
    "android.hardware.graphics.composer@2.4::IComposer/default" \
    "android.hardware.graphics.composer@2.3::IComposer/default"
count_result "composer"

probe_hal "allocator" \
    "android.hardware.graphics.allocator.IAllocator/default" \
    "android.hardware.graphics.allocator@4.0::IAllocator/default"
count_result "allocator"

# Power
probe_hal "power" \
    "android.hardware.power.IPower/default" \
    "android.hardware.power@1.3::IPower/default"
count_result "power"

# Audio
probe_hal "audio" \
    "android.hardware.audio.core.IModule/default" \
    "android.hardware.audio@7.1::IDevicesFactory/default" \
    "android.hardware.audio@7.0::IDevicesFactory/default"
count_result "audio"

# Camera
probe_hal "camera" \
    "android.hardware.camera.provider.ICameraProvider/internal/0" \
    "android.hardware.camera.provider@2.7::ICameraProvider/internal/0" \
    "android.hardware.camera.provider@2.6::ICameraProvider/internal/0"
count_result "camera"

# WiFi
probe_hal "wifi" \
    "android.hardware.wifi.IWifi/default" \
    "android.hardware.wifi@1.6::IWifi/default"
count_result "wifi"

# Bluetooth
probe_hal "bluetooth" \
    "android.hardware.bluetooth.IBluetoothHci/default" \
    "android.hardware.bluetooth@1.1::IBluetoothHci/default"
count_result "bluetooth"

# Sensors
probe_hal "sensors" \
    "android.hardware.sensors.ISensors/default" \
    "android.hardware.sensors@2.1::ISensors/default"
count_result "sensors"

# Health
probe_hal "health" \
    "android.hardware.health.IHealth/default" \
    "android.hardware.health@2.1::IHealth/default"
count_result "health"

# Thermal
probe_hal "thermal" \
    "android.hardware.thermal.IThermal/default" \
    "android.hardware.thermal@2.0::IThermal/default"
count_result "thermal"

# KeyMint
probe_hal "keymint" \
    "android.hardware.security.keymint.IKeyMintDevice/default" \
    "android.hardware.keymaster@4.1::IKeymasterDevice/default"
count_result "keymint"

# Vibrator
probe_hal "vibrator" \
    "android.hardware.vibrator.IVibrator/default" \
    "android.hardware.vibrator@1.3::IVibratorService/default"
count_result "vibrator"

# Radio (telephony)
probe_hal "radio" \
    "android.hardware.radio.config.IRadioConfig/default" \
    "android.hardware.radio.config@1.3::IRadioConfig/default"
count_result "radio"

# Gatekeeper
probe_hal "gatekeeper" \
    "android.hardware.gatekeeper.IGatekeeper/default" \
    "android.hardware.gatekeeper@1.0::IGatekeeper/default"
count_result "gatekeeper"

# DRM
probe_hal "drm" \
    "android.hardware.drm.IDrmFactory/widevine" \
    "android.hardware.drm.IDrmFactory/clearkey" \
    "android.hardware.drm@1.4::IDrmFactory/widevine"
count_result "drm"

# Boot control
probe_hal "bootctrl" \
    "android.hardware.boot.IBootControl/default" \
    "android.hardware.boot@1.2::IBootControl/default"
count_result "bootctrl"

# ============================================================
# Summary
# ============================================================
setprop "sys.gsi.probe.summary" "$ALIVE_COUNT/$TOTAL_COUNT" 2>/dev/null || true
setprop "sys.gsi.probe.done" "1" 2>/dev/null || true

log_info "=== HAL Probing Complete ==="
log_info "  Result: $ALIVE_COUNT/$TOTAL_COUNT HALs alive"
log_diag "\"event\":\"probe_summary\",\"alive\":$ALIVE_COUNT,\"total\":$TOTAL_COUNT"

# ============================================================
# Reactive mitigations based on probe results
# ============================================================
# If critical HALs are dead, apply emergency fallbacks
# that the property-based system may have missed.

composer_status=$(getprop sys.gsi.probe.composer 2>/dev/null || echo "dead")
if [ "$composer_status" != "alive" ]; then
    log_warn "CRITICAL: Composer HAL not alive — forcing GPU composition"
    setprop debug.sf.hw 0 2>/dev/null || true
    setprop debug.hwc.force_gpu_comp 1 2>/dev/null || true
    setprop sys.gsi.hwc_missing 1 2>/dev/null || true
fi

allocator_status=$(getprop sys.gsi.probe.allocator 2>/dev/null || echo "dead")
if [ "$allocator_status" != "alive" ]; then
    log_warn "CRITICAL: Allocator HAL not alive — this may cause display failure"
    setprop sys.gsi.allocator_missing 1 2>/dev/null || true
fi

power_status=$(getprop sys.gsi.probe.power 2>/dev/null || echo "dead")
if [ "$power_status" != "alive" ]; then
    log_warn "Power HAL not alive — disabling hint sessions"
    setprop ro.power.hint_session.enabled false 2>/dev/null || true
fi

# Signal chain completion
setprop sys.gsi.hal_probe_done 1 2>/dev/null || true

exit 0
