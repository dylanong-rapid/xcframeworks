#!/bin/bash
#
# build-xcframework.sh — Build a pre-compiled XCFramework from an external SPM package.
#
# Part of APP-6792 (XCFramework Conversion of External SPM Packages).
# See SA-APP-6792-xcframework-conversion.md for the full design.
#
# Pipeline (per product/scheme):
#   1. Clone the package source at the pinned tag into a temp dir.
#   2. Resolve the scheme(s)/product(s) to build (CLI args or xcframeworks.config.json).
#   3. xcodebuild archive for iphoneos and iphonesimulator separately.
#   4. Merge slices with xcodebuild -create-xcframework.
#   5. Write <Product>.xcframework to XCFrameworks/<Package>/<version>/ (LOCAL folder).
#   6. Zip the bundle and compute its SwiftPM checksum.
#   7. Upsert XCFrameworks/xcframeworks-manifest.json.
#
# Storage is LOCAL ONLY: everything lands in ~/Desktop/xcframework-builder/XCFrameworks/.
# Reference the result from a Package.swift wrapper with:
#   .binaryTarget(name: "<Product>", path: "<path>/XCFrameworks/<Package>/<version>/<Product>.xcframework")
#
# Usage:
#   ./build-xcframework.sh <package-name> [<version>] [<repo-url>] [product ...] [options]
#
# Examples:
#   ./build-xcframework.sh Sentry 9.8.0 https://github.com/getsentry/sentry-cocoa
#   ./build-xcframework.sh swift-log 1.6.4 https://github.com/apple/swift-log Logging
#   ./build-xcframework.sh swift-nio            # version/url/products resolved from config
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Paths
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$SCRIPT_DIR"
CONFIG_FILE="$SCRIPT_DIR/xcframeworks.config.json"

# ──────────────────────────────────────────────────────────────────────────────
# Colors (disabled when not a TTY or when NO_COLOR is set)
# ──────────────────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; DIM=''; NC=''
fi
log()   { echo -e "${BLUE}▶${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*" >&2; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────────────
NAME=""
VERSION=""
URL=""
TAG=""
EXPECT_REVISION=""
SCHEME=""
LIBRARY_EVOLUTION=true
NO_FORCE_DYNAMIC=false
NO_MACH_O_OVERRIDE=false
EXPLICIT_PRODUCTS=false
DISABLE_XCODEPROJ=false
SWIFT_VERSION_OVERRIDE=""
ENABLE_TESTABILITY=false
NO_TOOLS_DOWNGRADE=false
CLONE_SUBMODULES=false
NO_STRIP_DEV_TOOLS=false
declare -a PRODUCTS=()
OUTPUT_DIR="$PROJECT_ROOT/XCFrameworks"
MIN_IOS="17.0"
KEEP_SOURCES=false
MAKE_ZIP=true
INCLUDE_DSYM=true
QUIET=false

print_usage() {
    cat <<EOF
${BLUE}build-xcframework.sh${NC} — build a binary XCFramework from an external SPM package

Usage:
  $0 <package-name> [<version>] [<repo-url>] [product ...] [options]

Positional:
  package-name   Package identity (matches Package.resolved / config "name").
  version        Semantic version / git tag. Falls back to the config entry.
  repo-url       Git URL. Falls back to the config entry.
  product...     One or more product/scheme names to build. Falls back to the
                 config entry, then to <package-name>.

Options:
  --products a,b,c     Comma-separated products (alternative to positionals).
  --scheme <name>      Xcode scheme to archive (default: auto-detected package scheme).
  --tag <tag>          Git tag to clone (default: <version>, with v<version> fallback).
  --revision <sha>     Expected commit; warns if the cloned tag resolves elsewhere.
  --output-dir <dir>   Output root (default: $OUTPUT_DIR).
  --min-ios <ver>      iOS deployment target for the slices (default: $MIN_IOS).
  --no-library-evolution  Build without BUILD_LIBRARY_FOR_DISTRIBUTION (no module
                          stability; needed by a few packages that fail to compile with it).
  --submodules         Init git submodules after clone (packages whose native sources
                       live in submodules, e.g. aws-crt-swift's aws-common-runtime).
  --config <file>      Config file (default: $CONFIG_FILE).
  --keep-sources       Do not delete the temp clone/build dir afterwards.
  --no-zip             Skip the .zip + checksum step.
  --no-dsym            Do not embed dSYM debug symbols.
  -q, --quiet          Quieter xcodebuild output.
  -h, --help           Show this help.

Output layout:
  <output-dir>/<package>/<version>/<Product>.xcframework
  <output-dir>/<package>/<version>/<Product>.xcframework.zip   (unless --no-zip)
  <output-dir>/xcframeworks-manifest.json
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
declare -a POSITIONALS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --products)     IFS=',' read -r -a _p <<< "${2:-}"; [ ${#_p[@]} -gt 0 ] && PRODUCTS+=("${_p[@]}"); shift 2 ;;
        --scheme)       SCHEME="${2:-}"; shift 2 ;;
        --tag)          TAG="${2:-}"; shift 2 ;;
        --revision)     EXPECT_REVISION="${2:-}"; shift 2 ;;
        --output-dir)   OUTPUT_DIR="${2:-}"; shift 2 ;;
        --min-ios)      MIN_IOS="${2:-}"; shift 2 ;;
        --no-library-evolution) LIBRARY_EVOLUTION=false; shift ;;
        --submodules)   CLONE_SUBMODULES=true; shift ;;
        --config)       CONFIG_FILE="${2:-}"; shift 2 ;;
        --keep-sources) KEEP_SOURCES=true; shift ;;
        --no-zip)       MAKE_ZIP=false; shift ;;
        --no-dsym)      INCLUDE_DSYM=false; shift ;;
        -q|--quiet)     QUIET=true; shift ;;
        -h|--help)      print_usage; exit 0 ;;
        -*)             die "Unknown option: $1 (see --help)" ;;
        *)              POSITIONALS+=("$1"); shift ;;
    esac
