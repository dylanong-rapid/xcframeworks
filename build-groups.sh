#!/bin/bash
#
# build-groups.sh — Build XCFrameworks with a dedicated function per dependency group.
#
# Unlike build-all-xcframeworks.sh (one generic loop for every package), this script
# gives each group its own self-contained build_<group> function so per-group quirks
# live in one obvious place instead of being smeared across config toggles.
#
# It wraps the existing single-package engine build-xcframework.sh (unchanged) and the
# pinned versions/urls/revisions in xcframeworks.config.json. Group functions express the
# visible tweaks (products, scheme, library-evolution, revision) as explicit CLI flags;
# deeper knobs that build-xcframework.sh only reads from config (noMachOOverride,
# explicitProducts, enableTestability, noForceDynamic) are noted in comments and still
# come from the config entry.
#
# The aws group is opt-in and excluded from `all`: aws-crt-swift compiles a native C
# runtime and the whole group sits on top of it. Build it explicitly with `aws`.
#
# Usage:
#   ./build-groups.sh <group> [<group> ...]      # build one or more groups
#   ./build-groups.sh all                        # build every non-aws group
#   ./build-groups.sh aws                         # build the aws group (opt-in; see note)
#   ./build-groups.sh --list                     # list groups and exit
#
# Groups: shared-infra firebase pointfree segment okta easy-wins aws
#
# NOTE: `aws` is opt-in and NOT included in `all`. aws-crt-swift compiles a native
# C runtime (CMake-driven upstream; the SPM manifest vendors the C targets so
# xcodebuild can archive it), and the rest of the group sits on top of it. Build it
# explicitly with `./build-groups.sh aws` once aws-crt-swift's toolchain prereqs are
# in place.
#
# Pass-through options (forwarded to build-xcframework.sh):
#   --output-dir <dir> --min-ios <ver> --keep-sources --no-zip --no-dsym -q|--quiet
#
# Behaviour:
#   --dry-run        Print each package build command without running it.
#   --stop-on-error  Abort a group at its first failing package (default: continue).
#
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
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

ALL_GROUPS="shared-infra firebase pointfree segment okta easy-wins"
# Groups accepted on the command line. `aws` is buildable on its own but is excluded
# from ALL_GROUPS so `all` keeps its documented "every non-aws group" behaviour.
VALID_GROUPS="$ALL_GROUPS aws"

# ──────────────────────────────────────────────────────────────────────────────
# Options
# ──────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
STOP_ON_ERROR=false
LIST_ONLY=false
declare -a PASSTHROUGH=()
declare -a REQUESTED_GROUPS=()

print_usage() {
    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)          LIST_ONLY=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --stop-on-error) STOP_ON_ERROR=true; shift ;;
        --config)        CONFIG_FILE="${2:-}"; shift 2 ;;
        --output-dir)    PASSTHROUGH+=(--output-dir "${2:-}"); shift 2 ;;
        --min-ios)       PASSTHROUGH+=(--min-ios "${2:-}"); shift 2 ;;
        --keep-sources)  PASSTHROUGH+=(--keep-sources); shift ;;
        --no-zip)        PASSTHROUGH+=(--no-zip); shift ;;
        --no-dsym)       PASSTHROUGH+=(--no-dsym); shift ;;
        -q|--quiet)      PASSTHROUGH+=(-q); shift ;;
        -h|--help)       print_usage; exit 0 ;;
        all)             REQUESTED_GROUPS=($ALL_GROUPS); shift ;;
        -*)              die "Unknown option: $1 (see --help)" ;;
        *)               REQUESTED_GROUPS+=("$1"); shift ;;
    esac
done

command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq)."
[ -f "$CONFIG_FILE" ] || die "Config not found: $CONFIG_FILE"
[ -x "$BUILD_ONE" ]   || die "Not executable: $BUILD_ONE"

if [ "$LIST_ONLY" = true ]; then
    echo "Groups handled by this script:"
    for g in $ALL_GROUPS; do echo "  - $g"; done
    echo "  - aws   (opt-in; not part of 'all' — see note below)"
    echo ""
    echo "(aws needs aws-crt-swift's native C runtime; build it explicitly: ./build-groups.sh aws)"
    exit 0
fi

