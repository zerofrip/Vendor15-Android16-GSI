#!/usr/bin/env python3
import json
import argparse
import sys
import os
from typing import Dict, List, Set

class VndkDiffEngine:
    def __init__(self, system_model: Dict, vendor_footprint: Dict, policy: Dict):
        self.system_model = system_model
        self.vendor_footprint = vendor_footprint
        self.policy = policy
        self.plan = {
            "actions": [],
            "metrics": {
                "matches": 0,
                "missing": 0,
                "abi_breaks": 0,
                "visibility_violations": 0
            }
        }

    def _get_system_symbols(self) -> Dict[str, Set[str]]:
        res = {}
        for lib in self.system_model.get('libraries', []):
            res[lib['name']] = set(s['name'] for s in lib.get('symbols', []))
        return res

    def compute_diff(self):
        sys_libs = self._get_system_symbols()
        vendor_needs = self.vendor_footprint.get('libraries', [])

        for v_lib in vendor_needs:
            lib_name = v_lib['name']
            v_symbols = set(s['name'] for s in v_lib.get('symbols', []))
            
            if lib_name not in sys_libs:
                self.plan['metrics']['missing'] += 1
                self.plan['actions'].append({
                    "type": "MISSING_LIBRARY",
                    "target": lib_name,
                    "severity": "CRITICAL"
                })
                continue

            s_symbols = sys_libs[lib_name]
            missing_syms = v_symbols - s_symbols
            
            if not missing_syms:
                self.plan['metrics']['matches'] += 1
            else:
                self.plan['metrics']['abi_breaks'] += len(missing_syms)
                for sym in missing_syms:
                    action = self._resolve_via_policy(lib_name, sym)
                    self.plan['actions'].append({
                        "type": "ABI_BREAK",
                        "target": lib_name,
                        "symbol": sym,
                        "resolution": action
                    })

    def _resolve_via_policy(self, lib_name: str, symbol: str) -> Dict:
        # Check policy for shim/stub rules
        for rule in self.policy.get('rules', []):
            if rule.get('target') == lib_name and symbol in rule.get('symbols', []):
                return {
                    "action": rule['action'],
                    "remap": rule.get('remap', {}).get(symbol)
                }
        return {"action": "NONE", "fallback": "snapshot"}

    def save_plan(self, output_path: str):
        with open(output_path, 'w') as f:
            json.dump(self.plan, f, indent=2)

def main():
    parser = argparse.ArgumentParser(description='Advanced VNDK Diff Engine')
    parser.add_argument('--system-model', required=True)
    parser.add_argument('--vendor-footprint', required=True)
    parser.add_argument('--policy', required=True)
    parser.add_argument('--output', required=True)

    args = parser.parse_args()

    with open(args.system_model, 'r') as f: sys_model = json.load(f)
    with open(args.vendor_footprint, 'r') as f: v_footprint = json.load(f)
    with open(args.policy, 'r') as f: policy = json.load(f)

    engine = VndkDiffEngine(sys_model, v_footprint, policy)
    engine.compute_diff()
    engine.save_plan(args.output)

if __name__ == '__main__':
    main()
