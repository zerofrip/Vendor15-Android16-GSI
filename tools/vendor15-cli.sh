#!/bin/bash
# ============================================================
# vendor15-cli.sh
# Vendor15 Survival Architecture — Developer CLI Tool
# ============================================================
#
# One-stop shop for Vendor15 survival tooling.
#
# Usage:
#   vendor15-cli.sh <command> [args...]
#
# Commands:
#   generate-matrix   Generate optimized compatibility matrix
#   generate-shim     Generate mapper shim source code
#   diagnose          Run diagnostics on connected device
#   test              Run survival test harness on device
#   probe             Run HAL capability probes on device
#   dp-detect         Run dynamic partition detection on device
#   avc-parse         Parse AVC denials and suggest SELinux rules
#   vndk-check        Check VNDK version mismatch on device
#   scaffold          Generate project directory layout
#   status            Show current device survival status
#   help              Show this help message
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADB="${ADB:-adb}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║   Vendor15 Survival Architecture CLI       ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

usage() {
    banner
    echo "Usage: $(basename "$0") <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  generate-matrix <vendor_manifest> [upstream_matrix] [output]"
    echo "      Generate optimized compatibility matrix from vendor manifest."
    echo "      Can also use --from-device to pull manifest via adb."
    echo ""
    echo "  generate-shim [vendor_ver] [target_ver] [output_dir]"
    echo "      Generate mapper shim C++ source code."
    echo "      Default: vendor_ver=4, target_ver=5"
    echo ""
    echo "  diagnose"
    echo "      Push and run survival diagnostics on connected device."
    echo ""
    echo "  test [timeout_secs]"
    echo "      Run survival test harness on connected device."
    echo "      Default timeout: 300s"
    echo ""
    echo "  probe"
    echo "      Push and run HAL probes on connected device."
    echo ""
    echo "  dp-detect"
    echo "      Run dynamic partition detection on connected device."
    echo ""
    echo "  avc-parse [logfile]"
    echo "      Parse AVC denials and generate suggested SELinux rules."
    echo "      Uses live device if no logfile specified."
    echo ""
    echo "  vndk-check"
    echo "      Check VNDK version mismatch on connected device."
    echo ""
    echo "  scaffold <output_dir>"
    echo "      Generate complete project directory layout with templates."
    echo ""
    echo "  status"
    echo "      Show current device survival mode status."
    echo ""
    echo "  help"
    echo "      Show this help message."
    echo ""
}

# ============================================================
# Command: generate-matrix
# ============================================================
cmd_generate_matrix() {
    banner
    echo "=== Generate Optimized Compatibility Matrix ==="
    echo ""

    local vendor_manifest="${1:-}"
    local upstream_matrix="${2:-}"
    local output="${3:-compatibility_matrix_vendor15_frozen.xml}"

    if [ "$vendor_manifest" = "--from-device" ]; then
        echo "Pulling vendor manifest from connected device..."
        python3 "$SCRIPT_DIR/matrix_optimizer/optimize_matrix.py" \
            --from-device \
            --upstream-matrix "${upstream_matrix:?'upstream matrix path required'}" \
            --output "$output" \
            --verbose
    elif [ -n "$vendor_manifest" ] && [ -n "$upstream_matrix" ]; then
        python3 "$SCRIPT_DIR/matrix_optimizer/optimize_matrix.py" \
            --vendor-manifest "$vendor_manifest" \
            --upstream-matrix "$upstream_matrix" \
            --output "$output" \
            --verbose
    else
        echo "Usage:"
        echo "  $(basename "$0") generate-matrix <vendor_manifest.xml> <upstream_matrix.xml> [output.xml]"
        echo "  $(basename "$0") generate-matrix --from-device <upstream_matrix.xml> [output.xml]"
        exit 1
    fi
}

# ============================================================
# Command: generate-shim
# ============================================================
cmd_generate_shim() {
    banner
    echo "=== Generate Mapper Shim ==="
    echo ""

    local vendor_ver="${1:-4}"
    local target_ver="${2:-5}"
    local output_dir="${3:-./mapper_shim_output}"

    python3 "$SCRIPT_DIR/shim_generator/generate_mapper_shim.py" \
        --vendor-version "$vendor_ver" \
        --target-version "$target_ver" \
        --output-dir "$output_dir"
}

