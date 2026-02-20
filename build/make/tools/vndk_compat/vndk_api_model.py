#!/usr/bin/env python3
import os
import sys
import json
import argparse
import subprocess
from typing import Dict, List, Set

def run_readelf(file_path: str, args: List[str]) -> str:
    try:
        return subprocess.check_output(['readelf'] + args + [file_path], stderr=subprocess.DEVNULL).decode()
    except Exception:
        return ""

def extract_symbols(file_path: str) -> List[Dict]:
    symbols = []
    output = run_readelf(file_path, ['-W', '-s'])
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 8:
            continue
        
        bind = parts[4]
        ndx = parts[6]
        name = parts[7]
        
        # We focus on global/weak defined symbols for the model
        if bind in ['GLOBAL', 'WEAK'] and ndx != 'UND':
            symbols.append({
                "name": name,
                "visibility": "public" if bind == "GLOBAL" else "weak",
            })
    return symbols

def generate_model(api_level: int, scan_dir: str) -> Dict:
    model = {
        "api_level": api_level,
        "libraries": []
    }
    
    for root, _, files in os.walk(scan_dir):
        for f in files:
            if f.endswith('.so'):
                full_path = os.path.join(root, f)
                lib_name = os.path.basename(f)
                
                # Basic metadata
                lib_info = {
                    "name": lib_name,
                    "stability": "stable" if "vndk" in root else "unstable",
                    "owner": "platform", # Default, can be refined with APEX info
                    "symbols": extract_symbols(full_path)
                }
                model["libraries"].append(lib_info)
                
    return model

def main():
    parser = argparse.ArgumentParser(description='VNDK API Model Generator')
    parser.add_argument('--api-level', type=int, required=True)
    parser.add_argument('--scan-dir', required=True)
    parser.add_argument('--output', required=True)
    
    args = parser.parse_args()
    
    model = generate_model(args.api_level, args.scan_dir)
    
    with open(args.output, 'w') as f:
        json.dump(model, f, indent=2)

if __name__ == '__main__':
    main()
