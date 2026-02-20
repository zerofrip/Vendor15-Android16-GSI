#!/usr/bin/env python3
import os
import sys
import json
import argparse
import subprocess
from typing import Dict, List, Set

class VndkPolicy:
    def __init__(self, data: Dict):
        self.api_level = data.get('api_level')
        self.rules = data.get('rules', [])
        self.linker_patch = data.get('linker_config', {})

    def get_rules_for_lib(self, lib_name: str) -> List[Dict]:
        return [r for r in self.rules if r.get('target') == lib_name]

def run_readelf(file_path: str, args: List[str]) -> str:
    try:
        return subprocess.check_output(['readelf'] + args + [file_path], stderr=subprocess.DEVNULL).decode()
    except Exception:
        return ""

def get_elf_symbols(file_path: str, defined: bool = True) -> Set[str]:
    """Extracts defined or undefined symbols from an ELF file."""
    symbols = set()
    output = run_readelf(file_path, ['-W', '-s'])
    for line in output.splitlines():
        # Simple parser for readelf -s output
        parts = line.split()
        if len(parts) < 8:
            continue
        
        bind = parts[4]
        ndx = parts[6]
        name = parts[7]
        
        if defined:
            if bind in ['GLOBAL', 'WEAK'] and ndx != 'UND':
                symbols.add(name)
        else:
            if ndx == 'UND':
                symbols.add(name)
    return symbols

class VndkCompatEngine:
    def __init__(self, vendor_api: int, system_api: int, policy_dir: str):
        self.vendor_api = vendor_api
        self.system_api = system_api
        self.policy = self._load_policy(policy_dir)
        self.plan = {
            "version": "1.0",
            "vendor_api_level": vendor_api,
            "system_api_level": system_api,
            "actions": []
        }

    def _load_policy(self, policy_dir: str) -> VndkPolicy:
        path = os.path.join(policy_dir, f"v{self.vendor_api}.policy.json")
        if not os.path.exists(path):
            print(f"Warning: No policy found for API level {self.vendor_api} at {path}")
            return VndkPolicy({})
        with open(path, 'r') as f:
            return VndkPolicy(json.load(f))

    def analyze(self, vendor_path: str, system_path: str):
        """Analyzes dependencies and matches against policy."""
        # 1. Build System Symbol Map
        system_provided = set()
        for root, _, files in os.walk(system_path):
            for f in files:
                if f.endswith('.so'):
                    system_provided.update(get_elf_symbols(os.path.join(root, f), defined=True))

        # 2. Analyze Vendor Libraries
        for root, _, files in os.walk(vendor_path):
            for f in files:
                if f.endswith('.so'):
                    vendor_lib = os.path.join(root, f)
                    lib_name = os.path.basename(f)
                    undefined = get_elf_symbols(vendor_lib, defined=False)
                    
                    unresolved = undefined - system_provided
                    if unresolved:
                        self._process_unresolved(lib_name, unresolved)

    def _process_unresolved(self, lib_name: str, symbols: Set[str]):
        """Matches unresolved symbols against policy rules."""
        rules = self.policy.get_rules_for_lib(lib_name)
        
        for sym in symbols:
            matched = False
            for rule in rules:
                if sym in rule.get('symbols', []):
                    self.plan['actions'].append({
                        "type": rule['action'],
                        "target_lib": lib_name,
                        "symbol": sym,
                        "remap": rule.get('remap', {}).get(sym)
                    })
                    matched = True
                    break
            
            if not matched:
                print(f"Build Warning: Unresolved symbol '{sym}' in '{lib_name}' not covered by policy.")

    def save_plan(self, output_path: str):
        with open(output_path, 'w') as f:
            json.dump(self.plan, f, indent=2)

def main():
    parser = argparse.ArgumentParser(description='VNDK Compatibility Engine')
    parser.add_argument('--vendor-api', type=int, required=True)
    parser.add_argument('--system-api', type=int, required=True)
    parser.add_argument('--vendor-dir', required=True)
    parser.add_argument('--system-dir', required=True)
    parser.add_argument('--policy-dir', required=True)
    parser.add_argument('--output', required=True)

    args = parser.parse_args()

    engine = VndkCompatEngine(args.vendor_api, args.system_api, args.policy_dir)
    engine.analyze(args.vendor_dir, args.system_dir)
    engine.save_plan(args.output)

if __name__ == '__main__':
    main()