# ============================================================
# Command: diagnose
# ============================================================
cmd_diagnose() {
    banner
    echo "=== Survival Diagnostics ==="
    echo ""

    # Check device connectivity
    if ! $ADB devices 2>/dev/null | grep -q "device$"; then
        echo -e "${RED}Error: No device connected via adb.${NC}"
        exit 2
    fi

    echo "Pushing diagnostics script to device..."
    $ADB push "$SCRIPT_DIR/diagnostics/survival_diagnostics.sh" \
        /data/local/tmp/survival_diagnostics.sh 2>/dev/null

    echo "Running diagnostics..."
    $ADB shell "chmod 755 /data/local/tmp/survival_diagnostics.sh && \
        sh /data/local/tmp/survival_diagnostics.sh" 2>/dev/null

    echo ""
    echo "=== Diagnostics JSON Output ==="
    $ADB shell "logcat -d -s GSI_DIAG:I" 2>/dev/null | \
        grep -o '{.*}' 2>/dev/null || echo "(no diagnostic events found)"

    echo ""
    echo "=== Diagnostics Properties ==="
    $ADB shell "getprop | grep gsi.diagnostics" 2>/dev/null || \
        echo "(no diagnostics properties set)"
}

# ============================================================
# Command: test
# ============================================================
cmd_test() {
    banner
    local timeout="${1:-300}"
    bash "$SCRIPT_DIR/test_harness/survival_test.sh" "--timeout" "$timeout"
}

# ============================================================
# Command: probe
# ============================================================
cmd_probe() {
    banner
    echo "=== HAL Capability Probing ==="
    echo ""

    if ! $ADB devices 2>/dev/null | grep -q "device$"; then
        echo -e "${RED}Error: No device connected via adb.${NC}"
        exit 2
    fi

    echo "Pushing HAL prober to device..."
    $ADB push "$SCRIPT_DIR/hal_prober/hal_probe.sh" \
        /data/local/tmp/hal_probe.sh 2>/dev/null

    echo "Running HAL probes..."
    $ADB shell "chmod 755 /data/local/tmp/hal_probe.sh && \
        sh /data/local/tmp/hal_probe.sh" 2>/dev/null

    echo ""
    echo "=== Probe Results ==="
    $ADB shell "getprop | grep sys.gsi.probe" 2>/dev/null || \
        echo "(no probe results found)"
}

# ============================================================
# Command: scaffold
# ============================================================
cmd_scaffold() {
    banner
    echo "=== Scaffold Project Layout ==="
    echo ""

    local output_dir="${1:-./vendor15_scaffold}"

    echo "Creating scaffold at: $output_dir"
    mkdir -p "$output_dir"/{patches/{system/core,frameworks/base,build/make,device/phh/treble},scripts,tools/{shim_generator,matrix_optimizer,test_harness,diagnostics,hal_prober},sepolicy,docs}

    # Template: system.prop
    cat > "$output_dir/system.prop" << 'PROP'
# ============================================================
# Vendor15 Survival Mode — System Properties Template
# ============================================================

# VINTF Bypass
ro.vintf.enabled=false
ro.boot.vintf_override_level=202404

# Identity
ro.product.first_api_level=35
ro.board.first_api_level=35

# Graphics (GPU composition)
debug.sf.hw=0
debug.sf.gpu_comp_tiling=1
debug.sf.enable_hwc_vds=0
debug.hwc.force_gpu_comp=1

# Power
ro.power.hint_session.enabled=false
ro.surface_flinger.use_power_hint_session=false

# ML/AI
debug.nn.cpuonly=1

# Encryption
ro.crypto.fbe_algorithm=aes-256-xts:aes-256-cts
ro.crypto.allow_encrypt_override=false

# Rescue Party
persist.sys.disable_rescue=true

# Survival Mode
ro.gsi.compat.vendor_level=15
ro.gsi.compat.survival_mode=true
persist.sys.gsi.skip_sdk_check=true
PROP

    # Template: init .rc
    cat > "$output_dir/gsi_survival_template.rc" << 'RC'
# Vendor15 Survival Mode — Init Script Template
# Copy to /system/etc/init/gsi_survival.rc

service gsi_survival_gate /system/bin/sh /system/bin/gsi_survival_check.sh
    class core
    user root
    group root system
    oneshot
    disabled
    seclabel u:r:su:s0

on post-fs-data
    start gsi_survival_gate

on early-init
    setprop ro.vintf.enforce false
    setprop persist.sys.disable_rescue true
RC

    # Template: SELinux policy
    cat > "$output_dir/sepolicy/vendor15_survival.te" << 'TE'
# Vendor15 Survival Mode — SELinux Policy Additions
#
# These rules are required when running in enforcing mode.
# In permissive mode (common for survival builds), these are
# not strictly necessary but prevent audit log spam.

# Allow mapper shim to be loaded as same_process_hal
# (only needed if using the mapper v5 shim .so)
# allow hal_graphics_mapper system_file:file { read open execute map };

# Allow survival scripts to query service_manager
# (already available in su context — no additional policy needed)

# Allow survival scripts to write to /dev/kmsg
# allow su kmsg_device:chr_file { write open };
TE

    # Template: Makefile
    cat > "$output_dir/vendor15_survival_template.mk" << 'MK'
# Vendor15 Survival Mode — Makefile Template
#
# Include from device/phh/treble/base.mk

DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += \
    device/phh/treble/vendor15/compatibility_matrix_vendor15_frozen.xml

PRODUCT_COPY_FILES += \
    device/phh/treble/vendor15/gsi_survival.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_survival.rc \
    device/phh/treble/vendor15/gsi_survival_check.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/gsi_survival_check.sh

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.gsi.compat.vendor_level=15 \
    ro.gsi.compat.survival_mode=true \
    persist.sys.disable_rescue=true

PRODUCT_ENFORCE_VINTF_MANIFEST := false
MK

    echo ""
    echo "Scaffold created with the following layout:"
    find "$output_dir" -type f | sort | sed "s|$output_dir|  .|"
    echo ""
    echo "Next steps:"
    echo "  1. Edit system.prop with device-specific properties"
    echo "  2. Place vendor manifest in $output_dir/ for matrix generation"
    echo "  3. Run: vendor15-cli.sh generate-matrix ..."
    echo "  4. Copy scaffold into your AOSP tree"
}

