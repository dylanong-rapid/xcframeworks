#!/bin/bash
#
# build-all-xcframeworks.sh — Batch-build XCFrameworks in dependency order.
#
# Part of APP-6792 (XCFramework Conversion of External SPM Packages).
# Drives build-xcframework.sh once per convertible package listed in
# xcframeworks.config.json, in the correct order:
#   shared-infra → firebase → aws → pointfree → segment → okta → easy-wins
#
# Output is LOCAL ONLY: XCFrameworks/<package>/<version>/<Product>.xcframework
# Everything lives in ~/Desktop/xcframework-builder/.
#
# Usage:
#   ./build-all-xcframeworks.sh [options]
#
# Examples:
#   ./build-all-xcframeworks.sh --list
#   ./build-all-xcframeworks.sh --group easy-wins
#   ./build-all-xcframeworks.sh --skip-complex
#   ./build-all-xcframeworks.sh --only swift-log,swift-metrics --dry-run
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$SCRIPT_DIR"
CONFIG_FILE="$SCRIPT_DIR/xcframeworks.config.json"
BUILD_ONE="$SCRIPT_DIR/build-xcframework.sh"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; DIM=''; NC=''
fi
log()  { echo -e "${BLUE}▶${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*" >&2; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Options
# ──────────────────────────────────────────────────────────────────────────────
GROUPS_FILTER=""
ONLY_FILTER=""
FROM_PKG=""
SKIP_COMPLEX=false
DRY_RUN=false
LIST_ONLY=false
STOP_ON_ERROR=false
declare -a PASSTHROUGH=()

print_usage() {
    cat <<EOF
${BLUE}build-all-xcframeworks.sh${NC} — batch-build XCFrameworks in dependency order

Usage:
  $0 [options]

Selection:
  --group <g[,g2]>   Only build these groups. One or more of:
                     shared-infra, firebase, aws, pointfree, segment, okta, easy-wins
  --only <a[,b]>     Only build these package names.
  --from <name>      Start from this package (skip everything ordered before it).
  --skip-complex     Skip packages flagged "complex" (multi-product / CMake / umbrella SDKs).

Behaviour:
  --list             Print the build plan and exit (no building).
  --dry-run          Print each build command without executing it.
  --stop-on-error    Stop at the first failing package (default: continue).

Pass-through to build-xcframework.sh:
  --output-dir <dir> --min-ios <ver> --keep-sources --no-zip --no-dsym -q|--quiet

  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --group)        GROUPS_FILTER="${2:-}"; shift 2 ;;
        --only)         ONLY_FILTER="${2:-}"; shift 2 ;;
        --from)         FROM_PKG="${2:-}"; shift 2 ;;
        --skip-complex) SKIP_COMPLEX=true; shift ;;
        --list)         LIST_ONLY=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --stop-on-error) STOP_ON_ERROR=true; shift ;;
        --config)       CONFIG_FILE="${2:-}"; shift 2 ;;
        # pass-through (value-taking)
        --output-dir)   PASSTHROUGH+=(--output-dir "${2:-}"); shift 2 ;;
        --min-ios)      PASSTHROUGH+=(--min-ios "${2:-}"); shift 2 ;;
        # pass-through (flags)
        --keep-sources) PASSTHROUGH+=(--keep-sources); shift ;;
        --no-zip)       PASSTHROUGH+=(--no-zip); shift ;;
        --no-dsym)      PASSTHROUGH+=(--no-dsym); shift ;;
        -q|--quiet)     PASSTHROUGH+=(-q); shift ;;
        -h|--help)      print_usage; exit 0 ;;
        *)              die "Unknown option: $1 (see --help)" ;;
    esac
done

command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq)."
[ -f "$CONFIG_FILE" ] || die "Config not found: $CONFIG_FILE"
[ -x "$BUILD_ONE" ]   || die "Not executable: $BUILD_ONE (run: chmod +x \"$BUILD_ONE\")"

# Validate group filter values up front.
VALID_GROUPS="shared-infra firebase aws pointfree segment okta easy-wins"
if [ -n "$GROUPS_FILTER" ]; then
    IFS=',' read -r -a _gf <<< "$GROUPS_FILTER"
    for g in "${_gf[@]}"; do
        [[ " $VALID_GROUPS " == *" $g "* ]] || die "Unknown group '$g'. Valid: $VALID_GROUPS"
    done
fi

# ──────────────────────────────────────────────────────────────────────────────
# Build the selection list (TSV: order, name, group, complex, testOnly, products)
# ──────────────────────────────────────────────────────────────────────────────
in_csv() { # in_csv <needle> <csv>
    local needle="$1" csv="$2" item
    IFS=',' read -r -a _arr <<< "$csv"
    for item in "${_arr[@]}"; do [ "$item" = "$needle" ] && return 0; done
    return 1
}

