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
├── gsi_survival.rc                          # Init script: upgrade-only boot gate
├── gsi_survival_check.sh                    # SDK comparison + cache sanitation
├── vendor15_survival.mk                     # Build integration for survival mode
├── .github/workflows/                       # CI (self-hosted runner)
├── build/make/tools/vndk_compat/            # VNDK Compatibility Engine (Python)
├── docs/
│   └── VENDOR15_LIFETIME_EXTENSION_ARCHITECTURE.md
├── patches/                                 # AOSP + TrebleDroid patches
│   ├── build/make/
│   │   └── 0001-Integrate-VNDK-compatibility-framework.patch
│   ├── device/phh/treble/
│   │   ├── 0001-Include-vendor15-survival-mode.patch
│   │   ├── 0002-Remove-HIDL-fingerprint-from-framework-manifest.patch
│   │   ├── 0003-Remove-HIDL-audio-from-bluetooth-manifest.patch
│   │   ├── 0004-Remove-HIDL-libraries-from-interfaces.patch
│   │   └── 0005-Remove-HIDL-packages-from-base-mk.patch
│   ├── frameworks/base/
│   │   └── 0001-Allow-mismatched-vendor.patch
│   └── system/core/
│       └── 0001-Disable-VINTF-check-for-GSI.patch
├── scripts/
│   ├── apply_patches.sh                     # Applies patches to AOSP tree
│   ├── validate_patches.sh                  # Pre-build patch dry-run validator
│   ├── verify_aidl_only.sh                  # AIDL-only compliance checker
│   └── verify_survival.sh                   # Post-build survival mode verification
└── trebledroid/                             # TrebleDroid submodules
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

### Why AIDL-Only & Binder-Only?

- **Boot reliability**: Eliminates dual-transport complexity (no hwbinder cross-domain SELinux)
- **Single IPC path**: All HAL communication uses binder, not binder+hwbinder
- **No hwservicemanager**: AIDL-only vendors may not run hwservicemanager; HIDL declarations would cause stalled lookups and SELinux denials
- **Forward-compatible**: Android 17+ drops HIDL entirely
- **Reduced failure surface**: No HIDL→AIDL adapters, no hwservicemanager timing races, no HIDL Java libraries in boot classpath

### HAL Requirements

All HALs in the frozen compatibility matrix are marked `optional="true"`.
Missing vendor HALs degrade gracefully — they **never block boot**.

## HIDL Removal (Patches 0002–0005)

The TrebleDroid submodule ships legacy HIDL artifacts for backward compatibility
with older devices. The following are removed at build time to enforce AIDL-only policy:

| Patch | What it Removes | Why |
|-------|----------------|-----|
| `0002` | HIDL fingerprint v2.1 in `framework_manifest.xml` | hwbinder transport → SELinux denials on AIDL-only vendors |
| `0003` | HIDL audio @2.0–7.1 in `bluetooth_audio_system.xml` | False hwbinder service registrations stall boot |
| `0004` | HIDL library registrations in `interfaces.xml` | `android.hidl.manager` + vendor HIDL JARs waste classloader resources |
| `0005` | HIDL packages + Oppo/Oplus compat services in `base.mk` | HIDL boot JARs loaded by Zygote; compat services need hwbinder |

> **Note**: Oppo/Realme devices that rely on HIDL fingerprint compat services are
> out of scope. These devices require hwbinder, which is incompatible with the
> AIDL-only policy.

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
- No HAL access — zero binder/hwbinder calls during init
- Fail-open — errors default to "continue boot"

## How to Build

### Local Build

```bash
./build.sh
```

This will:
1. Initialize the AOSP repository (Android 16)
2. Sync the source code
3. Set up TrebleDroid device tree
4. Stage survival mode files
5. Apply all patches (VINTF bypass + HIDL removal + survival mode)
6. Build the GSI system image
7. Run post-build survival mode verification

### GitHub Actions (Self-Hosted Runner)

> Standard GitHub-hosted runners do not have enough disk space.
> A self-hosted runner with **300GB+ free** is required.

1. Go to Repository → Settings → Actions → Runners
2. Click "New self-hosted runner"
3. Install the runner agent on your build server
4. The workflow runs via `runs-on: self-hosted`

## Verification Scripts

| Script | When to Run | What it Checks |
|--------|-------------|----------------|
| `verify_aidl_only.sh` | After applying patches | No hwbinder, no HIDL fqnames, no HIDL packages, no mandatory HALs |
| `verify_survival.sh` | After building | Survival files installed, properties set, FCM in VINTF |
| `validate_patches.sh` | Before building | All patches apply cleanly to AOSP tree |

```bash
# Run AIDL-only compliance check
bash scripts/verify_aidl_only.sh

# Validate patches against AOSP tree
bash scripts/validate_patches.sh /path/to/aosp patches/
```

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
| `device/phh/treble/` (0001) | Survival mode inclusion in base.mk |
| `device/phh/treble/` (0002–0005) | HIDL removal for AIDL-only compliance |
| `frameworks/base/` | VINTF enforcement bypass in VintfObject |
| `system/core/` | Init-level VINTF check bypass |

Use `scripts/validate_patches.sh` to verify patches still apply cleanly before building.
