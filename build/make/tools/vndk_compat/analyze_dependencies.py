#!/usr/bin/env python3
import os
import sys
import argparse
import xml.etree.ElementTree as ET
import subprocess
import json

def parse_vintf_manifest(manifest_path):
    """Parses vendor manifest.xml to find HAL dependencies."""
    hal_deps = []
    if not os.path.exists(manifest_path):
        return hal_deps
    
    tree = ET.parse(manifest_path)
    root = tree.getroot()
    for hal in root.findall('hal'):
        name = hal.find('name').text
        versions = [v.text for v in hal.findall('version')]
        hal_deps.append({'name': name, 'versions': versions})
    return hal_deps

def get_elf_dependencies(file_path):
    """Uses readelf to find DT_NEEDED entries and undefined symbols."""
    deps = []
    try:
        output = subprocess.check_output(['readelf', '-d', file_path], stderr=subprocess.STDOUT).decode()
        for line in output.splitlines():
            if 'NEEDED' in line:
                lib = line.split('[')[1].split(']')[0]
                deps.append(lib)
    except Exception:
        pass
    return deps

def analyze_vendor_partition(vendor_path, system_libs):
    """Scans vendor partition for library dependencies."""
    missing_deps = {}
    for root, dirs, files in os.walk(vendor_path):
        for f in files:
            if f.endswith('.so'):
                full_path = os.path.join(root, f)
                deps = get_elf_dependencies(full_path)
                for dep in deps:
                    if dep not in system_libs:
                        if dep not in missing_deps:
                            missing_deps[dep] = []
                        missing_deps[dep].append(full_path)
    return missing_deps

def main():
    parser = argparse.ArgumentParser(description='Analyze vendor dependencies for VNDK compatibility.')
    parser.add_argument('--vendor', required=True, help='Path to vendor partition')
    parser.add_argument('--manifest', help='Path to vendor manifest.xml')
    parser.add_argument('--system-libs', required=True, help='File containing list of system libraries')
    parser.add_argument('--output', required=True, help='Output JSON file')
    
    args = parser.parse_args()
    
    with open(args.system_libs, 'r') as f:
        system_libs = set(line.strip() for line in f)
    
    hal_deps = parse_vintf_manifest(args.manifest) if args.manifest else []
    missing_deps = analyze_vendor_partition(args.vendor, system_libs)
    
    result = {
        'hal_dependencies': hal_deps,
        'missing_libraries': missing_deps,
    }
    
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

if __name__ == '__main__':
    main()
