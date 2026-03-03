#!/usr/bin/env python3
"""
Compatibility Matrix Optimizer for Vendor15 Survival Architecture.

Reads a vendor VINTF manifest and an upstream AOSP Framework Compatibility Matrix,
then outputs an optimized compatibility_matrix.xml where:
  - All HALs are optional="true"
  - Version ranges are widened to include vendor-provided versions
  - Automotive/TV/VR-only HALs are removed
  - Output is valid VINTF XML

Usage:
    python3 optimize_matrix.py \
        --vendor-manifest /vendor/etc/vintf/manifest.xml \
        --upstream-matrix compatibility_matrix.current.xml \
        --output compatibility_matrix_vendor15_frozen.xml

    # Or auto-pull from connected device:
    python3 optimize_matrix.py \
        --from-device \
        --upstream-matrix compatibility_matrix.current.xml \
        --output compatibility_matrix_vendor15_frozen.xml
"""

import argparse
import copy
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# HALs that are only relevant for automotive/TV/VR and should be removed
REMOVE_HALS = {
    "android.hardware.automotive",
    "android.hardware.broadcastradio",
    "android.hardware.tv",
    "android.hardware.contexthub",
    "android.hardware.bluetooth.ranging",
    "android.hardware.bluetooth.socket",
    "android.hardware.bluetooth.finder",
    "android.hardware.bluetooth.lmp_event",
    "android.hardware.security.see",
    "android.hardware.virtualization.capabilities",
    "android.hardware.automotive.vehicle",
    "android.hardware.automotive.evs",
    "android.hardware.automotive.audiocontrol",
    "android.hardware.automotive.occupant_awareness",
    "android.hardware.automotive.remoteaccess",
    "android.hardware.automotive.ivn",
    "android.hardware.automotive.can",
    "android.hardware.automotive.sv",
}


@dataclass
class HalInfo:
    """Parsed HAL entry."""
    name: str
    format: str  # "aidl" or "hidl" or "native"
    versions: list = field(default_factory=list)
    interfaces: list = field(default_factory=list)
    optional: bool = False
    updatable_via_apex: bool = False
    transport: str = ""


def parse_version_range(version_str: str) -> tuple:
    """Parse version string like '3-4' or '3' into (min, max) tuple."""
    version_str = version_str.strip()
    if not version_str:
        return (0, 0)

    # Handle ranges like "3-4" or "1.0-5.0"
    if "-" in version_str:
        parts = version_str.split("-")
        lo = parts[0].strip()
        hi = parts[1].strip()
        # Strip minor version for comparison
        lo_major = int(lo.split(".")[0]) if lo else 0
        hi_major = int(hi.split(".")[0]) if hi else 0
        return (lo_major, hi_major)

    # Single version like "3" or "5.0"
    major = int(version_str.split(".")[0])
    return (major, major)


def format_version_range(lo: int, hi: int, use_minor: bool = False) -> str:
    """Format version range back to string."""
    if use_minor:
        if lo == hi:
            return f"{lo}.0"
        return f"{lo}.0-{hi}.0"
    if lo == hi:
        return str(lo)
    return f"{lo}-{hi}"


