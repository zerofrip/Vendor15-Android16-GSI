// CompatInfo.aidl
// Parcelable snapshot of all GSI compatibility state.
// Returned by IGsiCompat.getCompatInfo() for efficient batch reads.
package android.gsi.compat;

parcelable CompatInfo {
    /** Whether survival mode is active (ro.gsi.compat.survival_mode) */
    boolean survivalModeActive;

    /** Vendor API level (ro.gsi.compat.vendor_level), e.g. 15 */
    int vendorApiLevel;

    /** System SDK version (ro.build.version.sdk), e.g. 36 */
    int systemSdkVersion;

    /** Previous SDK high-water mark (persist.sys.prev_sdk), 0 if first boot */
    int previousSdkVersion;

    /** Boot decision: "normal", "upgrade", "downgrade", "first_boot", "unknown" */
    String bootDecision;

    /** Whether this is an upgrade boot (persist.sys.gsi_upgrade) */
    boolean isUpgradeBoot;

    /** VINTF enforcement state (ro.vintf.enforce) */
    boolean vintfEnforced;
}