# Resolve --from order threshold.
FROM_ORDER=0
if [ -n "$FROM_PKG" ]; then
    FROM_ORDER="$(jq -r --arg n "$FROM_PKG" '(.packages[] | select(.name==$n) | .order) // empty' "$CONFIG_FILE")"
    [ -n "$FROM_ORDER" ] || die "--from: package '$FROM_PKG' not found in config."
fi

mapfile_rows() { # emits TSV rows from config, sorted by order
    jq -r '
        .packages[] | select(.skip|not)
        | [ .order, .name, .group, (.complex // false), (.testOnly // false), (.products|join(",")) ]
        | @tsv' "$CONFIG_FILE" | sort -n
}

declare -a SELECTED=()
while IFS=$'\t' read -r order name group complex testonly products; do
    [ -n "$name" ] || continue
    [ -n "$GROUPS_FILTER" ] && { in_csv "$group" "$GROUPS_FILTER" || continue; }
    [ -n "$ONLY_FILTER" ]   && { in_csv "$name" "$ONLY_FILTER"   || continue; }
    [ "$order" -lt "$FROM_ORDER" ] && continue
    [ "$SKIP_COMPLEX" = true ] && [ "$complex" = "true" ] && continue
    SELECTED+=("$order"$'\t'"$name"$'\t'"$group"$'\t'"$complex"$'\t'"$testonly"$'\t'"$products")
done < <(mapfile_rows)

[ ${#SELECTED[@]} -gt 0 ] || die "No packages match the given filters."

# ──────────────────────────────────────────────────────────────────────────────
# List / plan
# ──────────────────────────────────────────────────────────────────────────────
print_plan() {
    echo ""
    echo -e "${BLUE}Build plan${NC} (${#SELECTED[@]} package(s), in order):"
    printf "  %-4s %-30s %-13s %-8s %s\n" "#" "PACKAGE" "GROUP" "FLAGS" "PRODUCTS"
    printf "  %-4s %-30s %-13s %-8s %s\n" "----" "------------------------------" "-------------" "--------" "--------"
    local i=0
    for row in "${SELECTED[@]}"; do
        IFS=$'\t' read -r order name group complex testonly products <<< "$row"
        i=$((i+1))
        local flags=""
        [ "$complex" = "true" ]  && flags+="C"
        [ "$testonly" = "true" ] && flags+="T"
        [ -z "$flags" ] && flags="-"
        printf "  %-4s %-30s %-13s %-8s %s\n" "$i" "$name" "$group" "$flags" "$products"
    done
    echo -e "  ${DIM}flags: C=complex (may need per-package tweaks), T=test-only${NC}"
    echo ""
}

print_plan
if [ "$LIST_ONLY" = true ]; then
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────────────
# Execute
# ──────────────────────────────────────────────────────────────────────────────
declare -a SUCCEEDED=() FAILED=()
START_TS=$(date +%s)

for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r order name group complex testonly products <<< "$row"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${DIM}[dry-run]${NC} $BUILD_ONE $name --config $CONFIG_FILE ${PASSTHROUGH[*]:-}"
        SUCCEEDED+=("$name")
        continue
    fi

    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $name${NC}  ${DIM}($group)${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

    if "$BUILD_ONE" "$name" --config "$CONFIG_FILE" ${PASSTHROUGH[@]:+"${PASSTHROUGH[@]}"}; then
        SUCCEEDED+=("$name")
    else
        FAILED+=("$name")
        err "Build failed for $name"
        if [ "$STOP_ON_ERROR" = true ]; then
            err "Stopping (--stop-on-error)."
            break
        fi
    fi
done

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Summary${NC}  ${DIM}(${ELAPSED}s)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
ok "Succeeded: ${#SUCCEEDED[@]}"
for n in ${SUCCEEDED[@]+"${SUCCEEDED[@]}"}; do echo -e "    ${GREEN}•${NC} $n"; done
if [ ${#FAILED[@]} -ne 0 ]; then
    err "Failed: ${#FAILED[@]}"
    for n in "${FAILED[@]}"; do echo -e "    ${RED}•${NC} $n"; done
    echo ""
    [ "$DRY_RUN" = true ] || warn "Re-run a single package with: $SCRIPT_DIR/build-xcframework.sh <name> --keep-sources"
    exit 1
fi
echo ""
ok "All selected XCFrameworks built into $PROJECT_ROOT/XCFrameworks"