def parse_vendor_manifest(manifest_path: str) -> dict:
    """
    Parse vendor VINTF manifest XML.
    Returns dict: {hal_name: HalInfo}
    """
    hals = {}

    try:
        tree = ET.parse(manifest_path)
    except ET.ParseError as e:
        print(f"ERROR: Failed to parse vendor manifest: {e}", file=sys.stderr)
        return hals

    root = tree.getroot()

    for hal_elem in root.iter("hal"):
        name_elem = hal_elem.find("name")
        if name_elem is None or not name_elem.text:
            continue

        name = name_elem.text.strip()
        hal_format = hal_elem.get("format", "hidl")
        transport_elem = hal_elem.find("transport")
        transport = transport_elem.text.strip() if transport_elem is not None and transport_elem.text else ""

        versions = []
        for ver_elem in hal_elem.findall("version"):
            if ver_elem.text:
                versions.append(ver_elem.text.strip())

        # Also check for fqname which encodes version
        for fqname_elem in hal_elem.findall("fqname"):
            if fqname_elem.text:
                # Format: @1.0::IFoo/default
                match = re.match(r"@(\d+\.\d+)::", fqname_elem.text)
                if match:
                    versions.append(match.group(1))

        interfaces = []
        for iface_elem in hal_elem.findall("interface"):
            iface_name_elem = iface_elem.find("name")
            instances = []
            for inst_elem in iface_elem.findall("instance"):
                if inst_elem.text:
                    instances.append(inst_elem.text.strip())
            for inst_elem in iface_elem.findall("regex-instance"):
                if inst_elem.text:
                    instances.append(inst_elem.text.strip())
            if iface_name_elem is not None and iface_name_elem.text:
                interfaces.append({
                    "name": iface_name_elem.text.strip(),
                    "instances": instances,
                })

        info = HalInfo(
            name=name,
            format=hal_format,
            versions=versions,
            interfaces=interfaces,
            transport=transport,
        )

        # Merge if hal name already seen (e.g., multiple version entries)
        if name in hals:
            hals[name].versions.extend(versions)
            hals[name].interfaces.extend(interfaces)
        else:
            hals[name] = info

    return hals


def parse_upstream_matrix(matrix_path: str) -> ET.ElementTree:
    """Parse upstream AOSP framework compatibility matrix. Returns the full tree."""
    try:
        return ET.parse(matrix_path)
    except ET.ParseError as e:
        print(f"ERROR: Failed to parse upstream matrix: {e}", file=sys.stderr)
        sys.exit(1)


def get_vendor_max_version(vendor_hals: dict, hal_name: str) -> int:
    """Get the maximum version the vendor provides for a HAL."""
    if hal_name not in vendor_hals:
        return 0

    max_ver = 0
    for ver_str in vendor_hals[hal_name].versions:
        _, hi = parse_version_range(ver_str)
        if hi > max_ver:
            max_ver = hi
    return max_ver


def should_remove_hal(hal_name: str) -> bool:
    """Check if HAL should be removed entirely."""
    for prefix in REMOVE_HALS:
        if hal_name.startswith(prefix):
            return True
    return False


def optimize_matrix(
    vendor_hals: dict,
    upstream_tree: ET.ElementTree,
    target_fcm_level: str = "202404",
) -> ET.ElementTree:
    """
    Optimize the upstream matrix for Vendor15 survival.

    Rules:
    1. Set FCM level to target_fcm_level
    2. Remove automotive/TV/VR HALs
    3. Make all remaining HALs optional
    4. Widen version ranges to include vendor-provided versions
    5. Preserve interface/instance structure
    """
    tree = copy.deepcopy(upstream_tree)
    root = tree.getroot()

    # Set FCM level
    root.set("level", target_fcm_level)

    # Process each HAL
    hals_to_remove = []
    for hal_elem in root.findall("hal"):
        name_elem = hal_elem.find("name")
        if name_elem is None or not name_elem.text:
            continue

        hal_name = name_elem.text.strip()

        # Rule 2: Remove automotive/TV/VR HALs
        if should_remove_hal(hal_name):
            hals_to_remove.append(hal_elem)
            continue

        # Rule 3: Make all HALs optional
        hal_elem.set("optional", "true")

        # Rule 4: Widen version range
        hal_format = hal_elem.get("format", "hidl")
        use_minor = (hal_format == "native" or hal_format == "hidl")

        vendor_max = get_vendor_max_version(vendor_hals, hal_name)

        for ver_elem in hal_elem.findall("version"):
            if ver_elem.text:
                upstream_lo, upstream_hi = parse_version_range(ver_elem.text.strip())

                if vendor_max > 0 and vendor_max < upstream_lo:
                    # Vendor version is below upstream minimum — widen downward
                    new_lo = vendor_max
                    new_hi = upstream_hi
                    ver_elem.text = format_version_range(new_lo, new_hi, use_minor)
                elif vendor_max > upstream_hi:
                    # Vendor has newer than upstream expects — widen upward (unusual but safe)
                    ver_elem.text = format_version_range(upstream_lo, vendor_max, use_minor)
                # else: vendor within range or not present — keep as is

    # Remove marked HALs
    for hal_elem in hals_to_remove:
        root.remove(hal_elem)

    return tree


