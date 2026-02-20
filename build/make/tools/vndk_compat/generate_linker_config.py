#!/usr/bin/env python3
import json
import argparse
import os

def generate_linker_config(compat_versions, output_path):
    """Generates the linker.config.json for VNDK compatibility."""
    config = {
        "namespaces": []
    }
    
    for version in compat_versions:
        namespace_name = f"vndk_compat_v{version}"
        ns = {
            "name": namespace_name,
            "isolated": True,
            "visible": True,
            "links": [
                {
                    "target": "default",
                    "allow_all_shared_libs": True
                }
            ],
            "permitted_paths": [
                f"/system/lib64/vndk-v{version}",
                f"/system/lib/vndk-v{version}"
            ]
        }
        config["namespaces"].append(ns)
    
    with open(output_path, 'w') as f:
        json.dump(config, f, indent=2)

def main():
    parser = argparse.ArgumentParser(description='Generate linker.config.json patches for VNDK compatibility.')
    parser.add_argument('--versions', required=True, help='Comma-separated VNDK versions (e.g., 35)')
    parser.add_argument('--output', required=True, help='Output path for linker.config.json')
    
    args = parser.parse_args()
    versions = args.versions.split(',')
    
    generate_linker_config(versions, args.output)

if __name__ == '__main__':
    main()
