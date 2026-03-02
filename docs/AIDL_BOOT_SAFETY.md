# GSI Compatibility AIDL Service — Boot Safety Analysis

## Summary

The `IGsiCompat` Stable AIDL service provides a typed, versioned binder
interface for querying GSI compatibility state. It is designed with
**boot safety as the absolute priority**.

## Architecture

```
                         SYSTEM PARTITION ONLY
    ┌─────────────────────────────────────────────────┐
    │                                                  │
    │  Callers (apps, shell)                           │
    │       │                                          │
    │       ▼                                          │
    │  ServiceManager.getService("gsi_compat")         │
    │       │                                          │
    │       ▼                                          │
    │  gsi_compat_service (native daemon)              │
    │       │                                          │
    │       ▼                                          │
    │  android::base::GetProperty()                    │
    │       │                                          │
    │       ▼                                          │
    │  System Properties                               │
    │  ├── ro.gsi.compat.survival_mode                 │
    │  ├── ro.gsi.compat.vendor_level                  │
    │  ├── ro.build.version.sdk                        │
    │  ├── persist.sys.prev_sdk                        │
    │  ├── sys.gsi.boot_decision                       │
    │  ├── persist.sys.gsi_upgrade                     │
    │  └── ro.vintf.enforce                            │
    │                                                  │
    └─────────────────────────────────────────────────┘
    ┌─────────────────────────────────────────────────┐
    │  VENDOR PARTITION (frozen A15) — UNTOUCHED       │
    └─────────────────────────────────────────────────┘
```

## Why This Is Safe For Boot

### 1. Not Boot-Critical

The service is started by init **only after** `sys.boot_completed=1`:

```rc
service gsi_compat_service /system/bin/gsi_compat_service
    disabled
    oneshot

on property:sys.boot_completed=1
    start gsi_compat_service
```

- `disabled` prevents automatic start during init
- `oneshot` means it runs once and does not restart
- No `class` membership — not part of `main`, `core`, or `hal`
- init does not wait for this service at any boot phase

### 2. Not a HAL

This service is **not** declared in any VINTF manifest or compatibility matrix:

- No `<hal>` entry in `compatibility_matrix_vendor15_frozen.xml`
- No `@VintfStability` annotation on the AIDL interface
- Registered in `ServiceManager`, not `hwservicemanager`
- `VintfObject::CheckCompatibility()` does not check for it

### 3. No Vendor Dependencies

The service reads **only** system properties set by the GSI itself:

| Property | Set By | Partition |
|----------|--------|-----------|
| `ro.gsi.compat.survival_mode` | `vendor15_survival.mk` | system |
| `ro.gsi.compat.vendor_level` | `vendor15_survival.mk` | system |
| `ro.build.version.sdk` | AOSP build | system |
| `persist.sys.prev_sdk` | `gsi_survival_check.sh` | data |
| `sys.gsi.boot_decision` | `gsi_survival_check.sh` | volatile |
| `persist.sys.gsi_upgrade` | `gsi_survival_check.sh` | data |
| `ro.vintf.enforce` | `gsi_survival.rc` | system |

No vendor files, vendor HALs, or vendor binder services are accessed.

### 4. Graceful Fallback

Before the service starts (during boot), or if it fails to start:

```java
// Java caller
IBinder binder = ServiceManager.getService("gsi_compat");
if (binder == null) {
    // Service not available — fall back to properties
    String decision = SystemProperties.get("sys.gsi.boot_decision", "unknown");
}
```

```cpp
// C++ caller
auto service = IGsiCompat::fromBinder(
    ndk::SpAIBinder(AServiceManager_checkService("gsi_compat")));
if (service == nullptr) {
    // Fallback to properties
}
```

The service failing is **functionally equivalent** to the service not existing.
All state is available via properties regardless.

### 5. No SELinux Vendor Policy Changes

The service runs in a system SELinux domain. The required policy grants
are entirely within system sepolicy:

```te
# system/sepolicy/private/gsi_compat_service.te (conceptual)
type gsi_compat_service, domain;
type gsi_compat_service_exec, system_file_type, exec_type, file_type;

init_daemon_domain(gsi_compat_service)

# Read system properties
get_prop(gsi_compat_service, system_prop)
get_prop(gsi_compat_service, default_prop)

# Binder
binder_use(gsi_compat_service)
add_service(gsi_compat_service, gsi_compat_service_type)
```

No vendor sepolicy modifications are needed.

## Failure Modes

| Scenario | Impact | Boot Effect |
|----------|--------|-------------|
| Binary missing | Service doesn't start | **None** — init ignores missing disabled services |
| Binary crashes on start | Service doesn't register | **None** — callers get null |
| Service crashes after registration | Binder dies | **None** — callers handle DeadObjectException |
| SELinux blocks the service | Service is denied | **None** — boot proceeds without it |
| Properties are empty | Service returns defaults | **None** — empty/0/false values |

**In every failure mode, boot proceeds normally.**

## Version Evolution

The AIDL interface is versioned. Future versions can add methods without
breaking existing callers:

| Version | Changes |
|---------|---------|
| v1 | Initial: 5 methods, CompatInfo parcelable |
| v2+ | Add methods only — no removal, no signature changes |

Callers can check the interface version at runtime:
```java
int version = service.getInterfaceVersion();
```

## Assumptions About Vendor Behavior

1. **No assumptions are made about vendor behavior.** The service does not
   interact with the vendor partition in any way.
2. The service assumes system properties are set by the GSI's own init
   scripts and makefiles — which it controls entirely.
3. The vendor is assumed to be a stock Android 15 image with no custom
   system services that conflict with the `"gsi_compat"` service name.