def pull_vendor_manifest_from_device() -> Optional[str]:
    """Pull vendor manifest from connected device via adb."""
    tmp_path = "/tmp/vendor_manifest_pulled.xml"

    # Try primary manifest location
    manifest_paths = [
        "/vendor/etc/vintf/manifest.xml",
        "/vendor/manifest.xml",
    ]

    for remote_path in manifest_paths:
        result = subprocess.run(
            ["adb", "pull", remote_path, tmp_path],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print(f"Pulled vendor manifest from {remote_path}")

            # Also try to pull fragment manifests and merge
            frag_dir = "/vendor/etc/vintf/manifest/"
            frag_result = subprocess.run(
                ["adb", "shell", f"ls {frag_dir} 2>/dev/null"],
                capture_output=True,
                text=True,
            )
            if frag_result.returncode == 0 and frag_result.stdout.strip():
                frags = frag_result.stdout.strip().split("\n")
                for frag in frags:
                    frag = frag.strip()
                    if frag.endswith(".xml"):
                        frag_tmp = f"/tmp/vendor_manifest_frag_{frag}"
                        subprocess.run(
                            ["adb", "pull", f"{frag_dir}{frag}", frag_tmp],
                            capture_output=True,
                        )
                        # Merge fragments into main manifest
                        merge_manifest_fragment(tmp_path, frag_tmp)

            return tmp_path

    print("ERROR: Could not pull vendor manifest from device.", file=sys.stderr)
    return None


def merge_manifest_fragment(main_path: str, frag_path: str):
    """Merge a manifest fragment into the main manifest."""
    try:
        main_tree = ET.parse(main_path)
        frag_tree = ET.parse(frag_path)
    except ET.ParseError:
        return

    main_root = main_tree.getroot()
    frag_root = frag_tree.getroot()

    for hal_elem in frag_root.findall("hal"):
        main_root.append(hal_elem)

    main_tree.write(main_path, encoding="unicode", xml_declaration=True)


def write_output(tree: ET.ElementTree, output_path: str):
    """Write optimized matrix with proper formatting."""
    root = tree.getroot()

    # Add comment header
    output_lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!-- ============================================================ -->",
        "<!-- AUTO-GENERATED by optimize_matrix.py                         -->",
        "<!-- Vendor15 Frozen Framework Compatibility Matrix                -->",
        "<!--                                                              -->",
        "<!-- DO NOT EDIT MANUALLY — re-run optimize_matrix.py instead     -->",
        "<!-- ============================================================ -->",
        "",
    ]

    # Serialize the tree
    xml_str = ET.tostring(root, encoding="unicode")

    # Basic pretty-print (ET.indent requires Python 3.9+)
    try:
        ET.indent(root, space="    ")
        xml_str = ET.tostring(root, encoding="unicode")
    except AttributeError:
        # Python < 3.9 fallback
        pass

    output_lines.append(xml_str)

    with open(output_path, "w") as f:
        f.write("\n".join(output_lines))
        f.write("\n")

    print(f"Optimized matrix written to: {output_path}")


