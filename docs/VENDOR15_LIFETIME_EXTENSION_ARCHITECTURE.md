# Vendor15 Compatibility Lifetime Extension Architecture

**Target**: Keep Android 17+ GSIs booting on a frozen Android 15 vendor partition  
**Philosophy**: Bootability over correctness, survival over completeness  
**Status**: Experimental / Research Design  

---

## Table of Contents

1. [Core Design Rationale](#1-core-design-rationale)
2. [Mandatory Android 17+ Requirements That Vendor15 Cannot Satisfy](#2-mandatory-android-17-requirements-that-vendor15-cannot-satisfy)
3. [GSI-Side Survival Techniques](#3-gsi-side-survival-techniques)
4. [Version-by-Version Viability Limits](#4-version-by-version-viability-limits)
5. [Relationship to Upgrade-Only (No-Downgrade) Model](#5-relationship-to-upgrade-only-no-downgrade-model)
6. [Concrete Implementation Examples](#6-concrete-implementation-examples)
7. [Risks and Hard Limits](#7-risks-and-hard-limits)

---

## 1. Core Design Rationale

### 1.1 Why Vendor15 + Newer Android Versions Are Fundamentally Incompatible

Android's Treble architecture was designed to decouple vendor and framework, but it was **never designed for indefinite forward compatibility**. The contract between system and vendor is the **Framework Compatibility Matrix (FCM)**, which declares the minimum HAL versions the framework requires. Each Android release raises this floor.

The incompatibility chain is:

```
Android 15 Vendor provides:   HAL versions frozen at FCM level 202404
Android 16 Framework expects: HAL versions at FCM level 202504
Android 17 Framework expects: HAL versions at FCM level 202604
Android 18 Framework expects: HAL versions at FCM level 202704 (projected)
```

Concretely, comparing the actual compatibility matrices from the AOSP source:

| HAL | Vendor15 provides | A16 (202504) requires | A17 (202604) requires |
|-----|------------------|----------------------|----------------------|
| `graphics.composer3` | v3 | v4 | v4 |
| `power` | v4 (AIDL) | v5-6 | v5-6 |
| `audio.core` | v1-2 (AIDL) | v1-3 | v1-4 |
| `radio.*` | v2-3 (AIDL) | v3-4 | v3-5 |
| `wifi` | v1-2 (AIDL) | v2-3 | v2-4 |
| `wifi.supplicant` | v2-3 (AIDL) | v3-4 | v4-5 |
| `vibrator` | v1-2 (AIDL) | v1-3 | v1-4 |
| `gnss` | v2-4 (AIDL) | v2-6 | v2-7 |
| `drm` | v1 (AIDL) | v1 | v1-2 |
| `mapper` (native) | v4-5 | v5.0 | v5.0 |
| `health` | v2-3 (AIDL) | v3-4 | v3-4 |
| `keymint` | v1-2 | v1-4 | v1-4 |

The **structural problem**: the framework does not just *prefer* newer HALs — it often **hard-codes expectations** into service startup paths. When `system_server` or `SurfaceFlinger` calls a HAL method that doesn't exist in an older version, the result is a crash, not graceful degradation.

### 1.2 Which Assumptions Must Be Broken

To survive, the GSI must violate these normally inviolable Android assumptions:

1. **VINTF compatibility is enforced** → Must be bypassed entirely (init and VintfObject)
2. **FCM level matches vendor API level** → Must be frozen/spoofed to Vendor15's level
3. **HAL version ranges are strict minimums** → Must be treated as optional/best-effort
4. **system_server hard-fails on missing capabilities** → Individual service managers must be patched to degrade gracefully
5. **VNDK libraries are provided by system at a matching version** → Must be shimmed or snapshotted from A15
6. **`ro.product.first_api_level` reflects reality** → May need to be spoofed

### 1.3 How This Differs from Official OTA / Pixel Upgrades

| Aspect | Official Model | This Model |
|--------|---------------|------------|
| Vendor update | Required alongside system | **Frozen forever** |
| VINTF enforcement | Fatal check | **Bypassed** |
| HAL version mismatch | Blocked by OTA | **Tolerated, features disabled** |
| Feature completeness | Guaranteed | **Best-effort, degraded** |
| Security patches | Vendor + System | **System-only** |
| CTS/VTS compliance | Required | **Not possible** |
| Google certification | Required | **Not applicable** |

---

## 2. Mandatory Android 17+ Requirements That Vendor15 Cannot Satisfy

### 2.1 Graphics Stack (Critical — Bootloop Risk: **EXTREME**)

**Gralloc / Allocator:**
- A17 FCM requires `android.hardware.graphics.allocator` AIDL v1-2
- Vendor15 *may* provide v1 (first shipped in A13 AIDL migration). Vendors still on HIDL `IAllocator@4.0` are **not supported** (AIDL-only policy)
- **Fatal if missing**: `SurfaceFlinger` cannot allocate graphic buffers → black screen → bootloop appearance

**Mapper:**
- A17 FCM requires native `mapper` v5.0 (passthrough HAL loaded by `libui`)
- Vendor15 devices that shipped with mapper v4.0 will cause `libui` to fail to load the mapper → no buffer operations → **instant SurfaceFlinger crash**
- This is a *passthrough* (dlopen'd) HAL — there is no binder fallback

**Hardware Composer (HWC):**
- A17 FCM requires `android.hardware.graphics.composer3` AIDL v4
- Vendor15 likely provides composer3 AIDL v3. Vendors still on HIDL `IComposer@2.4` are **not supported** (AIDL-only policy)
- SurfaceFlinger's `HWComposer` wrapper calls version-specific methods. New methods on v4 that don't exist in v3 cause `UNKNOWN_TRANSACTION` binder errors → SurfaceFlinger treats these as fatal

**Survival strategy**: SurfaceFlinger must be patched to:
1. Fall back to software composition (GPU-only) when HWC methods fail
2. Accept mapper v4 via a shim `IMapper@5.0` wrapper on the system side
3. Tolerate missing allocator by falling back to ION/dmabuf directly (extremely fragile)

> [!CAUTION]
> The graphics stack is the single biggest bootloop risk. If SurfaceFlinger cannot start, Android cannot boot to launcher. Every A17→A18→A19 transition makes this worse.

### 2.2 Power HAL (Critical — Performance Impact: **HIGH**)

- A17 FCM requires `android.hardware.power` AIDL v5-6
- Vendor15 provides v4 at best (v4 was current for A15)
- The `PowerManagerService` in `system_server` queries power hint sessions using methods added in v5
- **Not bootloop-fatal by default**, but `PowerHintSession` creation failures cascade into thermal throttling issues and ANR storms

**Survival strategy**: 
- Patch `PowerManagerService` to catch `RemoteException` / `ServiceSpecificException` on new methods
- Set `ro.power.hint_session.enabled=false` to disable hint sessions entirely
- Vendor15's v4 power HAL *will* still respond to basic `setMode()` / `setBoost()` calls

### 2.3 Neural Networks / NNAPI (Non-Fatal — Degradation: **MODERATE**)

- A17 FCM lists `android.hardware.neuralnetworks` AIDL v1-4 as optional (`updatable-via-apex`)
- Vendor15 likely provides v1 (if any)
- The NNAPI runtime gracefully degrades — it falls back to CPU reference implementation
- **No bootloop risk**, but ML-heavy apps see dramatic performance drops

**Survival strategy**: No special action needed. NNAPI has always been designed to be optional.

### 2.4 Camera Provider (Non-Fatal with Caveats)

- A17 FCM requires `android.hardware.camera.provider` AIDL v1-3
- Vendor15 provides AIDL v1. Vendors still on HIDL `ICameraProvider@2.6-7` are **not supported** (AIDL-only policy)
- The `CameraService` (native daemon, not system_server) handles version negotiation reasonably well for basic capture
- **New features**: Ultra HDR, night mode extensions, etc. will crash if the framework blindly calls new AIDL methods

**Survival strategy**:
- Camera will work at baseline functionality
- Disable new camera features via `config_camera_features.xml` overlays

### 2.5 Input / Audio (Mixed Severity)

**Audio:**
- A17 FCM requires `android.hardware.audio.core` AIDL v1-4
- Vendor15 provides v1-2
- New methods in v3-4 for spatial audio, multi-zone audio will fail
- **AudioFlinger** generally handles version negotiation — basic audio will work
- The AIDL audio HAL was introduced in A14; Vendor15 should have it

**Input:**
- `android.hardware.input.processor` is optional
- HIDL `IInputClassifier@1.0` was dropped in the AIDL migration — vendors must provide the AIDL version or input classification is absent (no impact on basic touch/keyboard)

**Survival strategy**: Audio should work for basic playback/recording. Disable spatial audio features.

### 2.6 Where Framework Behavior Becomes Fatal

The following are **hard failure points** where the framework intentionally crashes rather than degrades:

| Component | Fatal Behavior | Trigger |
|-----------|---------------|---------|
| `SurfaceFlinger` | `LOG(FATAL)` on mapper load failure | Native mapper v5.0 not found |
| `SurfaceFlinger` | Abort on HWC initialization failure | composer3 v4 method missing |
| `init` (second stage) | `LOG(FATAL)` on VINTF check | Compatibility matrix mismatch |
| `vold` | Abort on KeyMint version check | KeyMint v1 when v3+ expected for new encryption modes |
| `system_server` | Crash in `PackageManagerService` | `ro.build.version.sdk` vs. `ro.product.first_api_level` conflict |
| `system_server` | Fatal in `DisplayManagerService` | Missing display HAL capabilities |
| `gatekeeperd` | Fatal if gatekeeper HAL missing | AIDL gatekeeper HAL not found |
| `wifi` service | Crash on supplicant version mismatch | v3 when v4+ expected (new methods) |

---

## 3. GSI-Side Survival Techniques

### 3.1 Freezing the Framework Compatibility Matrix

The most critical survival technique: **the GSI must ship a compatibility_matrix.xml that matches what Vendor15 actually provides**, not what Android 17+ nominally requires.

**Mechanism:**
1. At build time, replace the target FCM level with `202404` (Vendor15's era)
2. Ship a patched `compatibility_matrix.current.xml` that only declares HALs at versions Vendor15 provides
3. Set `PRODUCT_ENFORCE_VINTF_MANIFEST := false` (build-time flag, when available)
4. Patch `libvintf` to always report compatibility success

**Build-time approach (preferred):**
```makefile
# In device makefile or vndk_compat.mk
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE := \
    $(LOCAL_PATH)/compatibility_matrix_vendor15_frozen.xml

# Override the target FCM version
PRODUCT_SHIPPING_API_LEVEL := 35
PRODUCT_TARGET_FCM_VERSION := 202404
```

### 3.2 Downgrading HAL Version Expectations to Optional

For each HAL that Vendor15 cannot satisfy at the required version, the framework has three strategies:

**Strategy A: Make the HAL optional in FCM (preferred)**
```xml
<!-- Instead of mandatory -->
<hal format="aidl">
    <name>android.hardware.power</name>
    <version>5-6</version>  <!-- Vendor15 only has v4 -->
    ...
</hal>

<!-- Make it optional -->
<hal format="aidl" optional="true">
    <name>android.hardware.power</name>
    <version>4-6</version>  <!-- Accept v4 from Vendor15 -->
    ...
</hal>
```

**Strategy B: Widen the version range to include Vendor15**
```xml
<!-- Original A17 matrix -->
<hal format="aidl">
    <name>android.hardware.graphics.composer3</name>
    <version>4</version>
    ...
</hal>

<!-- Patched for Vendor15 survival -->
<hal format="aidl">
    <name>android.hardware.graphics.composer3</name>
    <version>3-4</version>  <!-- Accept v3 from Vendor15 -->
    ...
</hal>
```

**Strategy C: Remove the HAL entirely from FCM**
For HALs that are genuinely not needed for bootability (e.g., broadcastradio, automotive, contexthub):
```xml
<!-- Simply remove the <hal> block entirely -->
<!-- The framework service will fail to connect but should handle it -->
```

### 3.3 Framework Feature Flags and Properties

These system properties reduce the framework's capability assumptions:

```properties
# ===== VINTF / Compatibility Bypass =====
# Force the system to report a lower target FCM version
ro.boot.vintf_override_level=202404
# Disable VINTF enforcement in init
ro.vndk.version=35
persist.sys.vintf.enabled=false

# ===== Graphics Degradation =====
# Force GPU composition (bypass HWC)
debug.sf.hw=0
debug.sf.gpu_comp_tiling=1
# Disable HWC virtual display
debug.sf.enable_hwc_vds=0
# Force client composition
debug.hwc.force_gpu_comp=1
# Lower expected graphics HAL version
ro.hardware.gralloc=default

# ===== Power Management =====
# Disable power hint sessions (requires v5+)
ro.power.hint_session.enabled=false
# Disable ADPF (Android Dynamic Performance Framework)
ro.surface_flinger.use_power_hint_session=false

# ===== Camera =====
# Disable new camera features that require newer HAL
ro.camera.notify_nfc=0
persist.camera.HAL3.enabled=1

# ===== Neural Networks =====
# Force CPU-only NNAPI (no vendor accelerator)
debug.nn.cpuonly=1

# ===== Telephony =====
# Fallback to older radio interface
persist.radio.multisim.config=ss

# ===== General Feature Disablement =====
# Disable features that probe for missing HALs
ro.config.low_ram=false
persist.sys.disable_rescue=true
```

### 3.4 Preventing system_server Fatal Failures

`system_server` is the most complex survival target. It hosts 100+ system services, and any one of them crashing can take down the entire process (and trigger a bootloop after repeated crashes).

**Key patches required:**

**3.4.1 DisplayManagerService**
```java
// In DisplayManagerService.java, wrap HWC capability queries
try {
    mHwcCapabilities = mSurfaceControlProxy.getHwcDisplayCapabilities();
} catch (Exception e) {
    Slog.w(TAG, "HWC capabilities unavailable, using defaults", e);
    mHwcCapabilities = new HwcCapabilities(); // empty/default
}
```

**3.4.2 PowerManagerService**
```java
// In PowerManagerService.java, make power hint session creation non-fatal
private void createPowerHintSession() {
    try {
        // New A17 code that expects v5+ power HAL
        mSession = mPowerHal.createHintSession(...);
    } catch (RemoteException | UnsupportedOperationException e) {
        Slog.w(TAG, "Power hint sessions not available on this vendor", e);
        mSession = null; // Degraded mode
    }
}
```

**3.4.3 PackageManagerService version checks**
```java
// Block the SDK version sanity check that compares with vendor
// In PackageManagerService, around checkSdkSanity():
if (SystemProperties.getBoolean("persist.sys.gsi.skip_sdk_check", false)) {
    return; // Skip vendor SDK sanity check
}
```

**3.4.4 Rescue Party bypass**
When system_server crashes repeatedly, Android's "Rescue Party" triggers factory reset. This must be disabled:
```properties
persist.sys.disable_rescue=true
```
Or patched in `RescueParty.java` to never escalate past level 1.

---

## 4. Version-by-Version Viability Limits

### 4.1 Vendor15 + Android 17 (Viability: **LIKELY WITH HEAVY PATCHING**)

**What must be disabled to keep booting:**

| Feature | Reason | Impact |
|---------|--------|--------|
| HWC direct composition | composer3 v3→v4 gap | GPU fallback, higher power use |
| Power hint sessions | power HAL v4→v5 gap | Thermal/perf degradation |
| New WiFi features | supplicant v3→v4 gap | WiFi 7 features unavailable |
| Spatial audio | audio.core v2→v4 gap | Stereo-only audio |
| New camera modes | camera.provider v1→v3 gap | Basic camera only |
| Advanced biometrics | fingerprint/face v3→v5 gap | May lose FIDO2 features |
| New radio features | radio.* v3→v5 gap | Basic telephony works |

**Required patches (minimum for boot):**
1. VINTF bypass (init + VintfObject) — **already exists**
2. FCM frozen at 202404 — **partially exists** 
3. Mapper v5 shim or fallback — **must create**
4. composer3 v3 tolerance in SurfaceFlinger — **must create**
5. PowerManagerService degraded mode — **must create**
6. WiFi supplicant version tolerance — **must create**

**Prognosis**: Achievable. The A16→A17 delta is incremental. Most HALs bump by one AIDL version. This design assumes AIDL-only vendors — HIDL-only vendors are explicitly excluded from the support matrix.

### 4.2 Vendor15 + Android 18 (Viability: **EXPERIMENTAL**)

**New expected breakages:**

1. **Mapper v5→v6 or interface redesign**: If Android 18 introduces a new buffer allocation API, the mapper shim from A17 may not translate
2. **Binder protocol changes**: Minor binder wire format changes could break AIDL compatibility for older HAL stubs
3. **SELinux policy drift**: System SELinux policy increasingly references new vendor contexts that don't exist on Vendor15's `vendor_sepolicy`
4. **Init .rc changes**: New system services in A18 may depend on vendor-side init triggers that Vendor15 doesn't emit
5. **APEX module dependencies**: More framework code moves into APEX modules that expect specific vendor support

**Additional patches needed:**
- SELinux policy surgery: `permissive` domains for vendor-facing contexts
- More HAL shims (each version bump = new shim)
- Potential `init` trigger stubs on the system side
- `linkerconfig` adjustments as namespace rules change

**Prognosis**: Potentially workable but the shim layer grows significantly. Each new HAL method that the framework calls unconditionally is a new crash point to find and patch.

### 4.3 Vendor15 + Android 19+ (Viability: **STRUCTURAL FAILURE EXPECTED**)

**Structural reasons why it fails:**

1. **Kernel interface contracts change**: Android 19+ may require kernel features (e.g., io_uring, new binder features, memory tagging extensions) that Vendor15's frozen kernel cannot provide. The kernel is untouchable.

2. **SELinux becomes incompatible**: By A19, the gap between system and vendor SELinux policies is 4+ years. `neverallow` rules in the system policy will conflict with vendor policy, and the merge algorithm in `init` cannot resolve this.

3. **Binder NDK library (libbinder_ndk.so) ABI break**: If the binder NDK ABI changes (unlikely per-version but cumulative), vendor-side HAL processes linked against old libbinder crash on startup.

4. **Bionic (libc) ABI drift**: New system binaries expect libc symbols/behaviors that exist in system's bionic but vendor processes use vendor's frozen bionic. The linker namespace separation helps, but edge cases (e.g., `dlopen` across boundary) break.

5. **dm-verity / AVB metadata format changes**: If the verified boot metadata format changes, the boot chain cannot validate the new system image format against the old bootloader/kernel expectations.

6. **Filesystem format requirements**: New ext4/f2fs features required by A19's `vold` or `init` that the frozen kernel's filesystem drivers don't support.

7. **HAL removal, not just version bump**: Some HALs may be removed entirely from the framework, meaning the framework no longer has *any* code to talk to the old version. No amount of shimming helps when the client code is deleted.

```
Compatibility Gap Over Time:

A15 ──── A16 ──── A17 ──── A18 ──── A19 ──── A20
 │        │        │        │        │        │
 ├─ V15   │        │        │        │        │
 │  OK    │        │        │        │        │
 │        ├─ V15   │        │        │        │
 │        │  ~OK   │        │        │        │
 │        │        ├─ V15   │        │        │
 │        │        │  HEAVY │        │        │
 │        │        │  PATCH │        │        │
 │        │        │        ├─ V15   │        │
 │        │        │        │  EXPER │        │
 │        │        │        │        ├─ V15   │
 │        │        │        │        │  FAIL  │
 │        │        │        │        │        ├─ V15
 │        │        │        │        │        │  IMPOSSIBLE
```

**Hard deadline estimate**: Vendor15 + Android 19 (3 versions forward) is the likely practical limit. Android 20+ is structurally impossible without kernel/bootloader changes.

---

## 5. Relationship to Upgrade-Only (No-Downgrade) Model

### 5.1 Conditions Required to Preserve Userdata Across System Upgrades

Userdata preservation is achievable under these conditions:

1. **FBE key compatibility**: The file-based encryption keys stored in `/data/misc/vold/` and managed by `vold` + `keymint` must remain readable. The KeyMint HAL is on the vendor side (frozen at Vendor15's version). As long as the system-side `vold` can still speak the same KeyMint AIDL version, keys remain accessible.

2. **Database schema forward compatibility**: `system_server`'s databases in `/data/system/` (e.g., `packages.xml`, `settings_global.xml`, `accounts.db`) are versioned. Android handles forward migration (upgrade) but **not backward migration (downgrade)**.

3. **CE/DE storage structure**: Credential-Encrypted (CE) and Device-Encrypted (DE) storage structures must remain compatible. The directory layout (`/data/user/0/`, `/data/user_de/0/`) is extremely stable.

4. **`ro.build.version.sdk` must only increase**: The PackageManager uses this to determine schema versions. Decreasing it corrupts its internal state.

### 5.2 Why Downgrade Must Be Blocked

Downgrade (e.g., A17 GSI → A16 GSI with same Vendor15) causes **unrecoverable data corruption**:

1. **Database schema rollback failure**: `packages.xml` upgraded to A17 schema cannot be read by A16's `PackageManagerService`. Result: PMS crash loop → repeated factory reset attempts.

2. **Keystore version mismatch**: The `keystore2` database in `/data/misc/keystore/` is forward-migrated. A16's keystore2 cannot read A17's database format → all stored keys become inaccessible → apps lose authentication.

3. **RollbackManager state corruption**: A17 records rollback snapshots in `/data/rollback/`. A16 doesn't understand these → RollbackManager crash → system instability.

4. **Account Manager token format**: OAuth tokens and account DB format changes between versions. Downgrade = account re-authentication failures.

5. **SELinux context relabeling**: Files labeled with A17 SELinux contexts that don't exist in A16's policy → file access denials across the board.

### 5.3 Handling Critical Data Components

**`/data/system` (PackageManager, Settings, Users)**
```
Strategy: One-way migration gate
- Before GSI flash, record ro.build.version.sdk in /data/system/.gsi_sdk_version
- On boot, init.rc checks: if current SDK < recorded SDK → REFUSE TO BOOT
- Display recovery message: "Downgrade detected. Factory reset required."
```

**Keystore / KeyMint**
```
Strategy: Version-pinned key wrapping
- Vendor15's KeyMint HAL version is frozen
- System-side vold/keystore2 must use ONLY the key wrapping methods 
  available in Vendor15's KeyMint version
- New A17+ key wrapping algorithms must be disabled
- Set: ro.crypto.allow_encrypt_override=false
```

**Vold / FBE**
```
Strategy: Conservative encryption mode
- Do NOT enable new FBE modes introduced in A17+
- Pin FBE to AES-256-XTS + AES-256-CTS (Vendor15-supported modes)
- Patch vold to skip upgrade of encryption metadata format
- Set: ro.crypto.fbe_algorithm=aes-256-xts:aes-256-cts
```

**Metadata partition**
```
Strategy: Preserve metadata format
- /metadata stores critical boot state (e.g., checkpoint info, GSI status)
- Format must remain compatible with Vendor15's init expectations
- Do NOT enable metadata encryption upgrades
```

---

## 6. Concrete Implementation Examples

### 6.1 Frozen Compatibility Matrix (compatibility_matrix_vendor15_frozen.xml)

This is the **most critical file** in the entire survival architecture. It tells the framework exactly what to expect from the vendor.

```xml
<compatibility-matrix version="1.0" type="framework" level="202404">
    <!-- Graphics: Accept Vendor15's composer3 v3 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.graphics.composer3</name>
        <version>3-4</version>
        <interface>
            <name>IComposer</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Graphics: Accept Vendor15's allocator v1 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.graphics.allocator</name>
        <version>1-2</version>
        <interface>
            <name>IAllocator</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Power: Accept Vendor15's v4, make optional -->
    <hal format="aidl" optional="true">
        <name>android.hardware.power</name>
        <version>4-6</version>
        <interface>
            <name>IPower</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Audio: Accept Vendor15's v1-2 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.audio.core</name>
        <version>1-4</version>
        <interface>
            <name>IModule</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IConfig</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Camera: Keep wide version range -->
    <hal format="aidl" optional="true" updatable-via-apex="true">
        <name>android.hardware.camera.provider</name>
        <version>1-3</version>
        <interface>
            <name>ICameraProvider</name>
            <regex-instance>[^/]+/[0-9]+</regex-instance>
        </interface>
    </hal>

    <!-- WiFi: Accept Vendor15's v1-2 -->
    <hal format="aidl" optional="true" updatable-via-apex="true">
        <name>android.hardware.wifi</name>
        <version>1-4</version>
        <interface>
            <name>IWifi</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- WiFi Supplicant: Accept Vendor15's v2-3 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.wifi.supplicant</name>
        <version>2-5</version>
        <interface>
            <name>ISupplicant</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Radio: Accept Vendor15's v2-3 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.radio.config</name>
        <version>2-5</version>
        <interface>
            <name>IRadioConfig</name>
            <instance>default</instance>
        </interface>
    </hal>

    <hal format="aidl" optional="true">
        <name>android.hardware.radio.data</name>
        <version>2-5</version>
        <interface>
            <name>IRadioData</name>
            <instance>slot1</instance>
            <instance>slot2</instance>
        </interface>
    </hal>

    <hal format="aidl" optional="true">
        <name>android.hardware.radio.network</name>
        <version>2-5</version>
        <interface>
            <name>IRadioNetwork</name>
            <instance>slot1</instance>
            <instance>slot2</instance>
        </interface>
    </hal>

    <hal format="aidl" optional="true">
        <name>android.hardware.radio.modem</name>
        <version>2-5</version>
        <interface>
            <name>IRadioModem</name>
            <instance>slot1</instance>
            <instance>slot2</instance>
        </interface>
    </hal>

    <hal format="aidl" optional="true">
        <name>android.hardware.radio.sim</name>
        <version>2-5</version>
        <interface>
            <name>IRadioSim</name>
            <instance>slot1</instance>
            <instance>slot2</instance>
        </interface>
    </hal>

    <hal format="aidl" optional="true">
        <name>android.hardware.radio.voice</name>
        <version>2-5</version>
        <interface>
            <name>IRadioVoice</name>
            <instance>slot1</instance>
            <instance>slot2</instance>
        </interface>
    </hal>

    <hal format="aidl" optional="true">
        <name>android.hardware.radio.messaging</name>
        <version>2-5</version>
        <interface>
            <name>IRadioMessaging</name>
            <instance>slot1</instance>
            <instance>slot2</instance>
        </interface>
    </hal>

    <!-- KeyMint: Accept Vendor15's version -->
    <hal format="aidl" optional="true" updatable-via-apex="true">
        <name>android.hardware.security.keymint</name>
        <version>1-4</version>
        <interface>
            <name>IKeyMintDevice</name>
            <instance>default</instance>
            <instance>strongbox</instance>
        </interface>
    </hal>

    <!-- Health: Accept Vendor15's v2-3 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.health</name>
        <version>2-4</version>
        <interface>
            <name>IHealth</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Sensors: Accept Vendor15's version -->
    <hal format="aidl" optional="true">
        <name>android.hardware.sensors</name>
        <version>1-3</version>
        <interface>
            <name>ISensors</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Bluetooth: Keep as-is, generally stable -->
    <hal format="aidl" optional="true">
        <name>android.hardware.bluetooth</name>
        <interface>
            <name>IBluetoothHci</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Gatekeeper -->
    <hal format="aidl" optional="true">
        <name>android.hardware.gatekeeper</name>
        <version>1</version>
        <interface>
            <name>IGatekeeper</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Boot control -->
    <hal format="aidl" optional="true">
        <name>android.hardware.boot</name>
        <interface>
            <name>IBootControl</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Vibrator: Accept v1-2 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.vibrator</name>
        <version>1-4</version>
        <interface>
            <name>IVibrator</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- Thermal: Accept v2 -->
    <hal format="aidl" optional="true">
        <name>android.hardware.thermal</name>
        <version>2-3</version>
        <interface>
            <name>IThermal</name>
            <instance>default</instance>
        </interface>
    </hal>

    <!-- DRM: Accept v1 -->
    <hal format="aidl" optional="true" updatable-via-apex="true">
        <name>android.hardware.drm</name>
        <version>1-2</version>
        <interface>
            <name>IDrmFactory</name>
            <regex-instance>.*</regex-instance>
        </interface>
    </hal>

    <!-- Mapper: Accept v4-5 native -->
    <hal format="native" optional="true">
        <name>mapper</name>
        <version>4.0-5.0</version>
        <interface>
            <regex-instance>.*</regex-instance>
        </interface>
    </hal>

    <!-- REMOVE these HALs entirely (not present on most Vendor15 phone devices):
         - automotive.*
         - broadcastradio
         - contexthub
         - tv.*
         - bluetooth.ranging
         - bluetooth.socket
         - bluetooth.finder
         - bluetooth.lmp_event
         - bluetooth.gatt (new in A17)
         - security.see.*
         - virtualization.capabilities
    -->
</compatibility-matrix>
```

### 6.2 Build Properties (system.prop / system_ext.prop)

```properties
# ============================================================
# Vendor15 Compatibility Lifetime Extension - System Properties
# ============================================================

# ----- Identity & Version Spoofing -----
# Keep the device reporting Vendor15's API level for vendor compatibility
ro.product.first_api_level=35
ro.board.first_api_level=35

# ----- VINTF Bypass -----
# Force VINTF to report compatibility even with mismatched vendor
ro.vintf.enabled=false
ro.boot.vintf_override_level=202404

# ----- Graphics Survival -----
# Force GPU composition, bypass HWC for methods that don't exist
debug.sf.hw=0
debug.sf.gpu_comp_tiling=1
debug.sf.enable_hwc_vds=0
debug.hwc.force_gpu_comp=1
# Reduce SurfaceFlinger expectations
debug.sf.latch_unsignaled=1
debug.sf.disable_backpressure=1

# ----- Power Management Degradation -----
ro.power.hint_session.enabled=false
ro.surface_flinger.use_power_hint_session=false

# ----- NNAPI / ML -----
debug.nn.cpuonly=1

# ----- Security / Encryption Conservatism -----
# Pin encryption to Vendor15-compatible algorithms
ro.crypto.fbe_algorithm=aes-256-xts:aes-256-cts
ro.crypto.volume.metadata.method=dm-default-key
ro.crypto.allow_encrypt_override=false

# ----- Rescue Party Bypass -----
persist.sys.disable_rescue=true

# ----- GSI Upgrade Tracking -----
# Custom properties to track GSI version for upgrade-only enforcement
ro.gsi.compat.vendor_level=15
ro.gsi.compat.survival_mode=true

# ----- SDK / Framework Checks -----
persist.sys.gsi.skip_sdk_check=true
```

### 6.3 Init.rc Safeguards

**`/system/etc/init/gsi_survival.rc`** — Must be included in the GSI image:

> [!NOTE]
> The actual implementation uses **property-based SDK tracking** (`persist.sys.prev_sdk`)
> rather than the file-based approach (`/data/system/.gsi_last_sdk_version`) originally
> proposed. This is more robust because Android's property system handles persistence
> atomically and survives partial boots where file writes might not complete.

```rc
# ============================================================
# gsi_survival.rc
# Vendor15 Compatibility Lifetime Extension — Init Configuration
# ============================================================
#
# Flow:
#   1. post-fs-data: run gsi_survival_check.sh (SDK comparison)
#   2. Script sets sys.gsi.boot_decision property
#   3. Init reacts:
#      - "downgrade"  → halt boot, log fatal, reboot to recovery
#      - "upgrade"    → continue boot (caches already wiped by script)
#      - "normal"     → continue boot
#      - "first_boot" → continue boot
#
# Properties used:
#   persist.sys.prev_sdk       — high-water-mark of last booted SDK
#   persist.sys.gsi_upgrade    — "1" during the single upgrade boot
#   sys.gsi.boot_decision      — set by script, consumed by triggers
# ============================================================

# Service: gsi_survival_gate
# Runs the upgrade/downgrade check after /data is mounted.
service gsi_survival_gate /system/bin/sh /system/bin/gsi_survival_check.sh
    class core
    user root
    group root system
    oneshot
    disabled
    seclabel u:r:su:s0

on post-fs-data
    start gsi_survival_gate

# DOWNGRADE DETECTED — halt boot
on property:sys.gsi.boot_decision=downgrade
    write /dev/kmsg "GSI_SURVIVAL: FATAL: DOWNGRADE DETECTED"
    write /dev/kmsg "GSI_SURVIVAL: Flash SDK >= persist.sys.prev_sdk or wipe data."
    class_stop main
    class_stop late_start
    class_stop hal
    exec -- /system/bin/sleep 2
    setprop sys.powerctl reboot,recovery

# UPGRADE DETECTED
on property:sys.gsi.boot_decision=upgrade
    write /dev/kmsg "GSI_SURVIVAL: Upgrade boot in progress. Caches cleared."

# NORMAL BOOT
on property:sys.gsi.boot_decision=normal
    write /dev/kmsg "GSI_SURVIVAL: Normal boot. No version change detected."

# FIRST BOOT
on property:sys.gsi.boot_decision=first_boot
    write /dev/kmsg "GSI_SURVIVAL: First boot detected. SDK baseline recorded."

# Finalize upgrade flag on boot completion
on property:sys.boot_completed=1
    exec -- /system/bin/sh -c "\
        if [ \"$(getprop persist.sys.gsi_upgrade)\" = \"1\" ]; then \
            setprop persist.sys.gsi_upgrade 0; \
            log -t GSI_SURVIVAL -p i 'Upgrade boot completed.'; \
        fi"
    write /dev/kmsg "GSI_SURVIVAL: === Boot Complete ==="

# VINTF bypass properties (early-init)
on early-init
    setprop ro.vintf.enforce false
    setprop persist.sys.disable_rescue true
    write /dev/kmsg "GSI_SURVIVAL: Survival mode active (early-init)"
```

### 6.4 Must-Have Items That Will Otherwise Cause Bootloops

This is the **minimum survival checklist**. Missing ANY of these = bootloop:

| # | Item | What happens without it | Implementation |
|---|------|------------------------|----------------|
| 1 | VINTF bypass in `init` | `init` second stage aborts with `LOG(FATAL)` | Patch `init.cpp` — already in repo |
| 2 | `VintfObject::CheckCompatibility()` returns 0 | `system_server` refuses to start | Patch `android_os_VintfObject.cpp` — already in repo |
| 3 | Frozen FCM at level 202404 | Framework probes for HALs that don't exist → service crashes | Build custom `compatibility_matrix.xml` |
| 4 | Mapper v4→v5 shim OR SurfaceFlinger mapper fallback | `libui` crashes loading mapper → SurfaceFlinger dead → **bootloop** | Either create native shim library or patch `Gralloc5Mapper.cpp` |
| 5 | HWC version tolerance | SurfaceFlinger crashes calling v4 methods on v3 HAL | Patch `HWComposer.cpp` or force GPU composition via props |
| 6 | Rescue Party disabled | Crash loops trigger factory reset | `persist.sys.disable_rescue=true` |
| 7 | VNDK snapshot for v35 | Vendor processes fail to load system libraries | Include VNDK v35 snapshot in `/system/lib64/vndk-35/` |
| 8 | SELinux permissive or targeted neverallow fixes | Vendor processes denied access → HAL crashes → **bootloop** | `androidboot.selinux=permissive` on kernel cmdline or `setenforce 0` in init |
| 9 | SDK version sanity check bypass | PMS refuses to operate on "incompatible" data | Property + PMS patch |
| 10 | Downgrade blocker | Flashing older GSI corrupts `/data` → **brick** | `gsi_survival.rc` script |

### 6.5 Implemented Runtime Mitigation System

The following has been implemented and integrated into the build:

#### 6.5.1 Chained Execution Architecture

5 runtime scripts execute in deterministic order via `init` property triggers.
This eliminates race conditions between scripts that set overlapping properties.

```
post-fs-data
  └─ boot_safety.sh (18 props)
       └─ gpu_stability.sh (31 props)
            └─ hal_gap_mitigations.sh (45 props)
                 └─ app_compat_mitigations.sh (43 props)
                      └─ forward_compat.sh (40 props)
                           └─ sys.gsi.all_mitigations_done=1
```

Each `.rc` file starts its service only when the previous script sets its completion property.

#### 6.5.2 Layer Summary

| Layer | Script | Props | Key Mitigations |
|-------|--------|-------|------------------|
| 1. Boot Safety | `boot_safety.sh` | 18 | Rescue Party, sdcardfs→FUSE, atrace, SF crash recovery, watchdog 120s, tombstone limit |
| 2. GPU Stability | `gpu_stability.sh` | 31 | GPU vendor detection (Adreno/Mali/PowerVR/Xclipse/IMG), Vulkan blocklist, software fallback |
| 3. HAL Gaps | `hal_gap_mitigations.sh` | 45 | HWC composer, Power ADPF, WiFi 6E/7, Audio spatial, Camera v4, Biometrics v5, Radio VoNR |
| 4. App Compat | `app_compat_mitigations.sh` | 43 | Camera LIMITED, BT LE Audio→A2DP, NNAPI CPU-only, biometric PIN fallback |
| 5. Forward Compat | `forward_compat.sh` | 40 | AIDL version probing, Health/KeyMint gating, AVF/pVM disable, A18 compositor |

#### 6.5.3 Bluetooth LOG(FATAL) Neutralization

3 `LOG(FATAL)` calls in `HidlToAidlMiddleware.cpp` replaced with `LOG(ERROR)` + safe returns.
These killed the BT audio service when vendors sent unexpected codec types (Samsung Scalable, aptX Adaptive).

#### 6.5.4 Build Integration

`vendor15_survival.mk` includes all 9 makefiles in order:

```makefile
# 1. Survival mode base
# 2. VINTF enforcement disabled
# 3. Frozen FCM
# 4. VNDK compatibility
# 5. GPU stability
# 6. HAL gap mitigations
# 7. App compatibility
# 8. Boot safety
# 9. Forward compatibility
```

`build.sh` stages all files to the TrebleDroid survival directory.

#### 6.5.5 Safety Guarantees

- Every `setprop` guarded with `2>/dev/null || true`
- `set +e` at top of every script
- Property ownership: each property has exactly one authoritative script
- Chained execution eliminates parallel race conditions
- All scripts are `oneshot` + `disabled` — never restart on failure

---

## 7. Risks and Hard Limits

### 7.1 Security Implications

> [!WARNING]
> This architecture fundamentally compromises security. This must be explicitly accepted by anyone deploying it.

**Vendor-side security is frozen:**
- Kernel CVEs are **permanently unpatched** (vendor kernel is frozen)
- Vendor HAL vulnerabilities (graphics driver, modem firmware, TEE) are **permanently unpatched**
- SELinux running permissive (often necessary) removes **all mandatory access control**
- Bootloader is unlocked → physical access = full compromise

**System-side security is partially maintained:**
- Monthly security patches in the GSI cover framework-level CVEs
- App sandbox is intact (if SELinux is enforcing for `untrusted_app`)
- KeyMint/Keymaster operations still go through vendor TEE
- But: the TEE firmware itself is frozen → TEE exploits are permanent

**Practical risk level:**
- For a daily-driver phone: **UNACCEPTABLE**
- For a development/testing device: **Acceptable with awareness**
- For a kiosk/embedded single-purpose device: **Possibly reasonable**

### 7.2 App Compatibility Fallout

| Impact Area | Consequence |
|-------------|------------|
| Google Play Protect | Will flag the device as uncertified. GMS may not install. |
| SafetyNet / Play Integrity | Will fail. Banking apps, DRM content won't work. |
| Camera apps | Limited to basic functionality. Third-party camera apps may crash on missing features. |
| GPU-intensive apps | Performance regression from forced GPU composition. Some games may stutter. |
| WiFi 7 / 6E features | Unavailable if vendor HAL doesn't support them. |
| Bluetooth LE Audio | May not work if BT audio HAL version is insufficient. |
| ML/AI features | CPU-only inference, dramatically slower. |
| Biometric API apps | May see degraded biometric authentication. |

### 7.3 Why This Approach Inevitably Reaches an Endpoint

```mermaid
graph LR
    A["Vendor15 Frozen"] --> B["HAL Version Gap Grows"]
    B --> C["Framework Removes Old Codepaths"]
    C --> D["Shim Layer Becomes Unmaintainable"]
    D --> E["Kernel Interface Diverges"]
    E --> F["Binary Incompatibility"]
    F --> G["Unbootable"]
    
    style A fill:#2d5016,color:#fff
    style B fill:#5a6f1e,color:#fff
    style C fill:#8b7d2a,color:#fff
    style D fill:#b5651d,color:#fff
    style E fill:#cc4125,color:#fff
    style F fill:#990000,color:#fff
    style G fill:#660000,color:#fff
```

**The three terminal conditions:**

1. **Kernel ABI cliff**: When Android requires a kernel feature that doesn't exist in Vendor15's kernel (e.g., new ioctl, new binder version, KVM changes for pKVM), no amount of system-side patching can compensate. The kernel is a hard boundary.

2. **Cumulative shim failure**: Each Android version adds ~10-20 new HAL methods across all HALs. By Android 19, there are 40-60+ methods that need shimming. Each shim is a potential crash point. The combinatorial complexity of testing all paths becomes unmanageable.

3. **Framework code deletion**: When Google removes the legacy codepath for an old HAL version (not just deprecates it, but deletes the client code), there is nothing to shim to. The framework literally no longer contains the code to call the old HAL.

**Estimated timeline:**

| Android Version | Vendor15 Status | Effort Level |
|----------------|-----------------|--------------|
| A16 (current) | Working | Moderate (existing patches) |
| A17 | Likely bootable | Heavy patching required |
| A18 | Experimental | Very heavy patching, reliability issues |
| A19 | Structural limit | Kernel/SELinux likely block boot |
| A20+ | Not feasible | Fundamental binary incompatibility |

---

## Appendix A: Build Integration

Add to your `build.sh`:

```bash
# ===== Vendor15 Lifetime Extension Build Flags =====
export TARGET_ENABLE_VNDK_COMPAT=true
export TARGET_VENDOR_API_LEVEL=15
export TARGET_SYSTEM_API_LEVEL=17  # or 18, etc.

# Force FCM level to Vendor15's era
export PRODUCT_TARGET_FCM_VERSION=202404

# Include frozen compatibility matrix
export DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE=\
    "$(pwd)/compatibility_matrix_vendor15_frozen.xml"

# Include VNDK v35 snapshot
export BOARD_VNDK_VERSION=35
export PRODUCT_EXTRA_VNDK_VERSIONS="35"

# Disable VINTF enforcement at build level
export PRODUCT_ENFORCE_VINTF_MANIFEST=false

# Include survival init script
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/gsi_survival.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/gsi_survival.rc
```

## Appendix B: Patch Application Order

Patches must be applied in this order to avoid conflicts:

1. `system/core` — VINTF bypass in init (foundation)
2. `system/libvintf` — Compatibility check bypass
3. `frameworks/native` — SurfaceFlinger/HWC tolerance
4. `frameworks/base` — VintfObject + system_server resilience
5. `build/make` — Build system integration + frozen FCM
6. `hardware/interfaces` — Frozen compatibility matrix installation
7. `system/security` — Keystore conservative mode

## Appendix C: Diagnostic Commands

After booting a survival-mode GSI, use these to verify status:

```bash
# Check VINTF status
adb shell "getprop ro.vintf.enforce"
adb shell "vintf 2>&1 | head -20"

# Check HAL service status
adb shell "lshal -its 2>/dev/null | grep -E 'composer|power|audio|wifi|radio'"

# Check for crash loops
adb shell "dumpsys dropbox --print 2>/dev/null | grep -c system_server"

# Check SELinux status
adb shell "getenforce"
adb shell "cat /sys/fs/selinux/enforce"

# Check encryption status
adb shell "getprop ro.crypto.state"
adb shell "getprop ro.crypto.type"

# Check survival mode properties
adb shell "getprop ro.gsi.compat.survival_mode"
adb shell "getprop ro.gsi.compat.vendor_level"
adb shell "getprop sys.gsi.hwc_missing"
adb shell "getprop sys.gsi.downgrade_detected"

# Check SDK versions
adb shell "getprop ro.build.version.sdk"
adb shell "getprop ro.product.first_api_level"
adb shell "cat /data/system/.gsi_last_sdk_version"
```

---

*Document version: 2.0*  
*Last updated: 2026-03-02*  
*Applicable to: Vendor15 (Android 15, FCM 202404) + Android 16–18 GSIs*
