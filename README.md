# Android 16 GSI Builder for Android 15 Vendors

> **AIDL-only · Binder-only IPC · Lazy & Optional HALs**
> HIDL-only vendor partitions (pre-Android 13) are **not supported**.

This project builds an **Android 16 Generic System Image (GSI)** that boots on
devices with **Android 15 Vendor** partitions. It enforces three design principles
to maximize boot reliability across diverse vendors:

1. **Binder-only IPC** — No hwbinder, no hwservicemanager, no HIDL transport
2. **AIDL-only HALs** — All HAL declarations use Stable AIDL
3. **Lazy & optional HALs** — No HAL is accessed during boot; missing HALs degrade gracefully

## Prerequisites

- **Disk Space**: 300GB+ free
- **RAM**: 32GB+ recommended (16GB minimum with swap)
- **OS**: Ubuntu 22.04 LTS or newer

## Project Structure

```
Vendor15-GSI/
├── build.sh                                 # Main build script
├── compatibility_matrix_vendor15_frozen.xml  # Frozen FCM (all HALs optional, AIDL-only)
├── .gitignore
│
├── # ── Survival Mode: Boot Gate ──
├── gsi_survival.rc                          # Init: upgrade-only boot gate
├── gsi_survival_check.sh                    # SDK comparison + cache sanitation
├── vendor15_survival.mk                     # Master makefile (includes all .mk below)
│
├── # ── Runtime Mitigation Scripts ──
├── boot_safety.sh / .mk / gsi_boot_safety.rc
├── gpu_stability.sh / .mk / gsi_gpu_stability.rc
├── gpu_vulkan_blocklist.cfg                 # Vulkan extension blocklist
├── hal_gap_mitigations.sh / .mk / gsi_hal_mitigations.rc
├── app_compat_mitigations.sh / .mk / gsi_app_compat.rc
├── forward_compat.sh / .mk / gsi_forward_compat.rc
├── hal_probe.sh / gsi_hal_probe.rc          # Layer 6: runtime HAL liveness probing
├── survival_diagnostics.sh / gsi_diagnostics.rc  # Layer 7: boot telemetry
│
├── # ── Supporting Infrastructure ──
├── .github/workflows/
│   ├── build_gsi.yml                        # CI: GSI build (self-hosted runner)
│   └── survival_test.yml                    # CI: static + runtime validation
├── build/make/
│   ├── core/vndk_compat.mk
│   └── tools/vndk_compat/                   # VNDK Compatibility Engine (Python)
│       ├── vndk_compat_engine.py
│       ├── vndk_diff_engine.py
│       ├── analyze_dependencies.py
│       ├── generate_linker_config.py
│       ├── shim_generator.py
│       └── ...                              # models/, policies/, etc.
├── docs/
│   └── VENDOR15_LIFETIME_EXTENSION_ARCHITECTURE.md
├── patches/
│   ├── build/make/                          # VNDK compat patch
│   ├── device/phh/treble/                   # Survival + HIDL removal (5 patches)
│   ├── frameworks/base/                     # VINTF bypass
│   └── system/core/                         # Init VINTF bypass
├── scripts/
│   ├── apply_patches.sh
│   ├── validate_patches.sh
│   ├── verify_aidl_only.sh
│   └── verify_survival.sh
├── sepolicy/
│   └── vendor15_survival.te                 # SELinux policy for survival mode
├── tools/
│   ├── vendor15-cli.sh                      # Developer CLI (diagnose, probe, status...)
│   ├── diagnostics/survival_diagnostics.sh
│   ├── hal_prober/hal_probe.sh
│   ├── matrix_optimizer/optimize_matrix.py
│   ├── shim_generator/generate_mapper_shim.py
│   └── test_harness/survival_test.sh
└── trebledroid/                             # TrebleDroid submodules
    ├── device_phh_treble/
    ├── vendor_hardware_overlay/
    └── treble_app/
```

## Runtime Mitigation System

