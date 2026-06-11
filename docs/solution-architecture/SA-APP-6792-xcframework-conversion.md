---
title: "SA: XCFramework Conversion of External SPM Packages"
jira: APP-6792
confluence: https://ischemaview.atlassian.net/wiki/spaces/SOFTWARE/pages/4575428611/SA+XCFramework+Conversion+of+External+SPM+Packages
confluence_sync:
  last_synced: "2026-06-10T20:31:47Z"
  repo: ""
  sha: ""
  parent_page: "2993225740"
created: 2026-06-10
status: draft
---

# SA: XCFramework Conversion of External SPM Packages

## Overview

The `rapid-ios-app` project depends on a large set of external Swift Package
Manager (SPM) packages that are compiled from source on every clean build and
in CI. Building these third-party dependencies from source on each run is a
significant, recurring cost: it inflates clean-build and CI times, makes builds
sensitive to upstream toolchain/source changes, and couples local developer
productivity to the compilation of code the team does not own.

This SA describes a tool — the **XCFramework Builder** (this repository) — that
converts pinned external SPM dependencies into pre-compiled, distributable
binary **XCFrameworks**. The XCFrameworks can then be referenced as
`.binaryTarget` artifacts instead of source packages, so the app no longer
recompiles unchanged third-party code.

The conversion inventory is derived from the resolved package graph
(`RapidPlatform.xcworkspace/xcshareddata/swiftpm/Package.resolved`) and captured
in `xcframeworks.config.json`, which is the single source of truth for version
pins, git revisions, product lists, and per-package build tweaks.

All output is **local only** — nothing is uploaded or committed by the tooling.

## Goals & Non-Goals

### Goals

- Convert pinned external SPM packages into pre-compiled iOS XCFrameworks
  (`ios-arm64` device slice + `ios-arm64_x86_64-simulator` slice).
- Maintain a single source of truth (`xcframeworks.config.json`) for every
  package's pinned version, git revision, products, and build tweaks.
- Provide a repeatable, scriptable build path that captures per-package and
  per-group quirks so a build "just works" without tribal knowledge.
- Produce SPM-consumable artifacts: each product as `<Product>.xcframework`,
  plus an optional `.zip` + SwiftPM checksum for `.binaryTarget(checksum:)`.
- Emit a manifest (`xcframeworks-manifest.json`) recording path, zip, checksum,
  Xcode version, and build timestamp for every built product.
- Build dependencies in correct dependency order across the 7 groups.

### Non-Goals

- **No remote distribution.** The tooling does not upload, host, or commit
  artifacts; storage is local to the builder directory.
- **No non-iOS platforms.** Output is iOS-only (device + simulator); macOS,
  tvOS, watchOS, and visionOS slices are out of scope.
- **Not a replacement for SPM resolution.** The app still resolves and pins
  versions through `Package.resolved`; this tool consumes those pins.
- **No conversion of packages flagged `cannot-convert`** (e.g. build-tool /
  macro / executable packages such as `swift-syntax`, `swift-argument-parser`).
- **No re-conversion of packages that already ship as binaries**
  (`already-binary` group, e.g. `gRPC`, `GoogleAppMeasurement`, `Intercom`).

## Proposed Solution

A set of three Bash entry points wrapping one build engine, all driven by a
shared JSON config:

| Component | Role |
|---|---|
| `xcframeworks.config.json` | Source of truth: package pins (version, tag, revision), products, group, ordering, and per-package tweaks. Generated from `Package.resolved`. |
| `build-xcframework.sh` | The **engine**: builds a single package into an XCFramework. Resolves missing fields from the config. |
| `build-groups.sh` | **Recommended** driver: one self-contained `build_<group>()` function per dependency group, pre-wired with that group's exact products, schemes, and flags. |
| `build-all-xcframeworks.sh` | Generic batch driver: one loop over every convertible package with `--only` / `--from` / `--group` / `--skip-complex` selection. |

The packages are partitioned into **7 buildable groups** built in dependency
order: `shared-infra` → `firebase` → `aws` → `pointfree` → `segment` → `okta`
→ `easy-wins`. Two further config categories — `already-binary` and
`cannot-convert` — are inventoried but intentionally not built.

## Technical Design

### Build pipeline (per product/scheme)

The engine (`build-xcframework.sh`) executes the following pipeline for each
product:

1. **Clone** the package source at its pinned git tag into a temp directory.
2. **Resolve** the scheme(s)/product(s) to build from CLI args, then config,
   then the package name.
3. **Archive** twice with `xcodebuild archive` — once for `iphoneos` and once
   for `iphonesimulator` — with `BUILD_LIBRARY_FOR_DISTRIBUTION` enabled
   (module stability) unless the package opts out.
