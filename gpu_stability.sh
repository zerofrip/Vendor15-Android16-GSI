#!/system/bin/sh
# ============================================================
# gpu_stability.sh
# Vendor15 GPU Stability — Runtime Detection & Fallback
# ============================================================
#
# Called from gsi_gpu_stability.rc during post-fs-data.
# Probes vendor GPU state and applies conservative fallback
# properties to prevent crashes in EGL, Vulkan, and HWUI.
#
# Boot safety:
#   - Every operation is guarded with || true
#   - Never blocks, never aborts, never crashes
#   - All property sets use setprop (non-blocking)
#   - Errors default to "apply conservative fallbacks"
#
# Properties set:
#   sys.gsi.gpu_stability_done  — "1" when script completes
#   sys.gsi.gpu_vendor          — detected GPU vendor string
#   sys.gsi.gpu_egl_ok          — "1" if vendor EGL looks sane
#   sys.gsi.gpu_vulkan_ok       — "1" if vendor Vulkan ICD exists
# ============================================================

LOG_TAG="GSI_GPU"

log_info()  { log -t "$LOG_TAG" -p i "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }
log_warn()  { log -t "$LOG_TAG" -p w "$1" 2>/dev/null; echo "$LOG_TAG: $1" > /dev/kmsg 2>/dev/null || true; }

log_info "=== GPU Stability Check Starting ==="

# -------------------------------------------------------
# Helper: read VNDK version (for vendor API level detection)
# -------------------------------------------------------
vndk=$(getprop ro.vndk.version 2>/dev/null || echo "")
if [ -z "$vndk" ]; then
    vndk=$(getprop ro.vendor.build.version.sdk 2>/dev/null || echo "34")
fi
# Sanitize to numeric
case "$vndk" in
    ''|*[!0-9]*) vndk=34 ;;
esac
log_info "VNDK version: $vndk"

# -------------------------------------------------------
# 1. Probe vendor EGL libraries
# -------------------------------------------------------
egl_ok=0
gpu_vendor="unknown"

probe_egl() {
    local found=0

    # Check standard vendor EGL paths
    for dir in /vendor/lib64/egl /vendor/lib/egl; do
        if [ -d "$dir" ]; then
            # Look for any EGL implementation library
            for f in "$dir"/libEGL_*.so "$dir"/libGLESv2_*.so "$dir"/egl.cfg; do
                if [ -f "$f" ] 2>/dev/null; then
                    found=1
                    log_info "EGL found: $f"

                    # Detect GPU vendor from library name
                    case "$f" in
                        *adreno*|*ADRENO*)  gpu_vendor="adreno" ;;
                        *mali*|*MALI*)      gpu_vendor="mali" ;;
                        *powervr*|*PVR*|*_mtk*) gpu_vendor="powervr" ;;
                        *vivante*)          gpu_vendor="vivante" ;;
                        *freedreno*)        gpu_vendor="freedreno" ;;
                    esac
                    break 2
                fi
            done
        fi
    done

    # Also check for ANGLE or swiftshader as system fallback
    if [ $found -eq 0 ]; then
        for f in /system/lib64/egl/libEGL_angle.so /system/lib64/egl/libGLES_android.so; do
            if [ -f "$f" ] 2>/dev/null; then
                found=1
                gpu_vendor="swiftshader"
                log_warn "Only software EGL found: $f"
                break
            fi
        done
    fi

    return $((1 - found))
}

if probe_egl; then
    egl_ok=1
    log_info "Vendor EGL: OK (vendor=$gpu_vendor)"
else
    egl_ok=0
    log_warn "Vendor EGL: NOT FOUND — will force software rendering"
fi

setprop sys.gsi.gpu_egl_ok "$egl_ok" 2>/dev/null || true
setprop sys.gsi.gpu_vendor "$gpu_vendor" 2>/dev/null || true

# -------------------------------------------------------
# 2. Probe vendor Vulkan ICD
# -------------------------------------------------------
vulkan_ok=0