def print_diff_summary(vendor_hals: dict, upstream_tree: ET.ElementTree, optimized_tree: ET.ElementTree):
    """Print a human-readable summary of changes made."""
    upstream_root = upstream_tree.getroot()
    optimized_root = optimized_tree.getroot()

    upstream_hal_names = set()
    for hal_elem in upstream_root.findall("hal"):
        name_elem = hal_elem.find("name")
        if name_elem is not None and name_elem.text:
            upstream_hal_names.add(name_elem.text.strip())

    optimized_hal_names = set()
    for hal_elem in optimized_root.findall("hal"):
        name_elem = hal_elem.find("name")
        if name_elem is not None and name_elem.text:
            optimized_hal_names.add(name_elem.text.strip())

    removed = upstream_hal_names - optimized_hal_names
    kept = optimized_hal_names

    print("\n=== Matrix Optimization Summary ===")
    print(f"  Upstream HALs:  {len(upstream_hal_names)}")
    print(f"  Optimized HALs: {len(optimized_hal_names)}")
    print(f"  Removed:        {len(removed)}")
    print(f"  FCM level:      {optimized_root.get('level', 'unknown')}")

    if removed:
        print("\n  Removed HALs:")
        for name in sorted(removed):
            print(f"    - {name}")

    # Show version changes
    print("\n  Version adjustments:")
    for hal_elem in optimized_root.findall("hal"):
        name_elem = hal_elem.find("name")
        if name_elem is None or not name_elem.text:
            continue
        hal_name = name_elem.text.strip()
        vendor_max = get_vendor_max_version(vendor_hals, hal_name)

        for ver_elem in hal_elem.findall("version"):
            if ver_elem.text:
                print(f"    {hal_name}: {ver_elem.text.strip()}"
                      f" (vendor provides: v{vendor_max if vendor_max > 0 else '?'})")

    print("")


def main():
    parser = argparse.ArgumentParser(
        description="Optimize AOSP Framework Compatibility Matrix for Vendor15 survival."
    )
    parser.add_argument(
        "--vendor-manifest",
        help="Path to vendor VINTF manifest XML",
    )
    parser.add_argument(
        "--from-device",
        action="store_true",
        help="Pull vendor manifest from connected device via adb",
    )
    parser.add_argument(
        "--upstream-matrix",
        required=True,
        help="Path to upstream AOSP framework compatibility_matrix.current.xml",
    )
    parser.add_argument(
        "--output",
        default="compatibility_matrix_vendor15_frozen.xml",
        help="Output path for optimized matrix (default: compatibility_matrix_vendor15_frozen.xml)",
    )
    parser.add_argument(
        "--fcm-level",
        default="202404",
        help="Target FCM level (default: 202404 for Vendor15)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print detailed diff summary",
    )

    args = parser.parse_args()

    # Get vendor manifest
    vendor_manifest_path = args.vendor_manifest
    if args.from_device:
        vendor_manifest_path = pull_vendor_manifest_from_device()
        if vendor_manifest_path is None:
            sys.exit(1)
    elif not vendor_manifest_path:
        print("ERROR: Must specify --vendor-manifest or --from-device", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(vendor_manifest_path):
        print(f"ERROR: Vendor manifest not found: {vendor_manifest_path}", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(args.upstream_matrix):
        print(f"ERROR: Upstream matrix not found: {args.upstream_matrix}", file=sys.stderr)
        sys.exit(1)

    # Parse inputs
    print(f"Parsing vendor manifest: {vendor_manifest_path}")
    vendor_hals = parse_vendor_manifest(vendor_manifest_path)
    print(f"  Found {len(vendor_hals)} HALs in vendor manifest")

    print(f"Parsing upstream matrix: {args.upstream_matrix}")
    upstream_tree = parse_upstream_matrix(args.upstream_matrix)

    # Optimize
    print(f"Optimizing matrix (FCM level: {args.fcm_level})...")
    optimized_tree = optimize_matrix(vendor_hals, upstream_tree, args.fcm_level)

    # Write output
    write_output(optimized_tree, args.output)

    # Print summary
    if args.verbose:
        print_diff_summary(vendor_hals, upstream_tree, optimized_tree)

    print("Done.")


if __name__ == "__main__":
    main()