4. **Merge** the two slices with `xcodebuild -create-xcframework`.
5. **Write** `<Product>.xcframework` to
   `XCFrameworks/<Package>/<version>/`.
6. **Zip** the bundle and compute its SwiftPM checksum (unless `--no-zip`).
7. **Upsert** `XCFrameworks/xcframeworks-manifest.json`.

### Configuration & per-package tweaks

Most third-party packages do not archive cleanly as dynamic, distribution-ready
frameworks without adjustment. Rather than fork upstream sources, the engine
reads per-package tweaks from `xcframeworks.config.json`. Visible tweaks are
expressed by `build-groups.sh` as explicit CLI flags; deeper knobs are read
directly from the config entry:

| Config key | Effect |
|---|---|
| `scheme` | Force a specific Xcode scheme instead of auto-detection. |
| `noLibraryEvolution` | Build without `BUILD_LIBRARY_FOR_DISTRIBUTION` (for broken `.swiftinterface`). |
| `noForceDynamic` | Don't force library products to `.dynamic`. |
| `explicitProducts` | Replace computed products with explicit `.dynamic` libraries (drops executables). |
| `noMachOOverride` | Don't force `MACH_O_TYPE=mh_dylib`. |
| `enableTestability` | Archive with `ENABLE_TESTABILITY=YES`. |
| `swiftVersion` | Set the `SWIFT_VERSION` build setting. |
| `noToolsDowngrade` | Skip the automatic `swift-tools-version 6 → 5.10` manifest downgrade. |
| `patchDeps` | Pin a transitive dependency to an exact version (matched by URL suffix). |

### Group design

`build-groups.sh` keeps each group's quirks in one obvious place via a dedicated
`build_<group>()` function, rather than smearing toggles across the config:

- **`shared-infra` (25 pkgs)** — foundation: logging, networking (SwiftNIO
  stack), async primitives, protobuf, gRPC. `opentelemetry-swift` is an
  explicit skip (multi-product, needs source work).
- **`firebase` (7 pkgs)** — uses correct ObjC/real product names and builds
  GoogleUtilities sub-products and Firebase umbrella products **one per archive**
  (building together yields empty alias frameworks / static-vs-dynamic conflicts).
- **`aws` (5 pkgs)** — **opt-in, excluded from `all`**: `aws-crt-swift`
  compiles a native C runtime the rest of the group sits on; `Amplify` umbrella
  products are built one-per-archive.
- **`pointfree` (4 pkgs)**, **`segment` (3 pkgs)** — straightforward utilities.
- **`okta` (5 pkgs)** — auth stack; `swift-crypto` is an explicit skip
  (static-vs-dynamic `Crypto` conflict, needs source work).
- **`easy-wins` (13 pkgs)** — independent packages with no inter-group deps; all
  verified building.

### Output layout & consumption

```
XCFrameworks/
  <Package>/<version>/<Product>.xcframework        ← import in Xcode / Package.swift
  <Package>/<version>/<Product>.xcframework.zip    ← for SPM .binaryTarget(checksum:)
  xcframeworks-manifest.json                       ← registry of all built products
```

Consumers reference a product from a `Package.swift` wrapper via
`.binaryTarget(name:, path:)` (local) or `.binaryTarget(name:, url:, checksum:)`
(zip + checksum from the manifest).

### Verified status (Xcode 16.4)

| Group | Result | Notes |
|---|---|---|
| `shared-infra` | 24/24 ✅ | `opentelemetry-swift` explicitly skipped |
| `firebase` | 7/7 ✅ | per-product isolation applied automatically |
| `pointfree` | 4/4 ✅ | |
| `segment` | 3/3 ✅ | |
| `okta` | 4/4 ✅ | `swift-crypto` explicitly skipped |
| `easy-wins` | 13/13 ✅ | |

## Alternatives Considered

| Alternative | Why not chosen |
|---|---|
| **Keep building all deps from source** | The status quo; the recurring clean-build/CI compile cost of third-party code is exactly the problem this work addresses. |
| **Pre-built binaries hosted in a remote artifact registry** | Larger scope (hosting, auth, cache invalidation). This SA deliberately keeps output local-only; remote distribution can layer on later using the manifest + checksums already produced. |
| **Fork upstream packages to make them archive cleanly** | High maintenance burden and drift from upstream. Instead, per-package tweaks (`xcframeworks.config.json`) adjust build settings without source forks. |
| **Single monolithic build script** | Per-package quirks would be smeared across one loop. `build-groups.sh` localizes quirks into one `build_<group>()` function per group for clarity and reliability. |
| **Convert every dependency** | Some packages are build-tool/macro/executable (`cannot-convert`) or already ship as binaries (`already-binary`); converting them adds no value or is infeasible. |

## Dependencies

- **Xcode** — verified on Xcode 16.4 (`xcodebuild archive` /
  `-create-xcframework`).
