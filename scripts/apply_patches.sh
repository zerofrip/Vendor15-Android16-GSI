#!/bin/bash
# apply_patches.sh
# Applies patches from the patches directory to the AOSP source tree.

ROOT_DIR=$1
PATCHES_DIR=$2

if [ -z "$ROOT_DIR" ] || [ -z "$PATCHES_DIR" ]; then
    echo "Usage: apply_patches.sh <AOSP_ROOT> <PATCHES_DIR>"
    exit 1
fi

echo "Applying patches from $PATCHES_DIR to $ROOT_DIR"

# Navigate to AOSP root
cd "$ROOT_DIR"

# Find all patch directories
# We expect the structure inside PATCHES_DIR to mirror the AOSP source tree
# e.g. PATCHES_DIR/frameworks/base/*.patch -> AOSP_ROOT/frameworks/base/

find "$PATCHES_DIR" -type f -name "*.patch" | while read patch_file; do
    # Get the relative path of the patch file from PATCHES_DIR
    rel_path="${patch_file#$PATCHES_DIR/}"
    # Get the directory of the patch file (e.g., frameworks/base)
    project_path=$(dirname "$rel_path")
    
    echo "Processing patch: $rel_path for project: $project_path"
    
    if [ -d "$project_path" ]; then
        echo "Applying $patch_file to $project_path..."
        # Navigate to the project directory
        pushd "$project_path" > /dev/null
        
        # Apply patch
        # Try git apply first, checking for errors
        if git apply --check "$patch_file"; then
             git apply "$patch_file"
             echo "Success: Applied $patch_file"
        else
             echo "Warning: git apply check failed for $patch_file. Trying patch command..."
             if patch -p1 < "$patch_file"; then
                 echo "Success: Applied $patch_file with patch command"
             else
                 echo "Error: Failed to apply $patch_file"
             fi
        fi
        
        popd > /dev/null
    else
        echo "Warning: Directory $project_path does not exist in AOSP tree. Skipping patch."
    fi
done
