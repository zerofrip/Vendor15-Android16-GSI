#!/bin/bash
set -euo pipefail
# ============================================================
# parse_avc_denials.sh
# Vendor15 GSI — AVC Denial Log Parser & Rule Suggester
# ============================================================
#
# Parses avc: denied messages from a connected device's logcat
# or dmesg output, deduplicates them, and generates suggested
# SELinux allow rules.
#
# Usage:
#   bash scripts/parse_avc_denials.sh              # from live device
#   bash scripts/parse_avc_denials.sh <logfile>    # from saved log
#
# Output:
#   Suggested allow rules printed to stdout.
#   Does NOT apply any changes.
#
# Safety:
#   - Read-only: only reads logs, never modifies policy
#   - Suggestions must be manually reviewed before applying
# ============================================================

ADB="${ADB:-adb}"
LOG_SOURCE="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== AVC Denial Parser & Rule Suggester ===${NC}"
echo ""

# ============================================================
# 1. Collect AVC denials
# ============================================================
TMPFILE=$(mktemp /tmp/avc_denials.XXXXXX)
trap "rm -f $TMPFILE" EXIT

if [ -n "$LOG_SOURCE" ] && [ -f "$LOG_SOURCE" ]; then
    echo "Reading from file: $LOG_SOURCE"
    grep "avc: *denied" "$LOG_SOURCE" > "$TMPFILE" 2>/dev/null || true
else
    echo "Collecting from connected device..."
    if ! $ADB devices 2>/dev/null | grep -q "device$"; then
        echo -e "${RED}Error: No device connected via ADB.${NC}"
        echo "  Connect a device, or provide a log file:"
        echo "  bash $0 <logfile>"
        exit 2
    fi

    # Collect from both logcat and dmesg for completeness
    echo "  Pulling logcat..."
    $ADB shell "logcat -d" 2>/dev/null | grep "avc: *denied" >> "$TMPFILE" 2>/dev/null || true

    echo "  Pulling dmesg..."
    $ADB shell "dmesg" 2>/dev/null | grep "avc: *denied" >> "$TMPFILE" 2>/dev/null || true

    echo "  Pulling audit log..."
    $ADB shell "cat /proc/kmsg" 2>/dev/null | timeout 3 grep "avc: *denied" >> "$TMPFILE" 2>/dev/null || true
fi

TOTAL_DENIALS=$(wc -l < "$TMPFILE" 2>/dev/null || echo "0")
echo ""
echo "Found $TOTAL_DENIALS AVC denial(s)."

if [ "$TOTAL_DENIALS" -eq 0 ]; then
    echo -e "${GREEN}No AVC denials found. SELinux policy appears sufficient.${NC}"
    exit 0
fi

# ============================================================
# 2. Parse and deduplicate
# ============================================================
echo ""
echo -e "${BOLD}=== Unique Denials ===${NC}"
echo ""

# Extract key fields: scontext, tcontext, tclass, permission
# Format: { permission } for scontext=<source> tcontext=<target> tclass=<class>
PARSED_FILE=$(mktemp /tmp/avc_parsed.XXXXXX)
trap "rm -f $TMPFILE $PARSED_FILE" EXIT

while IFS= read -r line; do
    # Extract fields using sed
    PERM=$(echo "$line" | sed -n 's/.*{ \([^}]*\) }.*/\1/p' 2>/dev/null)
    SCON=$(echo "$line" | sed -n 's/.*scontext=\([^ ]*\).*/\1/p' 2>/dev/null)
    TCON=$(echo "$line" | sed -n 's/.*tcontext=\([^ ]*\).*/\1/p' 2>/dev/null)
    TCLASS=$(echo "$line" | sed -n 's/.*tclass=\([^ ]*\).*/\1/p' 2>/dev/null)

    if [ -n "$PERM" ] && [ -n "$SCON" ] && [ -n "$TCON" ] && [ -n "$TCLASS" ]; then
        # Extract just the type from the full context (u:r:type:s0 → type)
        STYPE=$(echo "$SCON" | cut -d: -f3)
        TTYPE=$(echo "$TCON" | cut -d: -f3)
        echo "$STYPE|$TTYPE|$TCLASS|$PERM" >> "$PARSED_FILE"
    fi