[ ${#REQUESTED_GROUPS[@]} -gt 0 ] || { print_usage; exit 1; }
for g in "${REQUESTED_GROUPS[@]}"; do
    [[ " $VALID_GROUPS " == *" $g "* ]] || die "Unknown group '$g'. Valid: $VALID_GROUPS (or 'all')."
done

# ──────────────────────────────────────────────────────────────────────────────
# Result tracking (populated by the `b` helper)
# ──────────────────────────────────────────────────────────────────────────────
declare -a SUCCEEDED=() FAILED=() SKIPPED=()

# b — build one package through build-xcframework.sh.
#   b <pkg> [extra flags for build-xcframework.sh ...]
# Version/url/revision/tag resolve from config; pass per-package tweaks as flags.
b() {
    local pkg="$1"; shift
    echo ""
    echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
    echo -e "${BLUE}  $pkg${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${DIM}[dry-run]${NC} $BUILD_ONE $pkg --config $CONFIG_FILE $* ${PASSTHROUGH[*]:-}"
        SUCCEEDED+=("$pkg")
        return 0
    fi

    if "$BUILD_ONE" "$pkg" --config "$CONFIG_FILE" "$@" ${PASSTHROUGH[@]:+"${PASSTHROUGH[@]}"}; then
        ok "$pkg built"
        SUCCEEDED+=("$pkg")
        return 0
    fi

    err "Build failed for $pkg"
    FAILED+=("$pkg")
    [ "$STOP_ON_ERROR" = true ] && die "Stopping (--stop-on-error)."
    return 1
}

# skip — record a package we deliberately do not build (with a reason).
skip() { warn "skipping $1 — $2"; SKIPPED+=("$1"); }

# ══════════════════════════════════════════════════════════════════════════════
# GROUP: shared-infra
#   Apple/swift-server stack. Most build cleanly. The ones with tweaks:
#     - many: --no-library-evolution (their .swiftinterface is invalid under evolution)
#     - swift-collections: explicitProducts (computed products array) + noToolsDowngrade
#                   (1.3.0's manifest needs the swift-tools-6 .swiftLanguageMode API) — config.
#     - swift-http-structured-headers: noMachOOverride — from config
#     - swift-nio: 5 products in one archive; noMachOOverride — from config
#     - grpc-swift: package ships protoc plugin executables AND compiles swift-nio from
#                   source. Fixed via: explicitProducts (drops the executables, forces the
#                   GRPC product dynamic — its name is a computed var so force_dynamic misses
#                   it), --no-library-evolution (swift-nio's @inlinable inits fail to compile
#                   under BUILD_LIBRARY_FOR_DISTRIBUTION), and a precise patchDeps pin
#                   ("swift-nio.git", not "swift-nio", which also matched swift-nio-ssl).
#     - opentelemetry-swift: currently skipped upstream (multi-product, noForceDynamic).
# ══════════════════════════════════════════════════════════════════════════════
build_shared_infra() {
    log "GROUP shared-infra"
    b swift-log                       --products Logging                  --no-library-evolution
    b swift-metrics                   --products CoreMetrics
    b swift-service-context           --products ServiceContextModule
    b swift-atomics                   --products Atomics                  --no-library-evolution
    b swift-numerics                  --products Numerics                 --no-library-evolution
    b swift-http-types                --products HTTPTypes
    b swift-http-structured-headers   --products StructuredFieldValues       # noMachOOverride (config)
    b swift-system                    --products SystemPackage
    b SwiftProtobuf                   --products SwiftProtobuf
    b swift-collections               --products OrderedCollections       --no-library-evolution   # explicitProducts + noToolsDowngrade (config)
    b swift-algorithms                --products Algorithms               --no-library-evolution
    b swift-async-algorithms          --products AsyncAlgorithms
    b swift-nio                       --products NIOCore,NIO,NIOEmbedded,NIOPosix,NIOHTTP1 --no-library-evolution  # noMachOOverride (config)
    b swift-nio-ssl                   --products NIOSSL                   --no-library-evolution
    b swift-nio-http2                 --products NIOHTTP2                 --no-library-evolution
    b swift-nio-extras                --products NIOExtras                --no-library-evolution
    b swift-nio-transport-services    --products NIOTransportServices     --no-library-evolution
    b swift-distributed-tracing       --products Tracing
    b swift-service-lifecycle         --products ServiceLifecycle         --no-library-evolution
    b async-http-client               --products AsyncHTTPClient          --no-library-evolution
    b grpc-swift                      --products GRPC --scheme GRPC --no-library-evolution  # explicitProducts drops protoc-plugin executables; evolution-off lets swift-nio compile (config)
    b Opentracing                     --products opentracing
    b Thrift                          --products Thrift
    skip opentelemetry-swift "multi-product; flagged skip in config (noForceDynamic, needs source work)"
    b swift-log-file                  --products FileLogging              --no-library-evolution
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP: firebase
#   Google/Firebase ObjC+Swift stack, built bottom-up. Quirks (all learned the hard way):
#     - Promises: product is FBLPromises (ObjC) — NOT the Swift "Promises" product.
#     - InteropForGoogle: the real product is RecaptchaInterop (repo exposes no
#       "GoogleInterop" product despite the package name).
#     - AppCheck: the real product is AppCheckCore (not "FirebaseAppCheck").
#     - GoogleUtilities: NO umbrella product. It ships 9 GUL* products, each aliasing a
#       "GoogleUtilities-<X>" target. Built together in one archive the depended-upon
#       targets emit an EMPTY product-named framework (binary lands under the target name).
#       Building each product in its OWN archive makes it a leaf → real binary. So we loop.
#     - Firebase: the Firebase-Package umbrella scheme builds ALL products at once, which
#       forces a static/dynamic conflict on FirebaseCore (dozens of other targets link it
#       statically). Building each wanted product in its OWN archive (single-product →
#       exact scheme) sidesteps that entirely. It also avoids dragging in the binary
#       targets (GoogleAppMeasurement, nanopb, leveldb) that the analytics products need.
# ══════════════════════════════════════════════════════════════════════════════
build_firebase() {
    log "GROUP firebase"
    b Promises            --products FBLPromises
    b InteropForGoogle    --products RecaptchaInterop
    b GTMSessionFetcher   --products GTMSessionFetcher
    # GoogleUtilities: one archive per product (see note above).
    local gul
    for gul in GULAppDelegateSwizzler GULEnvironment GULLogger GULMethodSwizzler \
               GULNetwork GULNSData GULReachability GULUserDefaults; do
        b GoogleUtilities --products "$gul"
    done
    b GoogleDataTransport --products GoogleDataTransport
    b AppCheck            --products AppCheckCore
    # Firebase: one archive per product (see note above).
    local fb
    for fb in FirebaseCore FirebaseInstallations FirebaseMessaging; do
        b Firebase --products "$fb"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP: aws
#   AWS SDK + Amplify, built bottom-up. This group is OPT-IN (not part of `all`)
#   because aws-crt-swift compiles a native C runtime that the rest of the stack
#   depends on. Build order matters: aws-crt-swift → smithy-swift → aws-sdk-swift,
#   then the Amplify packages on top.
#     - aws-crt-swift: product AwsCommonRuntimeKit. Upstream uses CMake, but the SPM
#       manifest vendors the C targets (aws-c-*), so xcodebuild archives it directly.
#       It MUST build first — every other package in the group links it.
#     - smithy-swift: ships many products; we build only ClientRuntime.
#     - aws-sdk-swift: very large; we build only AWSClientRuntime.
#     - AmplifyUtilsNotifications: single clean product.
#     - Amplify: multi-product umbrella. Like Firebase, the umbrella scheme builds all
#       products at once and forces static/dynamic conflicts on the shared core, so we
#       build each wanted product (Amplify, AWSCognitoAuthPlugin, AWSAPIPlugin) in its
#       OWN archive (single-product → exact scheme → real binary).
# ══════════════════════════════════════════════════════════════════════════════
build_aws() {
    log "GROUP aws"
    b aws-crt-swift             --products AwsCommonRuntimeKit --no-library-evolution     # submodules:true (config); .swiftinterface can't see private C module AwsCAuth under evolution
    b smithy-swift              --products ClientRuntime      --no-library-evolution     # pulls swift-log (@inlinable fails under evolution)
    b aws-sdk-swift             --products AWSClientRuntime    --no-library-evolution     # explicitProducts (config) injects a dynamic AWSClientRuntime (products are computed)
    b AmplifyUtilsNotifications --products AmplifyUtilsNotifications
    # Amplify: one archive per product (see note above). --no-library-evolution because
    # the umbrella transitively compiles swift-log (invalid .swiftinterface under evolution).
    local amp
    for amp in Amplify AWSCognitoAuthPlugin AWSAPIPlugin; do
        b Amplify --products "$amp" --no-library-evolution
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP: pointfree
#   Point-Free libraries. All clean single-product SPM packages.
# ══════════════════════════════════════════════════════════════════════════════
build_pointfree() {
    log "GROUP pointfree"
    b xctest-dynamic-overlay  --products IssueReporting
    b swift-concurrency-extras --products ConcurrencyExtras
    b combine-schedulers      --products CombineSchedulers
    b swift-clocks            --products Clocks
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP: segment
#   Segment analytics + its small deps. Clean single-product packages.
# ══════════════════════════════════════════════════════════════════════════════
build_segment() {
    log "GROUP segment"
    b Sovran           --products Sovran
    b JSONSafeEncoding --products JSONSafeEncoding
    b Segment          --products Segment
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP: okta
#   Okta auth SDK + the Apple crypto stack it needs. Everything here builds
#   WITHOUT library evolution (these packages emit invalid .swiftinterface under it).
#     - OktaIdx: also needs ENABLE_TESTABILITY=YES (config) for an internal module.
#     - swift-crypto: flagged skip upstream — CryptoExtras links Crypto statically,
#       conflicting with forced-dynamic products. Attempted with noForceDynamic (config).
# ══════════════════════════════════════════════════════════════════════════════
build_okta() {
    log "GROUP okta"
    b swift-asn1         --products SwiftASN1   --no-library-evolution
    skip swift-crypto "flagged skip in config (static/dynamic Crypto conflict; needs source work)"
    b swift-certificates --products X509        --no-library-evolution
    b AuthFoundation     --products AuthFoundation --no-library-evolution
    b OktaIdx            --products OktaIdx      --no-library-evolution   # enableTestability (config)
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP: easy-wins
#   Misc third-party packages. Mostly clean; the tricky ones:
#     - JSONAny / PriorsSchema / CombineExpectations: --no-library-evolution.
#     - swiftui-introspect: -Static/-Dynamic product variants (undefined symbols under
#       mh_dylib); built via config knobs.
#     - CombineExt: committed .xcodeproj has no shared schemes.
#     - SWCompression: source dep on BitByteData (built just before it).
# ══════════════════════════════════════════════════════════════════════════════
build_easy_wins() {
    log "GROUP easy-wins"
    b GrowthBook-IOS  --products GrowthBook
    b Sentry          --products Sentry
    b SimpleKeychain  --products SimpleKeychain
    b LRUCache        --products LRUCache
    b swiftui-introspect --products SwiftUIIntrospect
    b CombineExt      --products CombineExt
    b JSONAny         --products JSONAny          --no-library-evolution
    b XCGLogger       --products XCGLogger
    b SQLite.swift    --products SQLite
    b BitByteData     --products BitByteData
    b SWCompression   --products SWCompression
    b PriorsSchema    --products PriorsSchema     --no-library-evolution
    b CombineExpectations --products CombineExpectations --no-library-evolution
}

# ──────────────────────────────────────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────────────────────────────────────
START_TS=$(date +%s)
for g in "${REQUESTED_GROUPS[@]}"; do
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  GROUP: $g${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    case "$g" in
        shared-infra) build_shared_infra ;;
        firebase)     build_firebase ;;
        pointfree)    build_pointfree ;;
        segment)      build_segment ;;
        okta)         build_okta ;;
        easy-wins)    build_easy_wins ;;
        aws)          build_aws ;;
    esac
done

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
END_TS=$(date +%s); ELAPSED=$((END_TS - START_TS))
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Summary${NC}  ${DIM}(${ELAPSED}s)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
ok "Succeeded: ${#SUCCEEDED[@]}"
for n in ${SUCCEEDED[@]+"${SUCCEEDED[@]}"}; do echo -e "    ${GREEN}•${NC} $n"; done
if [ ${#SKIPPED[@]} -ne 0 ]; then
    warn "Skipped: ${#SKIPPED[@]}"
    for n in "${SKIPPED[@]}"; do echo -e "    ${YELLOW}•${NC} $n"; done
fi
if [ ${#FAILED[@]} -ne 0 ]; then
    err "Failed: ${#FAILED[@]}"
    for n in "${FAILED[@]}"; do echo -e "    ${RED}•${NC} $n"; done
    exit 1
fi
echo ""
ok "All requested groups built into $SCRIPT_DIR/XCFrameworks"
