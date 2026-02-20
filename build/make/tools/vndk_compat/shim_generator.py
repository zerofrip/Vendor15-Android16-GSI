#!/usr/bin/env python3
import os
import sys
import argparse
import json

SHIM_TEMPLATE = """
#include <dlfcn.h>
#include <log/log.h>
#include <string>

// Global handle for the real library
static void* get_real_lib_handle(const char* lib_name) {{
    static void* handle = nullptr;
    if (!handle) {{
        handle = dlopen(lib_name, RTLD_NOW);
    }}
    return handle;
}}

extern "C" {{

{symbol_definitions}

}}
"""

FORWARD_TEMPLATE = """
void* {name}(...) {{
    typedef void* (*func_ptr)(...);
    static func_ptr real_func = nullptr;
    if (!real_func) {{
        void* handle = get_real_lib_handle("{target_lib_path}");
        if (handle) {{
            real_func = (func_ptr)dlsym(handle, "{name}");
        }}
    }}
    if (real_func) return real_func();
    ALOGE("vndk_compat: {name} not found");
    return nullptr;
}}
"""

REMAP_TEMPLATE = """
extern void* {new_name}(...);
void* {old_name}(...) {{
    return {new_name}();
}}
"""

STUB_TEMPLATE = """
void* {name}(...) {{
    ALOGW("vndk_compat: stub called for {name}");
    return nullptr;
}}
"""

def generate_shim(plan_path, output_path):
    with open(plan_path, 'r') as f:
        plan = json.load(f)

    symbol_definitions = []
    actions = plan.get('actions', [])
    
    # Group actions by target lib to use correct dlopen target if needed
    for action in actions:
        action_type = action['type']
        name = action['symbol']
        target_lib = action['target_lib'] + ".so"

        if action_type == "shim":
            if action.get('remap'):
                symbol_definitions.append(REMAP_TEMPLATE.format(
                    old_name=name,
                    new_name=action['remap']
                ))
            else:
                symbol_definitions.append(FORWARD_TEMPLATE.format(
                    name=name,
                    target_lib_path=target_lib
                ))
        elif action_type == "stub":
            symbol_definitions.append(STUB_TEMPLATE.format(name=name))

    content = SHIM_TEMPLATE.format(
        target_lib="compat_layer",
        version=plan.get('vendor_api_level', 'unknown'),
        symbol_definitions="\n".join(symbol_definitions)
    )
    
    with open(output_path, 'w') as f:
        f.write(content)

def main():
    parser = argparse.ArgumentParser(description='Version-Agnostic Shim Generator')
    parser.add_argument('--plan', required=True, help='Path to compat_plan.json')
    parser.add_argument('--output', required=True, help='Output C++ file path')
    
    args = parser.parse_args()
    generate_shim(args.plan, args.output)

if __name__ == '__main__':
    main()