done < "$TMPFILE"

# Deduplicate and count
DEDUPED_FILE=$(mktemp /tmp/avc_deduped.XXXXXX)
trap "rm -f $TMPFILE $PARSED_FILE $DEDUPED_FILE" EXIT

sort "$PARSED_FILE" | uniq -c | sort -rn > "$DEDUPED_FILE"

UNIQUE_COUNT=$(wc -l < "$DEDUPED_FILE" 2>/dev/null || echo "0")
echo "Unique denial patterns: $UNIQUE_COUNT"
echo ""

# Display denials
printf "%-6s %-30s %-30s %-15s %s\n" "Count" "Source" "Target" "Class" "Permission(s)"
printf "%-6s %-30s %-30s %-15s %s\n" "-----" "------" "------" "-----" "-------------"

while IFS= read -r line; do
    COUNT=$(echo "$line" | awk '{print $1}')
    FIELDS=$(echo "$line" | awk '{print $2}')
    STYPE=$(echo "$FIELDS" | cut -d'|' -f1)
    TTYPE=$(echo "$FIELDS" | cut -d'|' -f2)
    TCLASS=$(echo "$FIELDS" | cut -d'|' -f3)
    PERM=$(echo "$FIELDS" | cut -d'|' -f4)
    printf "%-6s %-30s %-30s %-15s %s\n" "$COUNT" "$STYPE" "$TTYPE" "$TCLASS" "$PERM"
done < "$DEDUPED_FILE"

# ============================================================
# 3. Generate suggested allow rules
# ============================================================
echo ""
echo -e "${BOLD}=== Suggested Allow Rules ===${NC}"
echo ""
echo "# ============================================================"
echo "# Auto-generated SELinux allow rules"
echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo "# Source: $([ -n "$LOG_SOURCE" ] && echo "$LOG_SOURCE" || echo "live device")"
echo "# ============================================================"
echo "#"
echo "# WARNING: Review each rule before applying!"
echo "#   - Some denials are INTENTIONAL (security boundaries)"
echo "#   - Some denials indicate bugs (should be fixed, not allowed)"
echo "#   - Only allow what is strictly necessary"
echo "# ============================================================"
echo ""

# Group permissions by source/target/class
PREV_KEY=""
PERMS=""
while IFS= read -r line; do
    FIELDS=$(echo "$line" | awk '{print $2}')
    STYPE=$(echo "$FIELDS" | cut -d'|' -f1)
    TTYPE=$(echo "$FIELDS" | cut -d'|' -f2)
    TCLASS=$(echo "$FIELDS" | cut -d'|' -f3)
    PERM=$(echo "$FIELDS" | cut -d'|' -f4)

    KEY="$STYPE|$TTYPE|$TCLASS"
    if [ "$KEY" = "$PREV_KEY" ]; then
        PERMS="$PERMS $PERM"
    else
        if [ -n "$PREV_KEY" ]; then
            P_STYPE=$(echo "$PREV_KEY" | cut -d'|' -f1)
            P_TTYPE=$(echo "$PREV_KEY" | cut -d'|' -f2)
            P_TCLASS=$(echo "$PREV_KEY" | cut -d'|' -f3)
            echo "allow $P_STYPE $P_TTYPE:$P_TCLASS {$PERMS };"
        fi
        PREV_KEY="$KEY"
        PERMS=" $PERM"
    fi
done < <(sort -t'|' -k1,3 "$DEDUPED_FILE" | awk '{print $2}')

# Flush last entry
if [ -n "$PREV_KEY" ]; then
    P_STYPE=$(echo "$PREV_KEY" | cut -d'|' -f1)
    P_TTYPE=$(echo "$PREV_KEY" | cut -d'|' -f2)
    P_TCLASS=$(echo "$PREV_KEY" | cut -d'|' -f3)
    echo "allow $P_STYPE $P_TTYPE:$P_TCLASS {$PERMS };"
fi

echo ""
echo -e "${YELLOW}⚠  These rules are SUGGESTIONS only.${NC}"
echo "  Save to a .te file and add to sepolicy/overlays/ after review."
echo "  Do NOT blindly apply all rules."
