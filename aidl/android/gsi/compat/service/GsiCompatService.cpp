/*
 * GsiCompatService.cpp
 *
 * Minimal native implementation of IGsiCompat.
 *
 * This service is purely system-side. It reads Android system properties
 * and exposes them via a typed binder interface. No vendor partition
 * access, no HAL dependencies, no boot-critical behavior.
 *
 * Boot safety:
 *   - Started by init AFTER sys.boot_completed=1
 *   - If this binary fails to start, boot is unaffected
 *   - Callers get null from ServiceManager if service is unavailable
 */

#define LOG_TAG "GsiCompatService"

#include <android-base/logging.h>
#include <android-base/properties.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <aidl/android/gsi/compat/BnGsiCompat.h>
#include <aidl/android/gsi/compat/CompatInfo.h>

#include <cstdlib>
#include <string>

using aidl::android::gsi::compat::BnGsiCompat;
using aidl::android::gsi::compat::CompatInfo;
using android::base::GetProperty;
using android::base::GetBoolProperty;
using android::base::GetIntProperty;
using ndk::ScopedAStatus;

namespace {

class GsiCompatService : public BnGsiCompat {
public:
    // ── IGsiCompat implementation ────────────────────────────

    ScopedAStatus isSurvivalModeActive(bool* _aidl_return) override {
        *_aidl_return = GetBoolProperty("ro.gsi.compat.survival_mode", false);
        return ScopedAStatus::ok();
    }

    ScopedAStatus getVendorApiLevel(int32_t* _aidl_return) override {
        *_aidl_return = GetIntProperty("ro.gsi.compat.vendor_level", 0);
        return ScopedAStatus::ok();
    }

    ScopedAStatus getSystemSdkVersion(int32_t* _aidl_return) override {
        *_aidl_return = GetIntProperty("ro.build.version.sdk", 0);
        return ScopedAStatus::ok();
    }

    ScopedAStatus getBootDecision(std::string* _aidl_return) override {
        *_aidl_return = GetProperty("sys.gsi.boot_decision", "unknown");
        return ScopedAStatus::ok();
    }

    ScopedAStatus getCompatInfo(CompatInfo* _aidl_return) override {
        _aidl_return->survivalModeActive =
            GetBoolProperty("ro.gsi.compat.survival_mode", false);
        _aidl_return->vendorApiLevel =
            GetIntProperty("ro.gsi.compat.vendor_level", 0);
        _aidl_return->systemSdkVersion =
            GetIntProperty("ro.build.version.sdk", 0);
        _aidl_return->previousSdkVersion =
            GetIntProperty("persist.sys.prev_sdk", 0);
        _aidl_return->bootDecision =
            GetProperty("sys.gsi.boot_decision", "unknown");
        _aidl_return->isUpgradeBoot =
            GetBoolProperty("persist.sys.gsi_upgrade", false);
        _aidl_return->vintfEnforced =
            GetBoolProperty("ro.vintf.enforce", false);
        return ScopedAStatus::ok();
    }
};

}  // namespace

int main(int /*argc*/, char** /*argv*/) {
    LOG(INFO) << "GsiCompatService starting (post-boot)";

    // Single-threaded — this service handles very low traffic
    ABinderProcess_setThreadPoolMaxThreadCount(0);

    auto service = ndk::SharedRefBase::make<GsiCompatService>();
    const std::string instance = std::string() + GsiCompatService::descriptor + "/default";

    binder_status_t status = AServiceManager_addService(
        service->asBinder().get(), instance.c_str());

    if (status != STATUS_OK) {
        LOG(ERROR) << "Failed to register gsi_compat service: " << status;
        return EXIT_FAILURE;
    }

    LOG(INFO) << "GsiCompatService registered as: " << instance;

    ABinderProcess_joinThreadPool();

    // Should not reach here
    return EXIT_FAILURE;
}
