# XCFramework Builder — APP-6792

Converts external Swift Package Manager dependencies into pre-compiled binary XCFrameworks for the rapid-ios-app project.

All output is **local only** — nothing is uploaded or committed.

---

## Folder structure

```
xcframework-builder/
  build-groups.sh            # ⭐ recommended: one tuned function per group
  build-xcframework.sh       # per-package builder (engine)
  build-all-xcframeworks.sh  # generic batch driver (one loop for every package)
  xcframeworks.config.json   # source of truth: all package pins + per-package tweaks
  README.md                  # this file
  XCFrameworks/              # output (created at runtime)
    <Package>/<version>/<Product>.xcframework
    xcframeworks-manifest.json
```

There are three entry points:

| Script | Use it when |
|---|---|
| **`build-groups.sh`** | You want a whole group built with all its per-package tweaks already applied. **This is the recommended path** and is verified end-to-end for every non-aws group. |
| `build-xcframework.sh` | You want to build a single package (it's the engine the other two call). |
| `build-all-xcframeworks.sh` | You want the original generic batch loop with `--only` / `--from` / `--skip-complex` selection across all groups. |

---

## Quick start

```bash
cd ~/Desktop/xcframework-builder

# ⭐ Build a whole group with all its tweaks applied (recommended)
./build-groups.sh okta --no-zip

# Build every non-aws group in dependency order
./build-groups.sh all --no-zip

# Build a single package
./build-xcframework.sh LRUCache --no-zip

# See which groups build-groups.sh handles
./build-groups.sh --list
```

> **iOS-only XCFrameworks.** Each build produces `ios-arm64` (device) + `ios-arm64_x86_64-simulator` slices.
> Requires Xcode (verified on **Xcode 16.4**), plus `jq` (`brew install jq`).

---

## `build-groups.sh` — recommended group builder ⭐

One self-contained `build_<group>()` function per group, each pre-wired with the exact
products, schemes, and flags that group needs. Unlike the generic `build-all` loop, the
per-group quirks live in one obvious place — so a group "just works" without you having to
remember per-package options.

**The `aws` group is opt-in** — `aws-crt-swift` compiles a native C runtime that the rest of
the group sits on top of, so `aws` is excluded from `all` and must be requested explicitly
(`./build-groups.sh aws`).

### Syntax

```bash
./build-groups.sh <group> [<group> ...]    # build one or more groups
./build-groups.sh all                      # build every non-aws group, in order
./build-groups.sh aws                      # build the aws group (opt-in; not in 'all')
./build-groups.sh --list                   # list the groups and exit
```

Groups: `shared-infra` `firebase` `pointfree` `segment` `okta` `easy-wins` `aws`

### Options

| Flag | Description |
|---|---|
| `--dry-run` | Print each package build command without running it |
| `--stop-on-error` | Abort a group at its first failing package (default: continue) |
| `--no-zip` | Skip `.zip` + checksum (faster; use during testing) |
| `--keep-sources` | Keep temp clone dirs (debugging) |
| `--no-dsym` | Exclude dSYM debug symbols |
| `--output-dir <dir>` | Override output root (default: `./XCFrameworks`) |
| `--min-ios <ver>` | iOS deployment target (default: `17.0`) |
| `-q / --quiet` | Quieter xcodebuild output |

At the end it prints a per-run summary of **Succeeded / Skipped / Failed** packages.

### Examples

```bash
# Each group on its own
./build-groups.sh shared-infra --no-zip
./build-groups.sh firebase     --no-zip
./build-groups.sh pointfree    --no-zip
./build-groups.sh segment      --no-zip
./build-groups.sh okta         --no-zip
./build-groups.sh easy-wins    --no-zip
./build-groups.sh aws          --no-zip

# Several groups at once, in dependency order
./build-groups.sh shared-infra pointfree segment okta easy-wins --no-zip

# Everything (non-aws), production artifacts with zip + checksum
./build-groups.sh all

# Preview without building
./build-groups.sh all --dry-run
```

### Verified status (Xcode 16.4)

| Group | Result | Notes |
|---|---|---|
| `shared-infra` | 24/24 ✅ | `opentelemetry-swift` is an explicit skip (needs source work) |
| `firebase` | 7/7 ✅ | correct product names + per-product isolation applied automatically |
| `pointfree` | 4/4 ✅ | |
| `segment` | 3/3 ✅ | |
| `okta` | 4/4 ✅ | `swift-crypto` is an explicit skip (needs source work) |
| `easy-wins` | 13/13 ✅ | |
| `aws` | 7/7 ✅ | opt-in (not in `all`); submodules + per-package tweaks applied automatically |

Two packages are deliberately skipped (printed as `skipping …` in the run summary) because
they need source-level changes: **`swift-crypto`** (static-vs-dynamic `Crypto` conflict) and
**`opentelemetry-swift`** (multi-product). Everything else in the non-aws groups builds.

---

## `build-xcframework.sh` — single package

Clones the package at its pinned tag, archives for `iphoneos` + `iphonesimulator`, then merges into an `.xcframework`.

### Syntax

```bash
./build-xcframework.sh <package-name> [version] [repo-url] [product ...] [options]
```

All fields fall back to `xcframeworks.config.json` when not supplied on the command line.

### Options

| Flag | Description |
|---|---|
| `--no-zip` | Skip `.zip` + checksum (faster, use during testing) |
| `--keep-sources` | Don't delete the temp clone dir (useful when debugging a failure) |
| `--scheme <name>` | Force a specific Xcode scheme instead of auto-detection |
| `--no-library-evolution` | Build without `BUILD_LIBRARY_FOR_DISTRIBUTION` (needed by a few packages with broken `.swiftinterface`) |
| `--output-dir <dir>` | Override the output root (default: `./XCFrameworks`) |
| `--min-ios <ver>` | iOS deployment target (default: `17.0`) |
| `--no-dsym` | Exclude dSYM debug symbols from the xcframework |
| `--submodules` | Init git submodules after clone (for packages whose native sources live in submodules, e.g. `aws-crt-swift`) |
| `-q / --quiet` | Reduce xcodebuild output verbosity |
| `--config <file>` | Use a different config file |

### Config-only per-package tweaks

Some tweaks have no CLI flag and are set per package in `xcframeworks.config.json`. The engine
reads them automatically (this is how `build-groups.sh` gets group packages to build):

| Config key | Effect |
|---|---|
| `scheme` | Force a specific Xcode scheme |
| `noLibraryEvolution` | Build without `BUILD_LIBRARY_FOR_DISTRIBUTION` |
| `noForceDynamic` | Don't force library products to `.dynamic` |
| `explicitProducts` | Replace a computed `products:` array (variable, array literal, or expression such as `runtimeProducts + serviceTargets.map(...)`) with explicit `.dynamic` libraries (drops executables/extra products) |
| `noMachOOverride` | Don't force `MACH_O_TYPE=mh_dylib` |
| `enableTestability` | Archive with `ENABLE_TESTABILITY=YES` |
| `swiftVersion` | Set `SWIFT_VERSION` build setting |
| `noToolsDowngrade` | Skip the automatic `swift-tools-version 6 → 5.10` manifest downgrade (for manifests that need swift-tools-6 APIs such as `.swiftLanguageMode`) |
| `submodules` | Run `git submodule update --init --recursive` after clone (for packages whose native sources live in submodules, e.g. `aws-crt-swift`'s `aws-common-runtime/aws-c-*` C libraries) |
| `noStripDevTools` | Skip stripping `swift-docc-plugin` / dev-tool deps (for manifests where they're already env-gated via `dependencies.append(.package(...))` or `return .package(...)`, which the strip regex would corrupt) |
| `patchDeps` | Pin a dependency to an exact version (key is matched against the dependency URL — use a specific suffix like `swift-nio.git` to avoid matching siblings such as `swift-nio-ssl`) |

### Examples

```bash
# Basic — resolves everything from config
./build-xcframework.sh LRUCache --no-zip

# Explicit version + URL
./build-xcframework.sh Sentry 9.8.0 https://github.com/getsentry/sentry-cocoa --no-zip

# Keep build dir to inspect a failure
./build-xcframework.sh CombineExt --keep-sources --no-zip

# Force a scheme
./build-xcframework.sh XCGLogger --scheme "XCGLogger (iOS)" --no-zip

# Package whose .swiftinterface fails to compile
./build-xcframework.sh JSONAny --no-library-evolution --no-zip
```

---

## `build-all-xcframeworks.sh` — batch driver

Runs `build-xcframework.sh` for multiple packages in dependency order.

### Options

| Flag | Description |
|---|---|
| `--group <name>` | Only build packages in that group (see groups below) |
| `--only <pkg1,pkg2>` | Build only the named packages |
| `--from <pkg>` | Skip all packages ordered before `<pkg>` (resume after a failure) |
| `--skip-complex` | Skip packages flagged `complex` in the config |
| `--list` | Print the build plan and exit — no building |
| `--dry-run` | Print each command without executing it |
| `--stop-on-error` | Halt on the first failure (default: continue) |
| `--no-zip` | Pass-through: skip zip for all packages |
| `--keep-sources` | Pass-through: keep temp dirs |
| `-q / --quiet` | Pass-through: quieter output |

### Examples

```bash
# Preview everything that would run
./build-all-xcframeworks.sh --list

# Dry run (print commands, no builds)
./build-all-xcframeworks.sh --dry-run

# Build a specific group
./build-all-xcframeworks.sh --group easy-wins --skip-complex --no-zip
./build-all-xcframeworks.sh --group pointfree --no-zip
./build-all-xcframeworks.sh --group okta --no-zip
./build-all-xcframeworks.sh --group segment --no-zip
./build-all-xcframeworks.sh --group shared-infra --skip-complex --no-zip

# Build just two specific packages
./build-all-xcframeworks.sh --only swift-log,swift-metrics --no-zip

# Resume after a failure at SWCompression
./build-all-xcframeworks.sh --from SWCompression --no-zip

# Build everything non-complex across all groups
./build-all-xcframeworks.sh --skip-complex --no-zip

# Stop immediately on the first failure
./build-all-xcframeworks.sh --group easy-wins --stop-on-error --no-zip
```

---

## Groups and what they build

Packages are built in dependency order across 7 groups. Lower groups must be built first if their products are needed by packages in later groups.

### `shared-infra` (25 packages)

Foundation-level packages: logging, networking, async primitives, protobuf, gRPC.

| # | Package | Products | Complex |
|---|---|---|---|
| 1 | swift-log | `Logging` | |
| 2 | swift-metrics | `CoreMetrics` | |
| 3 | swift-service-context | `ServiceContextModule` | |
| 4 | swift-atomics | `Atomics` | |
| 5 | swift-numerics | `Numerics` | |
| 6 | swift-http-types | `HTTPTypes` | |
| 7 | swift-http-structured-headers | `StructuredFieldValues` | ⚠️ |
| 8 | swift-system | `SystemPackage` | |
| 9 | SwiftProtobuf | `SwiftProtobuf` | |
| 10 | swift-collections | `OrderedCollections` | |
| 11 | swift-algorithms | `Algorithms` | |
| 12 | swift-async-algorithms | `AsyncAlgorithms` | |
| 13 | swift-nio | `NIOCore, NIO, NIOEmbedded, NIOPosix, NIOHTTP1` | ⚠️ |
| 14 | swift-nio-ssl | `NIOSSL` | |
| 15 | swift-nio-http2 | `NIOHTTP2` | |
| 16 | swift-nio-extras | `NIOExtras` | |
| 17 | swift-nio-transport-services | `NIOTransportServices` | |
| 18 | swift-distributed-tracing | `Tracing` | |
| 19 | swift-service-lifecycle | `ServiceLifecycle` | |
| 20 | async-http-client | `AsyncHTTPClient` | |
| 21 | grpc-swift | `GRPC` | ⚠️ |
| 22 | Opentracing | `Opentracing` | |
| 23 | Thrift | `Thrift` | |
| 24 | opentelemetry-swift | `OpenTelemetryApi, OpenTelemetrySdk` | ⚠️ |
| 25 | swift-log-file | `FileLogging` | |

```bash
./build-groups.sh shared-infra --no-zip
```

---

### `firebase` (7 packages)

Firebase SDK and its Google dependencies, in dependency order.

| # | Package | Products built | Notes |
|---|---|---|---|
| 26 | Promises | `FBLPromises` | ObjC product (not the Swift `Promises`) |
| 27 | InteropForGoogle | `RecaptchaInterop` | real product name (no `GoogleInterop`) |
| 28 | GTMSessionFetcher | `GTMSessionFetcher` | |
| 29 | GoogleUtilities | `GULAppDelegateSwizzler, GULEnvironment, GULLogger, GULMethodSwizzler, GULNetwork, GULNSData, GULReachability, GULUserDefaults` | each built in its **own** archive |
| 30 | GoogleDataTransport | `GoogleDataTransport` | |
| 31 | AppCheck | `AppCheckCore` | real product name (no `FirebaseAppCheck`) |
| 32 | Firebase | `FirebaseCore, FirebaseMessaging, FirebaseInstallations` | each built in its **own** archive |

`build-groups.sh` handles the Firebase quirks for you: it uses the correct product names and
builds GoogleUtilities' sub-products and the Firebase umbrella products **one per archive**
(building them together yields empty alias frameworks / static-vs-dynamic conflicts).

```bash
./build-groups.sh firebase --no-zip
```

---

### `aws` (5 packages)

AWS SDK, Amplify, and Cognito auth plugin.

> **Opt-in in `build-groups.sh` (verified 7/7 on Xcode 16.4).** `aws-crt-swift` keeps its
> native `aws-c-*` C libraries in **git submodules** (`submodules: true` checks them out)
> and its `.swiftinterface` can't see those private C modules under library evolution, so the
> whole group builds with `--no-library-evolution`. `smithy-swift` / `aws-sdk-swift` have an
> env-gated `swift-docc-plugin` dep (`noStripDevTools: true` keeps the strip regex from
> corrupting it); `aws-sdk-swift`'s products are computed, so `explicitProducts: true` injects
> a dynamic `AWSClientRuntime`. The umbrella `Amplify` products are built one-per-archive
> (like Firebase) to avoid static/dynamic conflicts on the shared core. Because of the native
> runtime the `aws` group is **excluded from `all`** and must be requested explicitly.

| # | Package | Products | Complex |
|---|---|---|---|
| 33 | aws-crt-swift | `AwsCommonRuntimeKit` | ⚠️ |
| 34 | smithy-swift | `ClientRuntime` | ⚠️ |
| 35 | aws-sdk-swift | `AWSClientRuntime` | ⚠️ |
| 36 | AmplifyUtilsNotifications | `AmplifyUtilsNotifications` | |
| 37 | Amplify | `Amplify, AWSCognitoAuthPlugin, AWSAPIPlugin` | ⚠️ |

```bash
# Recommended: per-group builder (handles ordering + Amplify one-per-archive)
./build-groups.sh aws --no-zip

# Alternative: generic batch driver
./build-all-xcframeworks.sh --group aws --no-zip
```

---

### `pointfree` (4 packages)

Point-Free utilities: dependency injection, testing, concurrency, clocks.

| # | Package | Products | Complex |
|---|---|---|---|
| 38 | xctest-dynamic-overlay | `IssueReporting` | |
| 39 | swift-concurrency-extras | `ConcurrencyExtras` | |
| 40 | combine-schedulers | `CombineSchedulers` | |
| 41 | swift-clocks | `Clocks` | |

```bash
./build-groups.sh pointfree --no-zip
```

---

### `segment` (3 packages)

Segment analytics SDK and its dependencies.

| # | Package | Products | Complex |
|---|---|---|---|
| 42 | Sovran | `Sovran` | |
| 43 | JSONSafeEncoding | `JSONSafeEncoding` | |
| 44 | Segment | `Segment` | |

```bash
./build-groups.sh segment --no-zip
```

---

### `okta` (5 packages)

Okta authentication SDK: ASN.1, crypto, X.509, auth foundation, IDX flow.

| # | Package | Products | Notes |
|---|---|---|---|
| 45 | swift-asn1 | `SwiftASN1` | |
| 46 | swift-crypto | `Crypto` | ⚠️ skipped — static/dynamic `Crypto` conflict (needs source work) |
| 47 | swift-certificates | `X509` | |
| 48 | AuthFoundation | `AuthFoundation` | |
| 49 | OktaIdx | `OktaIdx` | |

```bash
./build-groups.sh okta --no-zip
```

---

### `easy-wins` (13 packages)

Miscellaneous packages with no inter-group dependencies.

| # | Package | Products | Status |
|---|---|---|---|
| 50 | GrowthBook-IOS | `GrowthBook` | ✅ Built |
| 51 | Sentry | `Sentry` | ✅ Built |
| 52 | SimpleKeychain | `SimpleKeychain` | ✅ Built |
| 53 | LRUCache | `LRUCache` | ✅ Built |
| 54 | swiftui-introspect | `SwiftUIIntrospect` | ✅ Built |
| 55 | CombineExt | `CombineExt` | ✅ Built |
| 56 | JSONAny | `JSONAny` | ✅ Built |
| 57 | XCGLogger | `XCGLogger` | ✅ Built |
| 58 | SQLite.swift | `SQLite` | ✅ Built |
| 59 | BitByteData | `BitByteData` | ✅ Built |
| 60 | SWCompression | `SWCompression` | ✅ Built |
| 61 | PriorsSchema | `PriorsSchema` | ✅ Built |
| 62 | CombineExpectations | `CombineExpectations` | ✅ Built (test-support) |

```bash
# All 13 build via build-groups.sh
./build-groups.sh easy-wins --no-zip
```

---

## Recommended build order

Build groups in dependency order. The easiest path uses `build-groups.sh`:

```bash
# Everything except aws, in the right order, with zip + checksum
./build-groups.sh all
```

Or one group at a time (same order `all` uses):

```bash
# 1. Foundation layer
./build-groups.sh shared-infra --no-zip

# 2. Firebase (built bottom-up internally)
./build-groups.sh firebase --no-zip

# 3. Auth / analytics
./build-groups.sh pointfree --no-zip
./build-groups.sh segment   --no-zip
./build-groups.sh okta      --no-zip

# 4. Miscellaneous
./build-groups.sh easy-wins --no-zip
```

The **aws** group is opt-in (not part of `all`) because `aws-crt-swift` compiles a native C
runtime the rest of the group sits on. Build it explicitly after the foundation layer:

```bash
./build-groups.sh aws --no-zip

# or, with the generic batch driver
./build-all-xcframeworks.sh --group aws --no-zip
```

---

## Output

```
XCFrameworks/
  <Package>/<version>/<Product>.xcframework    ← import in Xcode / Package.swift
  <Package>/<version>/<Product>.xcframework.zip  ← for SPM .binaryTarget(checksum:)
  xcframeworks-manifest.json                   ← registry of all built frameworks
```

The manifest records the path, zip, checksum, Xcode version, and build timestamp for every product.

---

## Flags legend

| Flag | Meaning |
|---|---|
| ⚠️ | Needs per-package tweaks to build — applied automatically by `build-groups.sh` (see the `note` / tweak fields in `xcframeworks.config.json`), or skipped where it needs source-level work |
| ✅ Built | Verified working on Xcode 16.4 |
| T | Test-only package — produces no shippable framework |
