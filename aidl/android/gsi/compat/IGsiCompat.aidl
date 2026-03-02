// IGsiCompat.aidl
// Stable versioned AIDL interface for GSI Compatibility reporting.
//
// This is a SYSTEM-SIDE-ONLY service. It runs entirely on the GSI
// system partition and has ZERO vendor dependencies.
//
// Boot safety:
//   - NOT a HAL — no VINTF manifest entry
//   - Starts AFTER sys.boot_completed=1
//   - ServiceManager.getService("gsi_compat") returns null before start
//   - No vendor implementation required
//
// Version: 1
package android.gsi.compat;

import android.gsi.compat.CompatInfo;

interface IGsiCompat {

    // ── Read-only accessors ──────────────────────────────────

    /**
     * Returns whether survival mode is active for this boot.
     * Backed by: ro.gsi.compat.survival_mode
     */
    boolean isSurvivalModeActive();

    /**
     * Returns the vendor API level this GSI is designed to run on.
     * Backed by: ro.gsi.compat.vendor_level
     * @return vendor API level (e.g. 15 for Android 15 vendor)
     */
    int getVendorApiLevel();

    /**
     * Returns the system (GSI) SDK version.
     * Backed by: ro.build.version.sdk
     */
    int getSystemSdkVersion();

    /**
     * Returns the boot decision made by gsi_survival_check.sh.
     * One of: "normal", "upgrade", "downgrade", "first_boot", "unknown"
     * Backed by: sys.gsi.boot_decision
     */
    String getBootDecision();

    /**
     * Returns a snapshot of all compatibility info in a single call.
     * Preferred over individual getters when multiple fields are needed.
     */
    CompatInfo getCompatInfo();
}