done

[ ${#POSITIONALS[@]} -ge 1 ] || { print_usage; exit 1; }
NAME="${POSITIONALS[0]}"
[ ${#POSITIONALS[@]} -ge 2 ] && VERSION="${POSITIONALS[1]}"
[ ${#POSITIONALS[@]} -ge 3 ] && URL="${POSITIONALS[2]}"
if [ ${#POSITIONALS[@]} -ge 4 ]; then
    PRODUCTS+=("${POSITIONALS[@]:3}")
fi

# ──────────────────────────────────────────────────────────────────────────────
# Tooling checks
# ──────────────────────────────────────────────────────────────────────────────
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found (install Xcode)."
command -v git        >/dev/null 2>&1 || die "git not found."
command -v jq         >/dev/null 2>&1 || die "jq not found (brew install jq)."
command -v swift      >/dev/null 2>&1 || die "swift not found."
$MAKE_ZIP && { command -v zip >/dev/null 2>&1 || die "zip not found."; }

# ──────────────────────────────────────────────────────────────────────────────
# Resolve missing fields from the config file
# ──────────────────────────────────────────────────────────────────────────────
config_get() { # config_get <jq-filter>
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e -r --arg n "$NAME" "(.packages[] | select(.name==\$n) | $1) // empty" "$CONFIG_FILE" 2>/dev/null
}

if [ -f "$CONFIG_FILE" ]; then
    [ -z "$VERSION" ] && VERSION="$(config_get '.version' || true)"
    [ -z "$URL" ]     && URL="$(config_get '.url' || true)"
    [ -z "$TAG" ]     && TAG="$(config_get '.tag' || true)"
    [ -z "$EXPECT_REVISION" ] && EXPECT_REVISION="$(config_get '.revision' || true)"
    [ -z "$SCHEME" ]  && SCHEME="$(config_get '.scheme' || true)"
    if [ "$LIBRARY_EVOLUTION" = true ] && [ "$(config_get '.noLibraryEvolution' || true)" = "true" ]; then
        LIBRARY_EVOLUTION=false
    fi
    if [ "$(config_get '.noForceDynamic' || true)" = "true" ]; then
        NO_FORCE_DYNAMIC=true
    fi
    if [ "$(config_get '.explicitProducts' || true)" = "true" ]; then
        EXPLICIT_PRODUCTS=true
    fi
    if [ "$(config_get '.disableXcodeProj' || true)" = "true" ]; then
        DISABLE_XCODEPROJ=true
    fi
    if [ "$(config_get '.noMachOOverride' || true)" = "true" ]; then
        NO_MACH_O_OVERRIDE=true
    fi
    if [ -z "$SWIFT_VERSION_OVERRIDE" ]; then
        SWIFT_VERSION_OVERRIDE="$(config_get '.swiftVersion' || true)"
    fi
    if [ "$(config_get '.enableTestability' || true)" = "true" ]; then
        ENABLE_TESTABILITY=true
    fi
    if [ "$(config_get '.noToolsDowngrade' || true)" = "true" ]; then
        NO_TOOLS_DOWNGRADE=true
    fi
    if [ "$(config_get '.submodules' || true)" = "true" ]; then
        CLONE_SUBMODULES=true
    fi
    if [ "$(config_get '.noStripDevTools' || true)" = "true" ]; then
        NO_STRIP_DEV_TOOLS=true
    fi
    if [ ${#PRODUCTS[@]} -eq 0 ]; then
        while IFS= read -r line; do [ -n "$line" ] && PRODUCTS+=("$line"); done \
            < <(jq -r --arg n "$NAME" '.packages[] | select(.name==$n) | .products[]?' "$CONFIG_FILE" 2>/dev/null)
    fi
fi

[ -n "$VERSION" ] || die "No version for '$NAME' (pass <version> or add it to $CONFIG_FILE)."
[ -n "$URL" ]     || die "No repo URL for '$NAME' (pass <repo-url> or add it to $CONFIG_FILE)."
[ -n "$TAG" ]     && true || TAG="$VERSION"
if [ ${#PRODUCTS[@]} -eq 0 ]; then
    warn "No products configured for '$NAME'; defaulting to scheme '$NAME'."
    PRODUCTS=("$NAME")
fi

# ──────────────────────────────────────────────────────────────────────────────
# Workspace dirs
# ──────────────────────────────────────────────────────────────────────────────
WORK_ROOT="${TMPDIR:-/tmp}/rapid-xcframeworks"
SRC_DIR="$WORK_ROOT/src/$NAME"
DD_DIR="$WORK_ROOT/dd/$NAME"
ARCHIVE_DIR="$WORK_ROOT/archives/$NAME"
DEST_DIR="$OUTPUT_DIR/$NAME/$VERSION"
mkdir -p "$ARCHIVE_DIR" "$DEST_DIR"

cleanup() {
    if [ "$KEEP_SOURCES" = false ]; then
        rm -rf "$SRC_DIR" "$DD_DIR" "$ARCHIVE_DIR"
    fi
}
trap cleanup EXIT

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | sed 's/ *$//')"

# Resolve libclang_rt paths — needed to link ___isPlatformVersionAtLeast for
# back-deployment stubs generated by the Swift compiler. Clang version dir
# (e.g. "17") varies across Xcode releases; resolve dynamically.
CLANG_RT_IOS=""
CLANG_RT_IOSSIM=""
_clang_rt_dir="$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang"
if [ -d "$_clang_rt_dir" ]; then
    _rt_ios="$(find "$_clang_rt_dir" -name "libclang_rt.ios.a"    2>/dev/null | sort -V | tail -1)"
    _rt_sim="$(find "$_clang_rt_dir" -name "libclang_rt.iossim.a" 2>/dev/null | sort -V | tail -1)"
    [ -f "$_rt_ios" ] && CLANG_RT_IOS="$_rt_ios"
    [ -f "$_rt_sim" ] && CLANG_RT_IOSSIM="$_rt_sim"
fi

# Allow git subprocesses spawned by xcodebuild/SPM to use bare repositories.
# SPM clones packages as bare repos into its resolution cache; without this,
# git binary processes reject them with "safe.bareRepository is 'explicit'".
# GIT_CONFIG_COUNT is the env-variable config mechanism (git 2.32+), which
# works even when HOME or gitconfig file lookup is non-standard inside Xcode.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.bareRepository
export GIT_CONFIG_VALUE_0=all

echo ""
log "Package : ${GREEN}$NAME${NC} @ ${GREEN}$VERSION${NC}  (tag: $TAG)"
log "URL     : $URL"
log "Products: ${PRODUCTS[*]}"
log "Output  : $DEST_DIR"
log "Xcode   : $XCODE_VERSION"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Clone the tagged source
# ──────────────────────────────────────────────────────────────────────────────
clone_source() {
    rm -rf "$SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    log "Cloning $NAME @ $TAG ..."
    if ! git clone --quiet --depth 1 --branch "$TAG" "$URL" "$SRC_DIR" 2>/dev/null; then
        warn "Tag '$TAG' not found; retrying as 'v$TAG' ..."
        rm -rf "$SRC_DIR"
        git clone --quiet --depth 1 --branch "v$TAG" "$URL" "$SRC_DIR" \
            || die "Failed to clone $URL at tag '$TAG' (or 'v$TAG')."
    fi
    if [ -n "$EXPECT_REVISION" ]; then
        local head; head="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo '')"
        if [ -n "$head" ] && [ "$head" != "$EXPECT_REVISION" ]; then
            warn "HEAD ($head) != pinned revision ($EXPECT_REVISION) for $NAME."
        fi
    fi
    # Packages whose native sources live in git submodules (e.g. aws-crt-swift's
    # aws-common-runtime/aws-c-* C libraries) need them checked out, otherwise the
    # C target dirs are empty and Swift fails with "no such module 'AwsCAuth'".
    if [ "$CLONE_SUBMODULES" = true ]; then
        log "  initializing git submodules ..."
        git -C "$SRC_DIR" submodule update --init --recursive --depth 1 \
            || die "Failed to initialize submodules for $NAME."
    fi
    [ -f "$SRC_DIR/Package.swift" ] || die "$NAME has no Package.swift — not an SPM package."
    # Opt-out: packages whose manifest needs swift-tools-version 6.x APIs (e.g.
    # swift-collections' .swiftLanguageMode) set "noToolsDowngrade": true in config.
    [ "$NO_TOOLS_DOWNGRADE" = true ] || downgrade_swift_tools_version
    # Opt-out: packages whose dev-tool deps (swift-docc-plugin) are already gated behind
    # an env var / optional helper (e.g. aws-sdk-swift's `return .package(...)`,
    # smithy-swift's `dependencies.append(.package(...))`). The strip regex would corrupt
    # those enclosing statements, so set "noStripDevTools": true for them in config.
    [ "$NO_STRIP_DEV_TOOLS" = true ] || strip_macos_only_deps
    [ "$NO_FORCE_DYNAMIC" = true ] || force_dynamic_products
    [ "$EXPLICIT_PRODUCTS" = true ] && inject_explicit_products
    patch_pinned_deps
    ok "Cloned to $SRC_DIR"
}

# ──────────────────────────────────────────────────────────────────────────────
# 1b-pre. Downgrade swift-tools-version:6.0 → 5.10 in Package*.swift.
#     xcodebuild forces SWIFT_VERSION=6 for swift-tools-version:6.0 packages,
#     enabling strict concurrency rules that break @inlinable inits in otherwise
#     valid Swift code (e.g. swift-nio 2.87.0 _NIODataStructures/Heap.swift).
#     Swift 5.10 still supports all the Swift 5.x upcoming-feature flags
#     (enableUpcomingFeature) used by these packages, so the downgrade is safe.
# ──────────────────────────────────────────────────────────────────────────────
downgrade_swift_tools_version() {
    for pkg in "$SRC_DIR"/Package*.swift; do
        [ -f "$pkg" ] || continue
        if grep -q 'swift-tools-version:6\.' "$pkg" 2>/dev/null; then
            sed -i '' 's|// swift-tools-version:6\.[0-9]*|// swift-tools-version:5.10|' "$pkg"
            log "  downgraded swift-tools-version to 5.10 in $(basename "$pkg")"
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 1b. Strip #if os(macOS) blocks from Package.swift that add developer-tool
#     dependencies (swift-docc-plugin, carton, etc.).  These are docs/wasm
#     tooling — irrelevant for iOS — but SPM tries to fetch them as bare-repo
#     clones, which triggers a libgit2 safe.bareRepository bug and aborts the
#     build.  Removing the block before xcodebuild runs fixes it cleanly.
# ──────────────────────────────────────────────────────────────────────────────
strip_macos_only_deps() {
    # Strip developer-tool-only dependencies (swift-docc-plugin, carton, swift-benchmark)
    # from ALL Package*.swift manifests before running xcodebuild.
    #
    # These deps appear in several patterns:
    #   1. #if os(macOS) ... dep ... #endif
    #   2. #if !os(Windows) ... dep ... #endif
    #   3. Unconditional .package(url: "...swift-docc-plugin", ...)
    #
    # Removing them avoids xcodebuild trying to resolve them, which causes bare-repo
    # git failures for transitive deps. We also set GIT_CONFIG_COUNT to handle the
    # transitive case, but stripping is belt-and-suspenders.
    local any_stripped=0
    for pkg in "$SRC_DIR"/Package*.swift; do
        [ -f "$pkg" ] || continue
        grep -qE 'swift-docc-plugin|swiftwasm/carton|swift-benchmark' "$pkg" || continue

        python3 - "$pkg" <<'PYEOF'
import sys, re, os

path = sys.argv[1]
with open(path) as f:
    src = f.read()

dev_tools = re.compile(r'swift-docc-plugin|swiftwasm/carton|swift-benchmark')

# Pattern 1 & 2: any #if ... #endif block containing a dev-tool dep
if_re = re.compile(r'#if\b.*?#endif', re.DOTALL)
result = if_re.sub(lambda m: '' if dev_tools.search(m.group()) else m.group(), src)

# Pattern 3: unconditional .package(url: "...dev-tool...", ...) lines
result = re.sub(r'\s*\.package\(url:\s*"[^"]*(?:swift-docc-plugin|swiftwasm/carton|swift-benchmark)[^"]*"[^)]*\),?', '', result)

if result != src:
    with open(path, 'w') as f:
        f.write(result)
    print(f"  stripped dev-tool deps from {os.path.basename(path)}")
PYEOF
        any_stripped=1
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 1c. Force all implicit-static library products to .dynamic in Package*.swift.
#     SPM library products with no explicit type default to static. When we build
#     with MACH_O_TYPE=mh_dylib, the static targets compile but don't produce a
#     .framework bundle — only a .o file. Adding type: .dynamic forces a proper
#     dynamic framework output that can be packaged into an XCFramework.
# ──────────────────────────────────────────────────────────────────────────────
force_dynamic_products() {
    # Only force the products listed in PRODUCTS to .dynamic.
    # Forcing ALL library products breaks packages where some products are
    # dependencies of others (static/dynamic conflict in the same build).
    local _products_json="[]"
    if [ ${#PRODUCTS[@]} -gt 0 ]; then
        _products_json="$(printf '"%s"\n' "${PRODUCTS[@]}" | jq -s '.')"
    fi
    for pkg in "$SRC_DIR"/Package*.swift; do
        [ -f "$pkg" ] || continue
        grep -qE '\.library' "$pkg"              || continue   # no library products at all
        python3 - "$pkg" "$_products_json" <<'PYEOF'
import sys, re, os, json

path = sys.argv[1]
products_to_force = set(json.loads(sys.argv[2])) if len(sys.argv) > 2 else set()

with open(path) as f:
    src = f.read()

# Match .library( ... ) blocks that lack a type: argument.
# Use a recursive/balanced approach by scanning token by token.
result_parts = []
pos = 0
pattern = re.compile(r'\.library\s*\(', re.DOTALL)

for m in pattern.finditer(src):
    result_parts.append(src[pos:m.end()])
    pos = m.end()
    # Find the matching closing paren (skip nested parens)
    depth = 1
    i = pos
    while i < len(src) and depth > 0:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
        i += 1
    body = src[pos:i-1]   # everything between .library( and its closing )
    closing = src[i-1:i]  # the closing )
    pos = i

    if re.search(r'\btype\s*:', body):
        # Already has explicit type — leave as-is
        result_parts.append(body + closing)
    else:
        # Extract product name for filtering
        name_match = re.search(r'\bname\s*:\s*"([^"]+)"', body)
        product_name = name_match.group(1) if name_match else None
        # Only force products in our list (if a list was provided)
        if products_to_force and product_name not in products_to_force:
            result_parts.append(body + closing)
        else:
            # Insert type: .dynamic before targets:
            new_body = re.sub(r'(\btargets\s*:)', r'type: .dynamic, \1', body, count=1)
            result_parts.append(new_body + closing)

result_parts.append(src[pos:])
result = ''.join(result_parts)

if result != src:
    with open(path, 'w') as f:
        f.write(result)
    print(f"  forced library products to .dynamic in {os.path.basename(path)}")
PYEOF
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 1d. For packages that use computed/dynamic Package.swift product arrays
#     (swift-tools-version 6.x compactMap patterns), inject an explicit
#     products declaration so xcodebuild can produce a real .framework.
#     Set explicitProducts: true in xcframeworks.config.json to enable.
# ──────────────────────────────────────────────────────────────────────────────
inject_explicit_products() {
    local _products_json="[]"
    if [ ${#PRODUCTS[@]} -gt 0 ]; then
        _products_json="$(printf '"%s"\n' "${PRODUCTS[@]}" | jq -s '.')"
    fi
    for pkg in "$SRC_DIR"/Package*.swift; do
        [ -f "$pkg" ] || continue
        python3 - "$pkg" "$_products_json" <<'PYEOF'
import sys, re, os, json

path = sys.argv[1]
products = json.loads(sys.argv[2])

with open(path) as f:
    src = f.read()

# Build explicit product lines for each requested product
explicit_lines = []
for p in products:
    explicit_lines.append(f'    .library(name: "{p}", type: .dynamic, targets: ["{p}"]),')
if not explicit_lines:
    sys.exit(0)

inject_block = "\n".join(explicit_lines)

# Find `Package(` constructor call and look for `products:` argument
# Replace the products: value (variable or array) with an explicit array
# Pattern: products: <variable or [...]>
pkg_pattern = re.compile(r'(let\s+package\s*=\s*Package\s*\([^)]*?products\s*:)\s*(_\w+|\[[^\]]*\])', re.DOTALL)

def replace_products(m):
    return m.group(1) + f' [\n{inject_block}\n  ]'

new_src = pkg_pattern.sub(replace_products, src)
if new_src == src:
    # Simpler fallback: just replace the products: variable name
    new_src = re.sub(r'(products\s*:)\s*_\w+', f'\\1 [\n{inject_block}\n  ]', src)
if new_src == src:
    # General fallback: the products: value is an expression (e.g.
    # `runtimeProducts + serviceTargets.map(...)` in aws-sdk-swift). Replace
    # everything from `products:` up to the trailing comma before the next
    # top-level key (dependencies:/targets:) with the explicit array.
    new_src = re.sub(
        r'(products\s*:)\s*.*?,(\s*(?:dependencies|targets)\s*:)',
        lambda m: m.group(1) + f' [\n{inject_block}\n  ],' + m.group(2),
        src, count=1, flags=re.DOTALL)

if new_src != src:
    with open(path, 'w') as f:
        f.write(new_src)
    print(f"  injected explicit products {products} in {os.path.basename(path)}")
else:
    print(f"  WARNING: could not inject explicit products in {os.path.basename(path)}", file=sys.stderr)
PYEOF
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 1d-alt. Pin transitive dependencies to exact versions (patchDeps config).
#     Used when `-resolvePackageDependencies` would pull a newer-than-pinned
#     version of a transitive dep (e.g. swift-nio 2.101 for grpc-swift).
#     Config format: "patchDeps": {"swift-nio": "2.87.0"}
#     Replaces `from:` or `upToNextMajor(from:)` in Package.swift with exact.
# ──────────────────────────────────────────────────────────────────────────────
patch_pinned_deps() {
    local raw_deps
    raw_deps="$(config_get '.patchDeps // {}' || true)"
    [ -z "$raw_deps" ] || [ "$raw_deps" = "null" ] || [ "$raw_deps" = "{}" ] && return 0
    for pkg in "$SRC_DIR"/Package*.swift; do
        [ -f "$pkg" ] || continue
        python3 - "$pkg" "$raw_deps" <<'PYEOF' || true
import sys, re, json, os

path = sys.argv[1]
deps = json.loads(sys.argv[2])   # {"swift-nio": "2.87.0", ...}
if not deps:
    sys.exit(0)

with open(path) as f:
    src = f.read()
new_src = src

for dep_name, exact_ver in deps.items():
    # Match .package(url: "...dep-name...", <from: "X" | upToNextMajor(from: "X") | ...>)
    # and replace the version constraint with exact: "pinned"
    pattern = re.compile(
        r'(\.package\s*\(\s*url:\s*"[^"]*' + re.escape(dep_name) + r'[^"]*"'
        r'\s*,\s*)(?:from:\s*"[^"]*"|\.upToNextMajor\(from:\s*"[^"]*"\)'
        r'|\.upToNextMinor\(from:\s*"[^"]*"\)|exact:\s*"[^"]*")',
        re.DOTALL,
    )
    replacement = r'\1exact: "' + exact_ver + '"'
    new_src, n = pattern.subn(replacement, new_src)
    if n:
        print(f"  pinned {dep_name} → {exact_ver} in {os.path.basename(path)}")
    else:
        print(f"  WARNING: no match for patchDeps '{dep_name}' in {os.path.basename(path)}", file=sys.stderr)

if new_src != src:
    with open(path, 'w') as f:
        f.write(new_src)
PYEOF
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 1e. After SPM resolves transitive deps, patch their Package*.swift files.
#     Scans both the local spm-cache AND global Xcode DerivedData checkouts —
#     xcodebuild -list (without -derivedDataPath) clones deps into global DerivedData
#     and reuses them during archive even when -clonedSourcePackagesDirPath is set.
# ──────────────────────────────────────────────────────────────────────────────
patch_spm_cache() {
    local checkouts_dir="$WORK_ROOT/spm-cache/checkouts"
    [ -d "$checkouts_dir" ] || return 0
    local count=0
    local checkout_pkg
    for checkout_pkg in "$checkouts_dir"/*/Package*.swift; do
        [ -f "$checkout_pkg" ] || continue
        # Ensure the file is writable before patching (spm-cache checkouts are often read-only)
        chmod u+w "$checkout_pkg" 2>/dev/null || true
        # strip_macos_only_deps equivalent inline
        if grep -qE 'swift-docc-plugin|swiftwasm/carton|swift-benchmark' "$checkout_pkg" 2>/dev/null; then
            python3 - "$checkout_pkg" <<'PYEOF' 2>/dev/null || true
import sys, re, os
path = sys.argv[1]
with open(path) as f: src = f.read()
dev_tools = re.compile(r'swift-docc-plugin|swiftwasm/carton|swift-benchmark')
if_re = re.compile(r'#if\b.*?#endif', re.DOTALL)
result = if_re.sub(lambda m: '' if dev_tools.search(m.group()) else m.group(), src)
result = re.sub(r'\s*\.package\(url:\s*"[^"]*(?:swift-docc-plugin|swiftwasm/carton|swift-benchmark)[^"]*"[^)]*\),?', '', result)
if result != src:
    with open(path, 'w') as f: f.write(result)
PYEOF
        fi
        # force_dynamic_products equivalent (force ALL library products for transitive deps)
        python3 - "$checkout_pkg" <<'PYEOF' 2>/dev/null || true
import sys, re, os
path = sys.argv[1]
with open(path) as f: src = f.read()
if not re.search(r'\.library', src): sys.exit(0)
result_parts = []
pos = 0
for m in re.compile(r'\.library\s*\(', re.DOTALL).finditer(src):
    result_parts.append(src[pos:m.end()])
    pos = m.end()
    depth = 1; i = pos
    while i < len(src) and depth > 0:
        if src[i] == '(': depth += 1
        elif src[i] == ')': depth -= 1
        i += 1
    body = src[pos:i-1]; closing = src[i-1:i]; pos = i
    if re.search(r'\btype\s*:', body):
        result_parts.append(body + closing)
    else:
        new_body = re.sub(r'(\btargets\s*:)', r'type: .dynamic, \1', body, count=1)
        result_parts.append(new_body + closing)
result_parts.append(src[pos:])
result = ''.join(result_parts)
if result != src:
    with open(path, 'w') as f: f.write(result)
PYEOF
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] && log "Patched $count Package*.swift files in spm-cache/checkouts"
    return 0
}
list_schemes() {
    # We only need scheme names — run xcodebuild -list without -clonedSourcePackagesDirPath
    # so SPM uses global DerivedData for resolution.  The spm-cache path is only needed
    # for the actual archive step (to ensure correct dep versions); for listing schemes it
    # causes hang/failure when workspace-state.json is stale or missing for this exact path.
    local raw err
    err="$(mktemp)"
    raw="$( cd "$SRC_DIR" && xcodebuild -list -json \
        -skipPackagePluginValidation \
        -skipMacroValidation 2>"$err" )" \
    || { warn "list_schemes: $(cat "$err" | grep 'error:' | head -2)"; raw=""; }
    rm -f "$err"
    echo "$raw" \
        | jq -r '((.workspace.schemes // []) + (.project.schemes // []))[]' 2>/dev/null \
        | awk 'NF && !seen[$0]++'
}

populate_spm_cache() {
    echo "[PROBE1] populate_spm_cache start" >&2
    # Populate spm-cache with all transitive deps for this package.
    local f
    for f in "$SRC_DIR"/*.xcworkspace "$SRC_DIR"/*.xcodeproj; do
        [ -e "$f" ] && mv "$f" "$f.disabled" 2>/dev/null
    done
    echo "[PROBE2] after xcodeproj disable" >&2
    rm -f  "$WORK_ROOT/spm-cache/workspace-state.json"
    rm -rf "$WORK_ROOT/spm-cache/repositories"
    echo "[PROBE3] before resolve" >&2
    ( cd "$SRC_DIR" && xcodebuild -resolvePackageDependencies \
        -clonedSourcePackagesDirPath "$WORK_ROOT/spm-cache" \
        -skipPackagePluginValidation \
        -skipMacroValidation 2>/dev/null ) || true
    echo "[PROBE4] after resolve" >&2
    echo "[PROBE4b] spm-cache contents: $(ls $WORK_ROOT/spm-cache/ 2>/dev/null | tr '
' ' ')" >&2
    echo "[PROBE4c] repositories: $(ls $WORK_ROOT/spm-cache/repositories/ 2>/dev/null | wc -l | tr -d ' ') items" >&2
    # Restore xcodeproj/xcworkspace after resolve (unless DISABLE_XCODEPROJ keeps it out)
    if [ "$DISABLE_XCODEPROJ" != true ]; then
        for f in "$SRC_DIR"/*.xcworkspace.disabled "$SRC_DIR"/*.xcodeproj.disabled; do
            [ -e "$f" ] && mv "$f" "${f%.disabled}" 2>/dev/null
        done
    fi
    echo "[PROBE5] populate_spm_cache done" >&2
}

detect_scheme() {
    [ -n "$SCHEME" ] && { ok "Using scheme (override): $SCHEME"; return 0; }

    # If DISABLE_XCODEPROJ is set, keep xcodeproj out for the rest of the build
    # (scheme detection AND archive). Required for packages whose xcodeproj causes
    # xcodebuild to bypass -clonedSourcePackagesDirPath and use global DerivedData
    # for transitive deps (e.g. SWCompression → BitByteData).

    local schemes; schemes="$(list_schemes || true)"

    # If no schemes found (xcodeproj absent or no shared schemes), try toggling:
    if [ -z "$schemes" ]; then
        if [ "$DISABLE_XCODEPROJ" = true ]; then
            # xcodeproj is disabled — try restoring it
            for f in "$SRC_DIR"/*.xcworkspace.disabled "$SRC_DIR"/*.xcodeproj.disabled; do
                [ -e "$f" ] && mv "$f" "${f%.disabled}" 2>/dev/null
            done
            warn "$NAME: Package.swift has no schemes; re-enabling committed Xcode project."
        else
            # xcodeproj is present — try disabling it
            local moved=0
            for f in "$SRC_DIR"/*.xcworkspace "$SRC_DIR"/*.xcodeproj; do
                [ -e "$f" ] || continue
                mv "$f" "$f.disabled" 2>/dev/null && moved=1
            done
            [ "$moved" = 1 ] && warn "$NAME: neutralized a committed Xcode project; using the SPM package."
        fi
        schemes="$(list_schemes || true)"
    fi
    [ -n "$schemes" ] || die "Could not list schemes for $NAME (xcodebuild -list failed)."

    # For single-product builds, prefer an exact-name scheme (e.g. "Metrics" over
    # "swift-metrics-Package") to avoid static/dynamic conflicts that arise when
    # the Package umbrella builds all products simultaneously and one product links
    # another product's target statically.
    if [ ${#PRODUCTS[@]} -eq 1 ]; then
        local exact_scheme
        exact_scheme="$(printf '%s\n' "$schemes" | grep -xF "${PRODUCTS[0]}" | head -1 || true)"
        if [ -n "$exact_scheme" ]; then SCHEME="$exact_scheme"; ok "Using scheme: $SCHEME"; return 0; fi
    fi

    # Multi-product umbrella scheme: build everything in one archive.
    local pkg_scheme
    pkg_scheme="$(printf '%s\n' "$schemes" | grep -E -- '-Package$' | head -1 || true)"
    if [ -n "$pkg_scheme" ]; then SCHEME="$pkg_scheme"; ok "Using scheme: $SCHEME"; return 0; fi

    # Drop non-library schemes (examples / demos / tests / host apps).
    local candidates
    candidates="$(printf '%s\n' "$schemes" \
        | grep -viE '(Tests?|TestFramework|TestUtils|TestHost|Showcase|Examples?|Demo|Sample|Benchmarks?|Snippets?|App)$' || true)"
    [ -n "$candidates" ] || candidates="$schemes"

    # Drop non-iOS platform variants when an iOS-capable scheme remains.
    local ios_only
    ios_only="$(printf '%s\n' "$candidates" | grep -viE '(macOS|watchOS|tvOS|visionOS|[ _-]Mac$)' || true)"
    [ -n "$ios_only" ] && candidates="$ios_only"

    # Prefer a scheme matching the primary product/module name.
    local primary="${PRODUCTS[0]}" prod_matches
    prod_matches="$(printf '%s\n' "$candidates" | grep -iF "$primary" || true)"
    [ -n "$prod_matches" ] && candidates="$prod_matches"

    # Prefer an iOS-flavoured scheme, then an exact identity match, then the first.
    local ios_scheme
    ios_scheme="$(printf '%s\n' "$candidates" | grep -iE '(^|[^a-z])iOS([^a-z]|$)' | head -1 || true)"
    if [ -n "$ios_scheme" ]; then
        SCHEME="$ios_scheme"
    elif printf '%s\n' "$candidates" | grep -qxF "$NAME"; then
        SCHEME="$NAME"
    else
        SCHEME="$(printf '%s\n' "$candidates" | head -1)"
    fi

    local total; total="$(printf '%s\n' "$schemes" | grep -c . || true)"
    [ "$total" -gt 1 ] && warn "$NAME schemes [$(printf '%s' "$schemes" | tr '\n' ' ')] → using '$SCHEME' (override with --scheme)."
    ok "Using scheme: $SCHEME"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Archive the scheme for one platform.
#    archive_slice <destination> <sdk-tag> -> sets ARCHIVE_PATH
# ──────────────────────────────────────────────────────────────────────────────
archive_slice() {
    local destination="$1" sdk="$2"
    local archive_path="$ARCHIVE_DIR/${sdk}.xcarchive"
    local logf="$ARCHIVE_DIR/${sdk}.log"
    local quiet_flag=(); $QUIET && quiet_flag=(-quiet)
    local evolution="YES"; [ "$LIBRARY_EVOLUTION" = true ] || evolution="NO"
    local swift_ver_flag=(); [ -n "$SWIFT_VERSION_OVERRIDE" ] && swift_ver_flag=("SWIFT_VERSION=$SWIFT_VERSION_OVERRIDE")
    local testability_flag=(); [ "$ENABLE_TESTABILITY" = true ] && testability_flag=("ENABLE_TESTABILITY=YES")
    # When noForceDynamic is set, omit MACH_O_TYPE — BUILD_LIBRARY_FOR_DISTRIBUTION alone
    # is sufficient for packages that already declare library products. Forcing mh_dylib on
    # packages with executables or complex internal targets causes duplicate-output errors.
    local mach_o_flag=(); [ "$NO_MACH_O_OVERRIDE" = false ] && mach_o_flag=("MACH_O_TYPE=mh_dylib")

    log "Archiving $sdk ($destination) ..."
    local clang_rt_flag=""
    if [ "$sdk" = "iphoneos" ] && [ -n "$CLANG_RT_IOS" ]; then
        clang_rt_flag="$CLANG_RT_IOS"
    elif [ "$sdk" = "iphonesimulator" ] && [ -n "$CLANG_RT_IOSSIM" ]; then
        clang_rt_flag="$CLANG_RT_IOSSIM"
    fi
    ( cd "$SRC_DIR" && xcodebuild archive \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination "$destination" \
        -archivePath "$archive_path" \
        -derivedDataPath "$DD_DIR" \
        -clonedSourcePackagesDirPath "$WORK_ROOT/spm-cache" \
        -skipMacroValidation \
        -skipPackagePluginValidation \
        ${quiet_flag[@]+"${quiet_flag[@]}"} \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION="$evolution" \
        ${mach_o_flag[@]+"${mach_o_flag[@]}"} \
        "OTHER_LDFLAGS=-lSystem${clang_rt_flag:+ $clang_rt_flag} -Xlinker -undefined -Xlinker dynamic_lookup" \
        IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" \
        ${swift_ver_flag[@]+"${swift_ver_flag[@]}"} \
        ${testability_flag[@]+"${testability_flag[@]}"} \
        > "$logf" 2>&1 ) || {
            err "archive failed: scheme=$SCHEME sdk=$sdk"
            echo -e "${DIM}---- error lines from $logf ----${NC}" >&2
            grep -E "error:|ARCHIVE FAILED|does not contain a scheme" "$logf" | head -20 >&2 || tail -30 "$logf" >&2
            return 1
        }
    ARCHIVE_PATH="$archive_path"
}

# ──────────────────────────────────────────────────────────────────────────────
# Locate <product>.framework and its dSYM inside an archive
# ──────────────────────────────────────────────────────────────────────────────
find_framework() { # find_framework <archive> <product>
    local archive="$1" product="$2" fw
    fw="$(find "$archive/Products/Library/Frameworks" -maxdepth 1 -type d -name "$product.framework" 2>/dev/null | head -1)"
    if [ -z "$fw" ]; then
        fw="$(find "$archive/Products" -type d -name "$product.framework" 2>/dev/null | head -1)"
    fi
    echo "$fw"
}
find_dsym() { # find_dsym <archive> <product>
    local archive="$1" product="$2"
    find "$archive/dSYMs" -maxdepth 1 -type d -name "$product.framework.dSYM" 2>/dev/null | head -1
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Re-seal each framework slice in an XCFramework with an ad-hoc signature.
#
#    xcodebuild -create-xcframework strips the binary .swiftmodule files from
#    framework bundles (keeping only the .swiftinterface text files for library
#    evolution) but does NOT update the code signature afterwards.  The
#    _CodeSignature/CodeResources hash still references the now-missing files,
#    so codesign -v reports "a sealed resource is missing or invalid" and Xcode
#    rejects the framework in any signed build.
#
#    codesign --force --sign - re-seals the bundle around the current set of
#    files, replacing the stale archive-time signature with a fresh ad-hoc one.
#    This is safe: Xcode re-signs everything with the app's own identity at
#    final link time; the ad-hoc seal here just satisfies the bundle integrity
#    check that Xcode performs before it gets to that point.
# ──────────────────────────────────────────────────────────────────────────────
resign_xcframework() { # resign_xcframework <xcfw_path> <product>
    local xcfw="$1" product="$2"
    local resigned=0 binary
    # Binaries live exactly 3 levels deep inside the XCFramework:
    #   <slice>/<product>.framework/<product>
    # Skip dSYM sub-trees which share the same depth pattern.
    while IFS= read -r binary; do
        if codesign --force --sign - "$binary" 2>/dev/null; then
            resigned=$((resigned + 1))
        else
            warn "codesign failed for $binary"
        fi
    done < <(find "$xcfw" -mindepth 3 -maxdepth 3 -type f -name "$product" -not -path "*/dSYMs/*")
    [ "$resigned" -gt 0 ] && ok "Re-signed $resigned slice(s) in $(basename "$xcfw")"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5-8. Assemble one product's XCFramework from the shared device/sim archives.
#      Uses globals IOS_ARCHIVE and SIM_ARCHIVE.
# ──────────────────────────────────────────────────────────────────────────────
build_product() { # build_product <product>
    local product="$1"
    echo ""
    log "── Packaging ${GREEN}$product${NC} ──"

    local ios_fw sim_fw
    ios_fw="$(find_framework "$IOS_ARCHIVE" "$product")"
    sim_fw="$(find_framework "$SIM_ARCHIVE" "$product")"
    [ -n "$ios_fw" ] || { err "device $product.framework not found in $IOS_ARCHIVE (is '$product' a product of $NAME?)"; return 1; }
    [ -n "$sim_fw" ] || { err "simulator $product.framework not found in $SIM_ARCHIVE"; return 1; }

    local -a create_args=(-framework "$ios_fw")
    if [ "$INCLUDE_DSYM" = true ]; then
        local ios_dsym; ios_dsym="$(find_dsym "$IOS_ARCHIVE" "$product")"
        [ -n "$ios_dsym" ] && create_args+=(-debug-symbols "$ios_dsym")
    fi
    create_args+=(-framework "$sim_fw")
    if [ "$INCLUDE_DSYM" = true ]; then
        local sim_dsym; sim_dsym="$(find_dsym "$SIM_ARCHIVE" "$product")"
        [ -n "$sim_dsym" ] && create_args+=(-debug-symbols "$sim_dsym")
    fi

    local out_xcfw="$DEST_DIR/$product.xcframework"
    rm -rf "$out_xcfw"
    xcodebuild -create-xcframework "${create_args[@]}" -output "$out_xcfw" >/dev/null \
        || { err "create-xcframework failed for $product"; return 1; }
    ok "Created $out_xcfw"

    # Re-seal framework bundles after xcodebuild strips binary .swiftmodule files.
    resign_xcframework "$out_xcfw" "$product"

    local checksum="" zip_name=""
    if [ "$MAKE_ZIP" = true ]; then
        zip_name="$product.xcframework.zip"
        ( cd "$DEST_DIR" && rm -f "$zip_name" && zip -ryq "$zip_name" "$product.xcframework" )
        checksum="$(swift package compute-checksum "$DEST_DIR/$zip_name")"
        ok "Zipped + checksum ${DIM}$checksum${NC}"
    fi

    update_manifest "$product" "$checksum" "$zip_name"
}

# ──────────────────────────────────────────────────────────────────────────────
# Manifest registry (XCFrameworks/xcframeworks-manifest.json)
# ──────────────────────────────────────────────────────────────────────────────
update_manifest() { # update_manifest <product> <checksum> <zip_name>
    local product="$1" checksum="$2" zip_name="$3"
    local manifest="$OUTPUT_DIR/xcframeworks-manifest.json"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local rel="$NAME/$VERSION/$product.xcframework"
    local rel_zip=""; [ -n "$zip_name" ] && rel_zip="$NAME/$VERSION/$zip_name"

    [ -s "$manifest" ] || echo '{"packages":{}}' > "$manifest"

    local tmp; tmp="$(mktemp)"
    jq \
        --arg name "$NAME" --arg version "$VERSION" --arg url "$URL" \
        --arg revision "${EXPECT_REVISION:-}" --arg xcode "$XCODE_VERSION" \
        --arg product "$product" --arg path "$rel" --arg zip "$rel_zip" \
        --arg checksum "$checksum" --arg now "$now" '
        .generatedAt = $now
        | .packages[$name].version = $version
        | .packages[$name].url = $url
        | .packages[$name].revision = $revision
        | .packages[$name].builtAt = $now
        | .packages[$name].xcodeVersion = $xcode
        | .packages[$name].products[$product] = ({ path: $path }
            + (if $zip      != "" then { zip: $zip }           else {} end)
            + (if $checksum != "" then { checksum: $checksum } else {} end))
        ' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
}

# ──────────────────────────────────────────────────────────────────────────────
# Run
# ──────────────────────────────────────────────────────────────────────────────
clone_source
populate_spm_cache
echo "[PROBE] after populate_spm_cache, SCHEME=$SCHEME" >&2
detect_scheme
# patch_spm_cache is only needed for packages with xcodeproj disabled (e.g. SWCompression),
# where transitive deps must be resolved into spm-cache and built as dynamic.
# For all other packages it is harmful (forces unneeded dynamic products on transitive deps).
[ "$DISABLE_XCODEPROJ" = true ] && patch_spm_cache
echo "[PROBE6] workspace-state before archive: $(ls $WORK_ROOT/spm-cache/workspace-state.json 2>/dev/null && echo EXISTS || echo MISSING)" >&2
echo "[PROBE7] checkouts: $(ls $WORK_ROOT/spm-cache/checkouts/ 2>/dev/null | wc -l | tr -d ' ') packages" >&2

archive_slice "generic/platform=iOS"           "iphoneos"        || die "$NAME: device archive failed."
IOS_ARCHIVE="$ARCHIVE_PATH"
archive_slice "generic/platform=iOS Simulator" "iphonesimulator" || die "$NAME: simulator archive failed."
SIM_ARCHIVE="$ARCHIVE_PATH"

FAILED=()
for product in "${PRODUCTS[@]}"; do
    if ! build_product "$product"; then
        FAILED+=("$product")
    fi
done

echo ""
if [ ${#FAILED[@]} -ne 0 ]; then
    err "$NAME: ${#FAILED[@]}/${#PRODUCTS[@]} product(s) failed: ${FAILED[*]}"
    exit 1
fi
ok "$NAME @ $VERSION — built ${#PRODUCTS[@]} product(s) into $DEST_DIR"
