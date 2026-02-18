# Android 16 GSI Builder for Android 15 Vendors

This project provides a set of scripts and patches to build an **Android 16 Generic System Image (GSI)** capable of running on devices with **Android 15 Vendor** implementations.

It is designed to be automated via **GitHub Actions**, allowing for monthly builds aligned with Google's security updates.

## Prerequisites

- **Disk Space**: Building AOSP requires 300GB+ of free space.
- **RAM**: 32GB+ recommended (16GB minimum with swap).
- **OS**: Ubuntu 22.04 LTS or newer (or equivalent Linux distribution).

## Project Structure

```
android16_gsi_builder/
├── .github/workflows/  # GitHub Actions CI/CD configuration
├── trebledroid/        # TrebleDroid Submodules
│   ├── device_phh_treble/
│   ├── vendor_hardware_overlay/
│   └── treble_app/
├── patches/            # Patches to apply to AOSP source tree
│   ├── frameworks/base/
│   └── system/libvintf/
├── scripts/            # Helper scripts
│   └── apply_patches.sh
├── build.sh            # Main build script
└── README.md           # This file
```

## Features

- **TrebleDroid Integration**: Includes `device_phh_treble`, `vendor_hardware_overlay`, and `treble_app` as submodules for maximum compatibility.
- **Automated Patching**: Applies critical patches for Android 15 vendor compatibility.
- **Make Generation**: Automatically runs `generate.sh` to create GSI build targets.

## How to use

### Local Build

1. Ensure you have `repo` installed and configured.
2. Run the build script:
    ```bash
    ./build.sh
    ```
    This will:
    - Initialize the AOSP repository (Android 16).
    - Sync the source code.
    - Apply necessary patches for vendor compatibility.
    - Build the GSI system image.

### GitHub Actions (Self-Hosted Runner)

The workflow in `.github/workflows/build_gsi.yml` is **specifically configured for a Self-Hosted Runner**.
Standard GitHub-hosted runners (ubuntu-latest) do not have enough disk space (only ~14GB free) to build AOSP (requires 300GB+).

**Setup Instructions:**
1.  Go to your GitHub Repository -> Settings -> Actions -> Runners.
2.  Click "New self-hosted runner".
3.  Follow the instructions to install the runner agent on your build server (e.g., a powerful Linux machine/VPS).
4.  Ensure the runner has at least **300GB of free disk space**.
5.  Start the runner. The workflow will automatically pick it up via `runs-on: self-hosted`.

**Workflow Features:**
- **Cleanup**: The workflow includes steps to clean `out/` before and after builds to prevent disk usage from growing indefinitely.
- **Persistence**: It reuses the `.repo` directory for faster syncs on subsequent runs.

## Compatibility Notes

### Android 15 Vendor on Android 16 GSI
Android 15 deprecated the **VNDK (Vendor Native Development Kit)**. This means Android 16 system images do not include VNDK libraries by default.
- **Modern Vendors**: If your Android 15 vendor partition is fully compliant with the new architecture (libs in `/vendor`), it should work out of the box.
- **Legacy Vendors**: If your vendor partition expects VNDK libraries in `/system`, you might face missing symbol errors.
    - **Note**: The `old-vndk` variant (`treble_arm64_byN`) in `device_phh_treble` targets API 28/29 (Android 9/10) and is **not** suitable for Android 15 vendors.

### Using Android 15 Source Code
If you have access to the **Android 15 source code** for your device, you can improve compatibility by:
1.  **Building Missing HALs**: If specific hardware features (Camera, Sensors) break, you can compile the relevant HALs from source and include them in the build (or overlay them).
2.  **Debugging**: Use the source to trace symbol errors.
3.  **VNDK Injection**: If absolutely necessary, you can build the required shared libraries from the Android 15 source and manually add them to the GSI `system/lib64` (though this is "dirty" and discouraged in modern Treble).

## Patches

The `patches/` directory contains modifications to AOSP sources to allow Android 16 system to boot with Android 15 vendor blobs.
- **VINTF Checks (`system/libvintf`)**: Globally disabled by forcing `checkCompatibility` to always return `COMPATIBLE`. This ensures `init`, `system_server`, and other components don't fail due to vendor mismatches.
- **Legacy Support (`frameworks/base`)**: Adjustments to allow booting even if specific vendor requirements aren't met.

