# Android 16 GSI Builder for Android 15 Vendors

> **AIDL-only** — This GSI targets Android 15 vendors with AIDL HAL implementations.
> HIDL-only vendor partitions (pre-Android 13) are **not supported**.

This project builds an **Android 16 Generic System Image (GSI)** that boots on
devices with **Android 15 Vendor** partitions. It includes survival mode (upgrade-only
enforcement, cache sanitation), VINTF bypass patches, and a frozen compatibility
matrix — all designed to maximize boot reliability across diverse vendors.

## Prerequisites

- **Disk Space**: 300GB+ free
- **RAM**: 32GB+ recommended (16GB minimum with swap)
- **OS**: Ubuntu 22.04 LTS or newer

## Project Structure

```
Vendor15-GSI/
├── build.sh                            # Main build script
├── compatibility_matrix_vendor15_frozen.xml  # Frozen FCM (all HALs optional, AIDL-only)
├── gsi_survival.rc                     # Init script: upgrade-only boot gate
├── gsi_survival_check.sh               # SDK comparison + cache sanitation
├── vendor15_survival.mk                # Build integration for survival mode
├── .github/
│   └── workflows/
│       └── build_gsi.yml               # Self-hosted runner workflow
├── build/
│   └── make/
│       ├── core/
│       │   └── vndk_compat.mk          # VNDK compat build integration
│       └── tools/
│           └── vndk_compat/            # VNDK Compatibility Engine (Python)
│               ├── Android.bp
│               ├── models/             # API model JSON files
│               ├── policies/           # Compat policies (v15)
│               ├── vndk_compat_engine.py
│               ├── vndk_diff_engine.py
│               ├── scoring_system.py
│               ├── shim_generator.py
│               └── linker_ir.py
├── docs/
│   └── VENDOR15_LIFETIME_EXTENSION_ARCHITECTURE.md
├── patches/                            # AOSP source tree patches
│   ├── build/make/                     # Framework integration
│   ├── device/phh/treble/              # Survival mode inclusion
│   ├── frameworks/base/                # VINTF bypass
│   └── system/core/                    # Init VINTF check bypass
├── scripts/
│   ├── apply_patches.sh                # Applies patches to AOSP tree
│   ├── validate_patches.sh             # Pre-build patch dry-run validator
│   └── verify_survival.sh             # Post-build survival mode verification
└── trebledroid/                        # TrebleDroid submodules
    ├── device_phh_treble/
    ├── vendor_hardware_overlay/
    └── treble_app/
```

## Vendor Compatibility

### Supported Vendors (AIDL-Only)

| Vendor Type | Supported | Notes |
|-------------|-----------|-------|
| Android 15 with AIDL HALs | ✅ Yes | Primary target |
| Android 14 with AIDL HALs | ✅ Likely | Most A14 vendors have AIDL |
| Android 13 with AIDL HALs | ⚠️ Possible | May lack newer AIDL versions |
| Pre-A13 (HIDL-only) | ❌ No | Not supported — too many breaking changes |

### Why AIDL-Only?

- **Boot reliability**: Eliminates dual-transport complexity (no hwbinder cross-domain SELinux)
- **Single IPC path**: All HAL communication uses binder, not binder+hwbinder
- **Forward-compatible**: Android 17+ will drop HIDL entirely
- **Reduced failure surface**: No HIDL→AIDL adapters, no hwservicemanager timing races

### HAL Requirements

All HALs in the frozen compatibility matrix are marked `optional="true"`.
Missing vendor HALs degrade gracefully — they do not block boot.

## Survival Mode

The GSI includes a **survival mode** system that:

1. **Upgrade-only enforcement** — Prevents SDK downgrades that would corrupt userdata
2. **Cache sanitation** — Clears dalvik-cache, resource-cache, and package_cache on SDK upgrades
3. **VINTF bypass** — Freezes the compatibility matrix against Vendor15 HAL versions
4. **Rescue Party suppression** — Prevents factory reset on repeated framework crashes

### Boot Gate Flow

```
post-fs-data
  └─ gsi_survival_check.sh
       ├─ first_boot  → record SDK baseline, continue
       ├─ normal      → same SDK, continue
       ├─ upgrade     → clear caches, update baseline, continue
       └─ downgrade   → HALT, log fatal, reboot
```

### Boot Safety Properties

- No `seclabel` — runs in init's universal context (works on all SELinux policies)
- No `class` membership — not part of core/main/hal (failure is invisible to boot)
- No `exec` shell blocks — all triggers use native init builtins
- Fail-open — errors default to "continue boot"

## How to Build

### Local Build

```bash
./build.sh
```

This will:
1. Initialize the AOSP repository (Android 16)
2. Sync the source code
3. Apply patches for vendor compatibility
4. Build the GSI system image
5. Run post-build survival mode verification

### GitHub Actions (Self-Hosted Runner)

> Standard GitHub-hosted runners do not have enough disk space.
> A self-hosted runner with **300GB+ free** is required.

1. Go to Repository → Settings → Actions → Runners
2. Click "New self-hosted runner"
3. Install the runner agent on your build server
4. The workflow runs via `runs-on: self-hosted`

## VNDK Compatibility Engine

Located in `build/make/tools/vndk_compat/`. Activated via:

```bash
export TARGET_ENABLE_VNDK_COMPAT=true
export TARGET_VENDOR_API_LEVEL=15
export TARGET_SYSTEM_API_LEVEL=16
```

Components:
- **API Model Generator** — Extracts symbol-level contracts from system libraries
- **Diff Engine** — Compares vendor requirements vs. system provisions
- **Scoring System** — Numeric health metric (`ro.vndk.compat_score`)
- **Shim Generator** — Creates forwarding shims for safe-to-shim symbols
- **Linker IR** — Graph-based linker namespace isolation

## Patches

| Directory | Purpose |
|-----------|---------|
| `build/make/` | VNDK compat framework integration |
| `device/phh/treble/` | Survival mode inclusion in base.mk |
| `frameworks/base/` | VINTF enforcement bypass in VintfObject |
| `system/core/` | Init-level VINTF check bypass |

Use `scripts/validate_patches.sh` to verify patches still apply cleanly before building.