probe_vulkan() {
    # Check for Vulkan ICD libraries
    for dir in /vendor/lib64/hw /vendor/lib/hw; do
        if [ -d "$dir" ]; then
            for f in "$dir"/vulkan.*.so; do
                if [ -f "$f" ] 2>/dev/null; then
                    log_info "Vulkan ICD found: $f"
                    return 0
                fi
            done
        fi
    done

    # Check for ICD manifests
    for f in /vendor/etc/vulkan/icd.d/*.json; do
        if [ -f "$f" ] 2>/dev/null; then
            log_info "Vulkan ICD manifest found: $f"
            return 0
        fi
    done

    return 1
}

if probe_vulkan; then
    vulkan_ok=1
    log_info "Vendor Vulkan ICD: OK"
else
    vulkan_ok=0
    log_warn "Vendor Vulkan ICD: NOT FOUND"
fi

setprop sys.gsi.gpu_vulkan_ok "$vulkan_ok" 2>/dev/null || true

# -------------------------------------------------------
# 3. Apply EGL/rendering fallbacks if vendor GPU is broken
# -------------------------------------------------------

if [ "$egl_ok" -eq 0 ]; then
    log_warn "Applying software rendering fallback"
    setprop debug.hwui.renderer skiagl 2>/dev/null || true
    setprop ro.config.avoid_gfx_accel true 2>/dev/null || true
    setprop debug.egl.hw 0 2>/dev/null || true
fi

# -------------------------------------------------------
# 4. Detect known-bad GPU families and apply mitigations
# -------------------------------------------------------

apply_powervr_mitigations() {
    log_info "Applying PowerVR mitigations"
    # PowerVR Rogue GE8100 and similar have broken Skia Vulkan backend
    setprop debug.hwui.renderer opengl 2>/dev/null || true
    setprop ro.skia.ignore_swizzle true 2>/dev/null || true
    # Disable Vulkan for HWUI — PowerVR Vulkan is often broken
    setprop debug.hwui.use_vulkan false 2>/dev/null || true
    if [ "$vndk" -le 28 ]; then
        setprop debug.hwui.use_buffer_age false 2>/dev/null || true
    fi
}

apply_old_adreno_mitigations() {
    log_info "Applying old Adreno mitigations"
    # Adreno 3xx/4xx on old VNDK have broken compute shaders
    setprop debug.hwui.renderer skiagl 2>/dev/null || true
    setprop debug.egl.traceGpuCompletion 0 2>/dev/null || true
}

apply_sprd_mitigations() {
    log_info "Applying SPRD/Unisoc mitigations"
    setprop ro.config.avoid_gfx_accel true 2>/dev/null || true
    setprop debug.hwui.renderer skiagl 2>/dev/null || true
}

# Detect PowerVR (MediaTek devices with IMG GPU)
if [ "$gpu_vendor" = "powervr" ]; then
    apply_powervr_mitigations
elif [ -f /vendor/lib/egl/GLESv1_CM_mtk.so ] || [ -f /vendor/lib/egl/libGLESv1_CM_mtk.so ]; then
    # Check specifically for PowerVR Rogue GE8100
    if grep -qF 'PowerVR Rogue GE8100' /vendor/lib/egl/GLESv1_CM_mtk.so 2>/dev/null ||
       grep -qF 'PowerVR Rogue' /vendor/lib/egl/libGLESv1_CM_mtk.so 2>/dev/null; then
        gpu_vendor="powervr"
        setprop sys.gsi.gpu_vendor "$gpu_vendor" 2>/dev/null || true
        apply_powervr_mitigations
    fi
fi

# Detect old Adreno on old VNDK
if [ "$gpu_vendor" = "adreno" ] && [ "$vndk" -le 28 ]; then
    # Check board platform for old Qualcomm SoCs
    board=$(getprop ro.board.platform 2>/dev/null || echo "")
    case "$board" in
        msm8917|msm8937|msm8940|msm8916|msm8909)
            apply_old_adreno_mitigations
            ;;
    esac
fi

# Detect SPRD/Unisoc
if [ -e /dev/sprd-adf-dev ]; then
    gpu_vendor="sprd"
    setprop sys.gsi.gpu_vendor "$gpu_vendor" 2>/dev/null || true
    apply_sprd_mitigations
fi

# -------------------------------------------------------
# 5. Conservative GPU capability properties
# -------------------------------------------------------
# Only set these if vendor hasn't already set them to
# something lower (don't upgrade vendor's own assessment).

current_gles=$(getprop ro.opengles.version 2>/dev/null || echo "")
if [ -z "$current_gles" ]; then
    # No vendor value — set conservative GLES 3.1
    setprop ro.opengles.version 196609 2>/dev/null || true
    log_info "Set ro.opengles.version=196609 (GLES 3.1)"
elif [ "$current_gles" -gt 196610 ] 2>/dev/null; then
    # Vendor claims GLES 3.2 — cap to 3.1 if VNDK is old
    if [ "$vndk" -le 30 ]; then
        setprop ro.opengles.version 196609 2>/dev/null || true
        log_warn "Capped ro.opengles.version from $current_gles to 196609 (VNDK $vndk)"
    fi
fi

# Vulkan capability: set conservative if not set or too high
if [ "$vulkan_ok" -eq 1 ]; then
    current_vk_level=$(getprop ro.hardware.vulkan.level 2>/dev/null || echo "")
    if [ -z "$current_vk_level" ] || [ "$current_vk_level" -gt 1 ] 2>/dev/null; then
        setprop ro.hardware.vulkan.level 0 2>/dev/null || true
        log_info "Set ro.hardware.vulkan.level=0 (baseline)"
    fi

    current_vk_ver=$(getprop ro.hardware.vulkan.version 2>/dev/null || echo "")
    if [ -z "$current_vk_ver" ]; then
        # Vulkan 1.1.0 = 4198400
        setprop ro.hardware.vulkan.version 4198400 2>/dev/null || true
        log_info "Set ro.hardware.vulkan.version=4198400 (Vulkan 1.1)"
    fi
else
    # No Vulkan ICD — explicitly disable Vulkan
    setprop ro.hardware.vulkan.level -1 2>/dev/null || true
    setprop ro.hardware.vulkan.version 0 2>/dev/null || true
    log_warn "Vulkan disabled (no ICD found)"
fi

# -------------------------------------------------------
# 6. Vulkan extension blocklist
# -------------------------------------------------------
BLOCKLIST_FILE="/system/etc/gpu_vulkan_blocklist.cfg"

if [ "$vulkan_ok" -eq 1 ] && [ -f "$BLOCKLIST_FILE" ]; then
    blocked_extensions=""
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        case "$line" in
            '#'*|'') continue ;;
        esac
        # Trim whitespace
        ext=$(echo "$line" | tr -d '[:space:]')
        if [ -n "$ext" ]; then
            if [ -z "$blocked_extensions" ]; then
                blocked_extensions="$ext"
            else
                blocked_extensions="$blocked_extensions,$ext"
            fi
        fi
    done < "$BLOCKLIST_FILE"

    if [ -n "$blocked_extensions" ]; then
        setprop debug.vulkan.disabled.extensions "$blocked_extensions" 2>/dev/null || true
        log_info "Vulkan extension blocklist applied ($(echo "$blocked_extensions" | tr ',' '\n' | wc -l) extensions)"
    fi
fi

# -------------------------------------------------------
# 7. SurfaceFlinger stability properties
# -------------------------------------------------------
# These help avoid crashes in SurfaceFlinger's HWC/GPU path.

# Allow SurfaceFlinger to latch unsignaled buffers —
# prevents deadlocks when vendor HWC is slow.
setprop debug.sf.latch_unsignaled 1 2>/dev/null || true

# Conservative frame buffer count — avoids triple-buffer
# races on broken HWC implementations.
setprop ro.surface_flinger.max_frame_buffer_acquired_buffers 3 2>/dev/null || true

# Disable frame rate override — broken on many vendor HWC2
setprop ro.surface_flinger.enable_frame_rate_override false 2>/dev/null || true

# -------------------------------------------------------
# 8. eglGetConfigAttrib safety — via HWUI/EGL properties
# -------------------------------------------------------
# When vendor eglGetConfigAttrib returns EGL_BAD_ATTRIBUTE or
# invalid values, these properties ensure frameworks don't abort.

# Use relaxed EGL config selection — accept configs even if
# some attributes are missing or have unexpected values.
setprop debug.egl.force_msaa false 2>/dev/null || true

# Don't require EGL_RECORDABLE_ANDROID — some vendors don't support it
setprop debug.egl.recordable 0 2>/dev/null || true

# WebView: prefer software rendering path for stability
if [ "$egl_ok" -eq 0 ] || [ "$gpu_vendor" = "powervr" ] || [ "$gpu_vendor" = "sprd" ]; then
    setprop debug.hwui.webview_overlays_enabled false 2>/dev/null || true
    log_warn "WebView GPU overlays disabled for stability"
fi

# -------------------------------------------------------
# Done
# -------------------------------------------------------
setprop sys.gsi.gpu_stability_done 1 2>/dev/null || true

log_info "=== GPU Stability Check Complete ==="
log_info "  GPU vendor : $gpu_vendor"
log_info "  EGL OK     : $egl_ok"
log_info "  Vulkan OK  : $vulkan_ok"
log_info "  VNDK       : $vndk"

exit 0
