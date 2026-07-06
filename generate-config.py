#!/usr/bin/env python3
"""
generate-config.py — Generate xcframeworks.config.json from a Swift Package.resolved
plus a hand-maintained overlay.

WHY: xcframeworks.config.json is two kinds of data fused together:

  1. Pins  (version / revision / tag) — mechanically derivable from the app's
     RapidPlatform.xcworkspace/.../Package.resolved. These change every time the
     iOS app bumps a dependency.
  2. Curated knowledge (products, group, order, skip, per-package build tweaks
     like noMachOOverride / explicitProducts / submodules / ...). This is
     human-discovered and must NEVER be clobbered by a regen.

So generation is a MERGE, not a regen-from-scratch: pins come from Package.resolved,
everything else comes from xcframeworks.overlay.json. The two are joined on the
package URL, because Package.resolved stores a *lowercased* identity while the
config needs the canonical package name (SwiftProtobuf, GoogleUtilities, ...).

USAGE
  ./generate-config.py --resolved <Package.resolved> [--check | --write]
                       [--overlay xcframeworks.overlay.json]
                       [--out xcframeworks.config.json]

MODES
  (default)  Dry-run: print the drift report, write nothing. Exit 0.
  --check    CI mode: compare regenerated config against --out. Print drift report.
             Exit non-zero if they differ OR if there are untriaged new deps.
  --write    Apply: write the merged config to --out.

DRIFT REPORT — three independent signals:
  • changed   pin (version/revision/tag) moved for a package already in the overlay
  • new       URL present in Package.resolved but missing from the overlay
              -> a human must add products/group/order/tweaks before it can build
  • removed   URL in the overlay but no longer in Package.resolved (dep dropped)
"""
import argparse
import json
import sys
from collections import OrderedDict

# Fields owned by Package.resolved. Everything else on a package comes from the overlay.
PIN_FIELDS = ("version", "revision", "tag")
# Preferred key order when emitting a package entry.
FIELD_ORDER = ["name", "url", "version", "revision", "tag", "group", "order", "products", "skip"]


def norm_url(url):
    """Normalize a git URL for joining. GitHub is case-insensitive; .git and a
    trailing slash are cosmetic."""
    u = (url or "").strip().rstrip("/")
    if u.endswith(".git"):
        u = u[:-4]
    return u.lower()


def load_resolved(path):
    """Parse Package.resolved (v1 'object.pins' or v2/v3 top-level 'pins').
    Returns { normalized_url: {"url","version","revision","tag"} }."""
    data = json.load(open(path))
    pins = data.get("pins")
    if pins is None:  # v1
        pins = data.get("object", {}).get("pins", [])
    out = {}
    for pin in pins:
        url = pin.get("location") or pin.get("repositoryURL") or pin.get("url")
        if not url:
            continue
        state = pin.get("state", {}) or {}
        version = state.get("version")  # absent for branch/revision pins
        out[norm_url(url)] = {
            "url": url,
            "version": version,
            "revision": state.get("revision"),
            "tag": version,  # tag tracks the resolved version tag when present
        }
    return out


def load_overlay(path):
    data = json.load(open(path))
    entries = data.get("overlay", [])
    by_url = OrderedDict()
    for e in entries:
        by_url[norm_url(e["url"])] = e
    return data, by_url


def order_keys(d):
    """Re-emit a package dict with FIELD_ORDER first, remaining keys after."""
    out = OrderedDict()
    for k in FIELD_ORDER:
        if k in d:
            out[k] = d[k]
    for k, v in d.items():
        if k not in out:
            out[k] = v
    return out


def merge(overlay_doc, overlay_by_url, pins):
    """Produce (config_dict, report). config preserves overlay ordering."""
    report = {"changed": [], "new": [], "removed": []}
    packages = []

    for nurl, entry in overlay_by_url.items():
        pkg = OrderedDict()
        # curated fields first (so name/url/group/... carry through)
        for k, v in entry.items():
            pkg[k] = v
        pin = pins.get(nurl)
        if pin is None:
            report["removed"].append(entry.get("name", entry.get("url")))
            # keep prior pins if the overlay still references it; surfaced as drift
        else:
            for f in PIN_FIELDS:
                pkg[f] = pin[f]
        packages.append(order_keys(pkg))

    # pins with no overlay entry == brand-new dependencies needing triage
    for nurl, pin in pins.items():
        if nurl not in overlay_by_url:
            report["new"].append(pin["url"])

    config = OrderedDict()
    config["schemaVersion"] = overlay_doc.get("schemaVersion", 1)
    config["description"] = overlay_doc.get("description", "")
    config["generatedFrom"] = overlay_doc.get("generatedFrom", "")
    config["defaults"] = overlay_doc.get("defaults", {})
    config["groupOrder"] = overlay_doc.get("groupOrder", [])
    config["packages"] = packages
    return config, report


def diff_pins(new_config, old_config):
    """Compare pin fields per package (joined on url) between regenerated and on-disk."""
    def by_url(cfg):
        return {norm_url(p["url"]): p for p in cfg.get("packages", [])}
    old = by_url(old_config)
    changed = []
    for nurl, p in by_url(new_config).items():
        o = old.get(nurl)
        if not o:
            continue
        for f in PIN_FIELDS:
            if p.get(f) != o.get(f):
                changed.append((p.get("name", p["url"]), f, o.get(f), p.get(f)))
    return changed


def print_report(report, pin_changes):
    def section(title, items):
        print(f"  {title}: {len(items)}")
        for it in items:
            print(f"    - {it}")
    if pin_changes:
        print(f"  changed pins: {len(pin_changes)}")
        for name, f, old, new in pin_changes:
            print(f"    - {name}: {f} {old} -> {new}")
    else:
        print("  changed pins: 0")
    section("new (need triage in overlay)", report["new"])
    section("removed (gone from Package.resolved)", report["removed"])


def main():
    ap = argparse.ArgumentParser(description="Generate xcframeworks.config.json from Package.resolved + overlay.")
    ap.add_argument("--resolved", required=True, help="Path to Package.resolved")
    ap.add_argument("--overlay", default="xcframeworks.overlay.json")
    ap.add_argument("--out", default="xcframeworks.config.json")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="CI mode: fail on drift / untriaged deps")
    mode.add_argument("--write", action="store_true", help="Write merged config to --out")
    args = ap.parse_args()

    pins = load_resolved(args.resolved)
    overlay_doc, overlay_by_url = load_overlay(args.overlay)
    config, report = merge(overlay_doc, overlay_by_url, pins)

    try:
        old_config = json.load(open(args.out))
    except FileNotFoundError:
        old_config = {"packages": []}
    removed_names = set(report["removed"])
    pin_changes = [c for c in diff_pins(config, old_config) if c[0] not in removed_names]

    print(f"Package.resolved : {args.resolved}  ({len(pins)} pins)")
    print(f"overlay          : {args.overlay}  ({len(overlay_by_url)} entries)")
    print("drift report:")
    print_report(report, pin_changes)

    drift = bool(pin_changes or report["new"] or report["removed"])

    if args.write:
        json.dump(config, open(args.out, "w"), indent=2)
        open(args.out, "a").write("\n")
        print(f"wrote {args.out} ({len(config['packages'])} packages)")
        return 0

    if args.check:
        if report["new"]:
            print("FAIL: new dependencies present in Package.resolved but missing from overlay.")
            return 1
        if drift:
            print("FAIL: config is out of date with Package.resolved (run --write).")
            return 1
        print("OK: config is in sync with Package.resolved.")
        return 0

    # default dry-run
    print("(dry-run; pass --write to apply or --check for CI)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
