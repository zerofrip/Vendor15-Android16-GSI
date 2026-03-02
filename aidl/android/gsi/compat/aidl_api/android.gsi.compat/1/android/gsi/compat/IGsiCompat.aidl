///////////////////////////////////////////////////////////////////////////////
// Frozen AIDL API snapshot — android.gsi.compat v1
//
// DO NOT MODIFY. This file is the canonical record of the v1 API surface.
// Any changes to the interface require incrementing the version number
// and adding a new frozen snapshot directory.
///////////////////////////////////////////////////////////////////////////////

// IGsiCompat.aidl
package android.gsi.compat;
import android.gsi.compat.CompatInfo;
interface IGsiCompat {
    boolean isSurvivalModeActive();
    int getVendorApiLevel();
    int getSystemSdkVersion();
    String getBootDecision();
    CompatInfo getCompatInfo();
}

// CompatInfo.aidl
package android.gsi.compat;
parcelable CompatInfo {
    boolean survivalModeActive;
    int vendorApiLevel;
    int systemSdkVersion;
    int previousSdkVersion;
    String bootDecision;
    boolean isUpgradeBoot;
    boolean vintfEnforced;
}