# ============================================================
# Command: status
# ============================================================
cmd_status() {
    banner
    echo "=== Device Survival Status ==="
    echo ""

    if ! $ADB devices 2>/dev/null | grep -q "device$"; then
        echo -e "${RED}Error: No device connected via adb.${NC}"
        exit 2
    fi

    local model=$($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    local sdk=$($ADB shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
    local survival=$($ADB shell getprop ro.gsi.compat.survival_mode 2>/dev/null | tr -d '\r')
    local vendor_level=$($ADB shell getprop ro.gsi.compat.vendor_level 2>/dev/null | tr -d '\r')
    local boot_completed=$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    local all_mitigations=$($ADB shell getprop sys.gsi.all_mitigations_done 2>/dev/null | tr -d '\r')
    local selinux=$($ADB shell getenforce 2>/dev/null | tr -d '\r')
    local boot_decision=$($ADB shell getprop sys.gsi.boot_decision 2>/dev/null | tr -d '\r')

    echo "Device Information:"
    echo "  Model:          $model"
    echo "  SDK:            $sdk"
    echo "  SELinux:        ${selinux:-unknown}"
    echo ""
    echo "Survival Mode:"
    echo -n "  Active:         "
    if [ "$survival" = "true" ]; then
        echo -e "${GREEN}YES${NC}"
    else
        echo -e "${RED}NO${NC}"
    fi
    echo "  Vendor Level:   ${vendor_level:-not set}"
    echo -n "  Boot Completed: "
    if [ "$boot_completed" = "1" ]; then
        echo -e "${GREEN}YES${NC}"
    else
        echo -e "${RED}NO${NC}"
    fi
    echo "  Boot Decision:  ${boot_decision:-not set}"
    echo -n "  Mitigations:    "
    if [ "$all_mitigations" = "1" ]; then
        echo -e "${GREEN}ALL COMPLETE${NC}"
    else
        echo -e "${YELLOW}INCOMPLETE${NC}"
        # Show individual chain status
        for prop in sys.gsi.boot_safety_done sys.gsi.gpu_stability_done sys.gsi.hal_mitigations_done sys.gsi.app_compat_done sys.gsi.forward_compat_done sys.gsi.hal_probe_done sys.gsi.diagnostics_done; do
            local val=$($ADB shell getprop "$prop" 2>/dev/null | tr -d '\r')
            local short=$(echo "$prop" | sed 's/sys.gsi.\(.*\)_done/\1/')
            if [ "$val" = "1" ]; then
                echo -e "    ${GREEN}✓${NC} $short"
            else
                echo -e "    ${RED}✗${NC} $short"
            fi
        done
    fi

    # HAL probes if available
    local probe_done=$($ADB shell getprop sys.gsi.probe.done 2>/dev/null | tr -d '\r')
    if [ "$probe_done" = "1" ]; then
        echo ""
        echo "HAL Probes:"
        local summary=$($ADB shell getprop sys.gsi.probe.summary 2>/dev/null | tr -d '\r')
        echo "  Summary: $summary"
        for hal in composer allocator power audio camera wifi bluetooth sensors health thermal keymint; do
            local status=$($ADB shell getprop "sys.gsi.probe.$hal" 2>/dev/null | tr -d '\r')
            if [ -n "$status" ]; then
                if [ "$status" = "alive" ]; then
                    echo -e "    ${GREEN}●${NC} $hal"
                elif [ "$status" = "timeout" ]; then
                    echo -e "    ${YELLOW}○${NC} $hal (timeout)"
                else
                    echo -e "    ${RED}✗${NC} $hal"
                fi
            fi
        done
    fi

    echo ""
}

# ============================================================
# Command: dp-detect
# ============================================================
cmd_dp_detect() {
    banner
    echo "=== Dynamic Partition Detection ==="
    echo ""

    if ! $ADB devices 2>/dev/null | grep -q "device$"; then
        echo -e "${RED}Error: No device connected via adb.${NC}"
        exit 2
    fi

    echo "Pushing detection script to device..."
    $ADB push "$PROJECT_ROOT/scripts/dynamic_partition_detect.sh" \
        /data/local/tmp/dynamic_partition_detect.sh 2>/dev/null

    echo "Running detection..."
    $ADB shell "chmod 755 /data/local/tmp/dynamic_partition_detect.sh && \
        sh /data/local/tmp/dynamic_partition_detect.sh" 2>/dev/null

    echo ""
    echo "=== Detection Results ==="
    for prop in sys.gsi.dp.detected sys.gsi.dp.slot_scheme sys.gsi.dp.retrofit \
                sys.gsi.dp.super_device sys.gsi.dp.super_size_mb sys.gsi.dp.partitions; do
        local val=$($ADB shell getprop "$prop" 2>/dev/null | tr -d '\r')
        printf "  %-30s %s\n" "$prop" "${val:-(not set)}"
    done

    echo ""
    echo "For flashing instructions, run:"
    echo "  bash scripts/dynamic_partition_prepare.sh"
}

# ============================================================
# Command: avc-parse
# ============================================================
cmd_avc_parse() {
    banner
    bash "$PROJECT_ROOT/scripts/parse_avc_denials.sh" "$@"
}

# ============================================================
# Command: vndk-check
# ============================================================
cmd_vndk_check() {
    banner
    echo "=== VNDK Version Mismatch Check ==="
    echo ""

    if ! $ADB devices 2>/dev/null | grep -q "device$"; then
        echo -e "${RED}Error: No device connected via adb.${NC}"
        exit 2
    fi

    echo "Pushing detection script to device..."
    $ADB push "$PROJECT_ROOT/vndklite/vndklite_detect.sh" \
        /data/local/tmp/vndklite_detect.sh 2>/dev/null

    echo "Running VNDK detection..."
    $ADB shell "chmod 755 /data/local/tmp/vndklite_detect.sh && \
        sh /data/local/tmp/vndklite_detect.sh" 2>/dev/null

    echo ""
    echo "=== VNDK Results ==="
    for prop in sys.gsi.vndk.system_version sys.gsi.vndk.vendor_version \
                sys.gsi.vndk.mismatch sys.gsi.vndk.version_delta; do
        local val=$($ADB shell getprop "$prop" 2>/dev/null | tr -d '\r')
        printf "  %-35s %s\n" "$prop" "${val:-(not set)}"
    done

    local mismatch=$($ADB shell getprop sys.gsi.vndk.mismatch 2>/dev/null | tr -d '\r')
    echo ""
    if [ "$mismatch" = "true" ]; then
        echo -e "${YELLOW}VNDK mismatch detected.${NC}"
        echo "  Consider building with: ./build.sh --vndklite"
    else
        echo -e "${GREEN}VNDK versions match. No action needed.${NC}"
    fi
}

# ============================================================
# Main dispatch
# ============================================================
COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    generate-matrix)    cmd_generate_matrix "$@" ;;
    generate-shim)      cmd_generate_shim "$@" ;;
    diagnose)           cmd_diagnose "$@" ;;
    test)               cmd_test "$@" ;;
    probe)              cmd_probe "$@" ;;
    dp-detect)          cmd_dp_detect "$@" ;;
    avc-parse)          cmd_avc_parse "$@" ;;
    vndk-check)         cmd_vndk_check "$@" ;;
    scaffold)           cmd_scaffold "$@" ;;
    status)             cmd_status "$@" ;;
    help|--help|-h)     usage ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        echo ""
        usage
        exit 1
        ;;
esac
