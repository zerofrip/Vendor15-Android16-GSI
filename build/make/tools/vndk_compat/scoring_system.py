#!/usr/bin/env python3
import json
import argparse
import sys

# Penalty weights as defined in the design spec
PENALTIES = {
    "FORWARDING_SHIM": 1,
    "SYMBOL_REMAP": 2,
    "STUB_GENERATED": 5,
    "SNAPSHOT_DEPENDENCY": 5,
    "CRITICAL_HAL_MISSING": 25,
    "LINKER_ISOLATION_BREACH": 10,
    "MISSING_LIBRARY": 15
}

def calculate_score(plan: Dict) -> int:
    score = 100
    actions = plan.get('actions', [])
    
    for action in actions:
        p_type = action.get('type')
        res = action.get('resolution', {})
        action_val = res.get('action') if isinstance(res, dict) else None

        if p_type == "MISSING_LIBRARY":
            score -= PENALTIES["MISSING_LIBRARY"]
        elif p_type == "ABI_BREAK":
            if action_val == "shim":
                if res.get('remap'):
                    score -= PENALTIES["SYMBOL_REMAP"]
                else:
                    score -= PENALTIES["FORWARDING_SHIM"]
            elif action_val == "stub":
                score -= PENALTIES["STUB_GENERATED"]
            else:
                score -= PENALTIES["SNAPSHOT_DEPENDENCY"]
                
    return max(0, score)

def get_state(score: int) -> str:
    if score >= 100: return "FULL"
    if score >= 70: return "DEGRADED"
    return "UNSUPPORTED"

def main():
    parser = argparse.ArgumentParser(description='VNDK Compatibility Scorer')
    parser.add_argument('--plan', required=True)
    parser.add_argument('--output-props', required=True)

    args = parser.parse_args()

    with open(args.plan, 'r') as f:
        plan = json.load(f)

    score = calculate_score(plan)
    state = get_state(score)

    with open(args.output_props, 'w') as f:
        f.write(f"ro.vndk.compat_score={score}\n")
        f.write(f"ro.vndk.compat_state={state}\n")

if __name__ == '__main__':
    main()
from typing import Dict