The GSI ships **7 runtime mitigation scripts** that execute in a deterministic
chain during boot via `init` property triggers. Each script probes vendor
capabilities at runtime and sets conservative system properties.

### Execution Chain

```
post-fs-data
  └─ boot_safety (18 props)
       └─ gpu_stability (31 props)
            └─ hal_mitigations (45 props)
                 └─ app_compat (43 props)
                      └─ forward_compat (40 props)
                           └─ hal_probe (16 HALs probed, reactive fallbacks)
                                └─ diagnostics (structured JSON telemetry)
                                     └─ sys.gsi.all_mitigations_done=1
```

**Total: ~177 runtime property adjustments + 16 HAL probes + 43 build-time defaults**

### Mitigation Layers

| Layer | Script | Purpose |
|-------|--------|---------|
| **1. Boot Safety** | `boot_safety.sh` | Rescue Party suppression, sdcardfs→FUSE, atrace disable, SurfaceFlinger crash recovery, watchdog timeout, tombstone limits |
| **2. GPU Stability** | `gpu_stability.sh` | GPU vendor detection (Adreno/Mali/PowerVR/Xclipse/IMG), Vulkan extension blocklist, software rendering fallback |
| **3. HAL Gaps** | `hal_gap_mitigations.sh` | 7 HAL areas: HWC composer, Power ADPF, WiFi 6E/7, Audio spatial, Camera v4, Biometrics v5, Radio VoNR |
| **4. App Compat** | `app_compat_mitigations.sh` | Camera LIMITED cap, BT LE Audio→A2DP fallback, NNAPI CPU-only, biometric PIN fallback, WiFi advanced masking |
| **5. Forward Compat** | `forward_compat.sh` | AIDL version probing, ServiceManager resilience, Health/KeyMint gating, AVF/pVM disable, A18 compositor masking |

### Design Rules

- Every operation guarded with `|| true` — no script can crash
- `set +e` at top of every script — no abort on command failure
- Property ownership: each property has exactly one authoritative script
- Chain ordering prevents race conditions between scripts

## Code Fixes

### Bluetooth HidlToAidlMiddleware (3 LOG(FATAL) neutralized)

The HIDL-to-AIDL bridge in `trebledroid/device_phh_treble/bluetooth/audio/`
contained 3 `LOG(FATAL)` calls that killed the BT audio service when a vendor
sent an unexpected codec type (Samsung Scalable, aptX Adaptive, etc.).
Replaced with `LOG(ERROR)` + safe fallback returns.

## Vendor Compatibility

### Supported Vendors (AIDL-Only)

| Vendor Type | Supported | Notes |
|-------------|-----------|-------|
| Android 15 with AIDL HALs | ✅ Yes | Primary target |
| Android 14 with AIDL HALs | ✅ Likely | Most A14 vendors have AIDL |
| Android 13 with AIDL HALs | ⚠️ Possible | May lack newer AIDL versions |
| Pre-A13 (HIDL-only) | ❌ No | Not supported |

### Why AIDL-Only & Binder-Only?

- **Boot reliability**: Eliminates dual-transport complexity
- **Single IPC path**: All HAL communication uses binder
- **Forward-compatible**: Android 17+ drops HIDL entirely
- **Reduced failure surface**: No HIDL→AIDL adapters, no hwservicemanager races

### HAL Requirements

All HALs in the frozen compatibility matrix are marked `optional="true"`.
Missing vendor HALs degrade gracefully — they **never block boot**.

## HIDL Removal (Patches 0002–0005)

| Patch | What it Removes | Why |
|-------|----------------|-----|
| `0002` | HIDL fingerprint v2.1 | hwbinder transport → SELinux denials |
| `0003` | HIDL audio @2.0–7.1 | False hwbinder registrations stall boot |
| `0004` | HIDL library registrations | vendor HIDL JARs waste classloader resources |
| `0005` | HIDL packages + Oppo compat services | HIDL boot JARs loaded by Zygote |

