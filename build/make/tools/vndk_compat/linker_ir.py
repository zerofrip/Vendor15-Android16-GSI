#!/usr/bin/env python3
import json
import argparse
from typing import Dict, List, Set, Any

class NamespaceNode:
    def __init__(self, name: str):
        self.name = name
        self.isolated = True
        self.visible = True
        self.links = [] # List of Dict { "target": str, "allow_all": bool }
        self.permitted_paths = set()
        self.search_paths = set()

    def to_json(self) -> Dict:
        return {
            "name": self.name,
            "isolated": self.isolated,
            "visible": self.visible,
            "links": self.links,
            "permitted_paths": sorted(list(self.permitted_paths)),
            "search_paths": sorted(list(self.search_paths))
        }

class LinkerNamespaceIR:
    def __init__(self):
        self.nodes = {}

    def get_or_create(self, name: str) -> NamespaceNode:
        if name not in self.nodes:
            self.nodes[name] = NamespaceNode(name)
        return self.nodes[name]

    def add_link(self, source: str, target: str, allow_all: bool = True):
        src_node = self.get_or_create(source)
        if not any(l['target'] == target for l in src_node.links):
            src_node.links.append({"target": target, "allow_all_shared_libs": allow_all})

    def export_json(self) -> Dict:
        return {
            "namespaces": [n.to_json() for n in self.nodes.values()]
        }

def main():
    parser = argparse.ArgumentParser(description='Linker Namespace IR Tool')
    parser.add_argument('--input-config', help='Optional base linker.config.json')
    parser.add_argument('--plan', required=True, help='Compat plan JSON')
    parser.add_argument('--output', required=True)

    args = parser.parse_args()

    ir = LinkerNamespaceIR()
    
    # Load base config if exists
    if args.input_config and os.path.exists(args.input_config):
        with open(args.input_config, 'r') as f:
            base = json.load(f)
            for ns in base.get('namespaces', []):
                node = ir.get_or_create(ns['name'])
                node.isolated = ns.get('isolated', True)
                node.visible = ns.get('visible', True)
                node.links = ns.get('links', [])
                node.permitted_paths.update(ns.get('permitted_paths', []))

    # Apply plan-based adjustments
    with open(args.plan, 'r') as f:
        plan = json.load(f)
    
    v_api = plan.get('vendor_api_level', 15)
    compat_ns = f"vndk_compat_v{v_api}"
    
    # Ensure vndk_compat namespace exists
    node = ir.get_or_create(compat_ns)
    node.permitted_paths.add(f"/system/lib64/vndk-v{v_api}")
    ir.add_link(compat_ns, "default")
    
    # Link default to compat if needed by plan
    ir.add_link("default", compat_ns)

    with open(args.output, 'w') as f:
        json.dump(ir.export_json(), f, indent=2)

import os
if __name__ == '__main__':
    main()
