#!/usr/bin/env python3
import json
import argparse
import sys
from typing import Dict, List, Any

class LinkerConfigAST:
    def __init__(self, data: Dict):
        self.data = data

    def find_namespace(self, name: str) -> Dict:
        for ns in self.data.get('namespaces', []):
            if ns.get('name') == name:
                return ns
        return None

    def add_namespace(self, ns_data: Dict):
        if not self.find_namespace(ns_data['name']):
            if 'namespaces' not in self.data:
                self.data['namespaces'] = []
            self.data['namespaces'].append(ns_data)

    def patch_namespace(self, name: str, patch_data: Dict):
        ns = self.find_namespace(name)
        if not ns:
            print(f"Warning: Namespace '{name}' not found for patching. Creating it.")
            ns = {"name": name}
            self.add_namespace(ns)
        
        # Apply structured patches
        if 'links' in patch_data:
            if 'links' not in ns:
                ns['links'] = []
            
            for action_obj in patch_data['links']:
                if 'add' in action_obj:
                    new_link = action_obj['add']
                    # Avoid duplicates
                    if not any(l.get('target') == new_link['target'] for l in ns['links']):
                        ns['links'].append(new_link)

    def save(self, path: str):
        with open(path, 'w') as f:
            json.dump(self.data, f, indent=2)

def main():
    parser = argparse.ArgumentParser(description='AST-based linker.config.json patcher')
    parser.add_argument('--input', required=True)
    parser.add_argument('--policy', required=True)
    parser.add_argument('--output', required=True)

    args = parser.parse_args()

    with open(args.input, 'r') as f:
        ast = LinkerConfigAST(json.load(f))

    with open(args.policy, 'r') as f:
        policy_data = json.load(f)
        patch_info = policy_data.get('linker_config', {})

    for ns_patch in patch_info.get('namespaces', []):
        ns_name = ns_patch['name']
        if 'patch' in ns_patch:
            ast.patch_namespace(ns_name, ns_patch['patch'])
        elif 'add' in ns_patch:
            ast.add_namespace(ns_patch['add'])

    ast.save(args.output)

if __name__ == '__main__':
    main()
