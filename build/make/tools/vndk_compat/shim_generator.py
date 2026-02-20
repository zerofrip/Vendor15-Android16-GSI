#!/usr/bin/env python3
import os
import sys
import argparse

SHIM_TEMPLATE = """
#include <dlfcn.h>
#include <log/log.h>
#include <string>

// Shim for {target_lib}
// Version: {version}

extern "C" {{

{symbol_definitions}

}}
"""

SYMBOL_TEMPLATE = """
typedef void* (*{func_name}_ptr)({arg_types});

void* {func_name}({args}) {{
    static {func_name}_ptr real_func = nullptr;
    if (!real_func) {{
        void* handle = dlopen("{target_lib_path}", RTLD_NOW);
        if (handle) {{
            real_func = ({func_name}_ptr)dlsym(handle, "{func_name}");
        }}
    }}

    if (real_func) {{
        return real_func({arg_names});
    }}

    ALOGE("vndk_compat: failed to find {func_name} in {target_lib_path}");
    return nullptr;
}}
"""

def generate_shim(target_lib, symbols, output_path, version="35"):
    """Generates a C++ shim for a library."""
    symbol_defs = []
    for sym in symbols:
        # Note: In a real implementation, we would use a tool like 'header-abi-diff'
        # or parse headers to get exact signatures. For this reference, we use
        # generic pointers or simplified signatures.
        symbol_defs.append(SYMBOL_TEMPLATE.format(
            func_name=sym,
            arg_types="...",
            args="...",
            arg_names="...", # This is a placeholder; real ABI forwarding is more complex
            target_lib_path=target_lib + ".so"
        ))
    
    content = SHIM_TEMPLATE.format(
        target_lib=target_lib,
        version=version,
        symbol_definitions="\n".join(symbol_defs)
    )
    
    with open(output_path, 'w') as f:
        f.write(content)

def main():
    parser = argparse.ArgumentParser(description='Generate C++ shims for VNDK compatibility.')
    parser.add_argument('--lib', required=True, help='Target library name (e.g., libvndksupport)')
    parser.add_argument('--symbols', required=True, help='Comma-separated list of symbols')
    parser.add_argument('--output', required=True, help='Output C++ file path')
    parser.add_argument('--version', default='35', help='VNDK version')
    
    args = parser.parse_args()
    symbols = args.symbols.split(',')
    
    generate_shim(args.lib, symbols, args.output, args.version)

if __name__ == '__main__':
    main()