## Survival Mode

The GSI includes a **survival mode** system that:

1. **Upgrade-only enforcement** — Prevents SDK downgrades that corrupt userdata
2. **Cache sanitation** — Clears dalvik-cache, resource-cache on SDK upgrades
3. **VINTF bypass** — Freezes compatibility matrix at Vendor15 HAL versions
4. **Rescue Party suppression** — Prevents factory reset on framework crashes
5. **Chained runtime mitigations** — 5 scripts execute in deterministic order
6. **Fatal path neutralization** — All LOG(FATAL) in repo code eliminated
7. **A17/18 forward-compatibility** — AIDL version probing and feature masking

### Boot Gate Flow

```
post-fs-data
  └─ gsi_survival_check.sh
       ├─ first_boot  → record SDK baseline, continue
       ├─ normal      → same SDK, continue
       ├─ upgrade     → clear caches, update baseline, continue
       └─ downgrade   → HALT, log fatal, reboot to recovery
```

## How to Build

```bash
./build.sh
```

This will:
1. Initialize the AOSP repository (Android 16)
2. Sync the source code
3. Set up TrebleDroid device tree
4. Stage all survival mode files (boot safety, GPU, HAL, app compat, forward compat)
5. Apply all patches (VINTF bypass + HIDL removal + survival mode)
6. Build the GSI system image
7. Run post-build survival mode verification

### GitHub Actions (Self-Hosted Runner)

> A self-hosted runner with **300GB+ free** is required.

## Verification Scripts

| Script | When to Run | What it Checks |
|--------|-------------|----------------|
| `verify_aidl_only.sh` | After patches | No hwbinder, no HIDL, no mandatory HALs |
| `verify_survival.sh` | After building | Survival files installed, properties set |
| `validate_patches.sh` | Before building | All patches apply cleanly |

## Diagnostic Commands

```bash
# Check mitigation status
adb shell getprop sys.gsi.all_mitigations_done        # Should be 1
adb shell getprop sys.gsi.boot_safety_done             # Should be 1
adb shell getprop sys.gsi.gpu_stability_done           # Should be 1
adb shell getprop sys.gsi.hal_mitigations_done         # Should be 1
adb shell getprop sys.gsi.app_compat_done              # Should be 1
adb shell getprop sys.gsi.forward_compat_done          # Should be 1

# Check VINTF status
adb shell getprop ro.vintf.enforce                     # Should be false

# Check GPU vendor detection
adb shell getprop sys.gsi.gpu_vendor                   # adreno/mali/powervr/etc

# Check for crash loops
adb shell "dumpsys dropbox --print 2>/dev/null | grep -c system_server"

# Check SELinux
adb shell getenforce
```

## Patches

| # | Path | Patch | Purpose |
|---|------|-------|---------|
| 1 | `build/make/` | `0001-Integrate-VNDK-compatibility-framework` | VNDK compat engine integration |
| 2 | `device/phh/treble/` | `0001-Include-vendor15-survival-mode` | Survival mode inclusion in base.mk |
| 3 | `device/phh/treble/` | `0002-Remove-HIDL-fingerprint-from-framework-manifest` | HIDL fingerprint v2.1 removal |
| 4 | `device/phh/treble/` | `0003-Remove-HIDL-audio-from-bluetooth-manifest` | HIDL audio @2.0–7.1 removal |
| 5 | `device/phh/treble/` | `0004-Remove-HIDL-libraries-from-interfaces` | HIDL library registrations removal |
| 6 | `device/phh/treble/` | `0005-Remove-HIDL-packages-from-base-mk` | HIDL packages + Oppo compat removal |
| 7 | `frameworks/base/` | `0001-Allow-mismatched-vendor` | VINTF enforcement bypass in VintfObject |
| 8 | `system/core/` | `0001-Disable-VINTF-check-for-GSI` | Init-level VINTF check bypass |