- **`jq`** — JSON parsing of the config (`brew install jq`).
- **`xcframeworks.config.json`** — generated from the app's
  `Package.resolved`; must be regenerated when pins change.
- **Upstream git repositories** — each package is cloned at its pinned
  tag/revision at build time.
- **`aws-crt-swift` native C toolchain prerequisites** — required only for the
  opt-in `aws` group.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Upstream tag/source changes break a build | A package stops archiving | Pins include exact `revision`; engine warns when a cloned tag resolves to a different commit. |
| Static-vs-dynamic / multi-product conflicts | Empty alias frameworks or link errors | Group functions build umbrella products one-per-archive; `noForceDynamic`/`explicitProducts`/`noMachOOverride` tweaks per package. |
| Broken `.swiftinterface` with library evolution | Archive fails to compile | `noLibraryEvolution` per package (loses module stability for that product). |
| `swift-tools-version 6` manifests | Resolution/build failures on older toolchains | Automatic `6 → 5.10` manifest downgrade, with `noToolsDowngrade` escape hatch. |
| Two packages need source-level work | `swift-crypto`, `opentelemetry-swift` not yet converted | Explicitly skipped and surfaced in the run summary; tracked as follow-up tasks. |
| `aws` native C runtime build complexity | `aws` group may not build in all environments | Kept opt-in and excluded from `all`; documented toolchain prerequisites. |
| Xcode version drift | Build settings/flags may change | Manifest records the Xcode version per artifact; "verified on 16.4" documented. |

## Work Breakdown

| # | Task | Jira | Size | Assignee | Dependencies |
|---|------|------|------|----------|--------------|
| 1 | Generate conversion inventory (`xcframeworks.config.json`) from `Package.resolved` | APP-6792 | M | dylanong-rapid | - |
| 2 | Implement single-package engine (`build-xcframework.sh`): clone → archive → create-xcframework → zip/checksum → manifest | APP-6792 | L | dylanong-rapid | #1 |
| 3 | Implement per-package tweak handling (library-evolution, mach-o, force-dynamic, explicit products, tools downgrade, patchDeps) | APP-6792 | M | dylanong-rapid | #2 |
| 4 | Implement generic batch driver (`build-all-xcframeworks.sh`) with group/only/from/skip-complex selection | APP-6792 | M | dylanong-rapid | #2 |
| 5 | Implement recommended per-group builder (`build-groups.sh`) with one `build_<group>()` per group | APP-6792 | L | dylanong-rapid | #2, #3 |
| 6 | Verify & tune non-aws groups end-to-end on Xcode 16.4 | APP-6792 | L | dylanong-rapid | #5 |
| 7 | Verify opt-in `aws` group (native C runtime prerequisites) | To create | L | dylanong-rapid | #5 |
| 8 | Resolve source-level skips: `swift-crypto` (static/dynamic) and `opentelemetry-swift` (multi-product) | To create | L | dylanong-rapid | #6 |
| 9 | Documentation: README, dependency graph, this SA | APP-6792 | M | dylanong-rapid | #6 |

### Dependency Graph

```
#1 ──► #2 ──► #3 ──► #5 ──► #6 ──► #8
              │       ▲      │
              └► #4 ──┘      ├──► #7
                            └──► #9
```

### Estimates Summary

| Size | Count | Estimated Days |
|------|-------|----------------|
| S | 0 | 1-2 days each |
| M | 4 | 3-5 days each |
| L | 5 | 1-2 weeks each |
| XL | 0 | 2+ weeks each |

**Total Estimated Effort**: ~7–11 weeks

## Timeline / Milestones

1. **Inventory & engine** (Tasks #1–#3) — config generated, single-package
   builds working with tweaks.
2. **Drivers** (Tasks #4–#5) — batch and per-group builders.
3. **Verification** (Task #6) — all non-aws groups verified on Xcode 16.4.
   *(Current state: reached — 6 non-aws groups building.)*
4. **AWS + skips** (Tasks #7–#8) — opt-in `aws` group and the two source-level
   skips.
5. **Docs** (Task #9) — README, dependency graph, SA.

## Open Questions

1. **Remote distribution** — Will these XCFrameworks eventually be hosted in a
   remote registry (using the manifest's zip + checksum), or remain local-only?
2. **CI integration** — Should group builds run in CI, and how are produced
   artifacts cached/consumed by `rapid-ios-app`?
3. **`swift-crypto` / `opentelemetry-swift`** — Is the source-level work to
   convert these in scope for APP-6792 or a follow-up ticket?
4. **Re-generation cadence** — When pins change in `Package.resolved`, what is
   the process/owner for regenerating `xcframeworks.config.json`?
5. **Consumption switch** — How and when does `rapid-ios-app` flip from source
   packages to `.binaryTarget` references?
