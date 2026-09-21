#!/usr/bin/env bash
#
# What to verify next, as one JSON object.
#
#   scripts/plan.sh <inventory.json> <verdict-dir> [> plan.json]
#
# <verdict-dir> mirrors the bucket's verify/ prefix, as `aws s3 sync` leaves
# it: verify/<suite>/<arch>/<package>.json. An empty or missing directory is a
# first run, not an error.
#
# Two things decide the plan.
#
# PRIORITY. An artifact with no verdict, or whose verdict names a version the
# archive no longer publishes, comes first: those are the two states where the
# page is silent about something it should be reporting. Everything else is
# ordered oldest-verdict-first, so a fleet at rest re-verifies round-robin.
#
# THROTTLE. snapshot.debian.org is a rate-limited volunteer service and it is
# the binding constraint on this whole system, not CI minutes. MAX_PER_LEG
# bounds how many rebuilds one leg starts per run; six legs run in parallel and
# each works through its own list serially.
#
# An `Architecture: all` package is published in both arch indices and built
# once. It appears here as ONE item with two targets, so it rebuilds once and
# writes both verdicts. Verifying it twice would spend a rebuild to learn the
# same fact, and reporting it in only one column would leave the other reading
# as unchecked forever.

set -euo pipefail
shopt -s inherit_errexit

INVENTORY="${1:?usage: $0 <inventory.json> <verdict-dir>}"
VERDICTS="${2:?usage: $0 <inventory.json> <verdict-dir>}"

# Deliberately small. Raised explicitly by the dispatch path, which knows it is
# verifying one freshly published package rather than sweeping.
MAX_PER_LEG="${MAX_PER_LEG:-3}"
# Space-separated. Empty means "whatever the priority order picks".
ONLY_PACKAGES="${ONLY_PACKAGES:-}"

python3 - "$INVENTORY" "$VERDICTS" "$MAX_PER_LEG" "$ONLY_PACKAGES" <<'PY'
import datetime
import json
import os
import sys

inventory_path, verdict_dir, max_per_leg, only = sys.argv[1:5]
max_per_leg = int(max_per_leg)
only = set(only.split())

inventory = json.load(open(inventory_path, encoding="utf-8"))
targets = inventory.get("targets") or {}
if not targets:
    sys.exit("FATAL: inventory has no targets")

# Read rather than list: the object's key says nothing about which version it
# is a verdict for, and "the verdict is for the version we no longer publish"
# is half the reason to re-verify. A verdict that will not parse is treated as
# absent, which re-verifies it and overwrites the damage.
def verdict_for(suite, arch, package):
    path = os.path.join(verdict_dir, suite, arch, f"{package}.json")
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None

EPOCH = "0000-00-00T00:00:00Z"

items = {}
for target, rows in targets.items():
    suite, arch = target.split("/", 1)
    for row in rows:
        package = row["package"]
        if only and package not in only:
            continue
        key = (suite, row["build_arch"], package)
        item = items.setdefault(key, {
            "package": package,
            "version": row["version"],
            "suite": suite,
            "build_arch": row["build_arch"],
            "buildinfo": row["buildinfo"],
            "targets": [],
            "_stale": [],
            "_age": None,
        })
        item["targets"].append(target)

        verdict = verdict_for(suite, arch, package)
        if verdict is None:
            item["_stale"].append("never checked")
            item["_age"] = EPOCH
        elif verdict.get("version") != row["version"]:
            item["_stale"].append(f"verdict is for {verdict.get('version')!r}")
            item["_age"] = EPOCH
        else:
            checked = verdict.get("checked_at") or EPOCH
            if item["_age"] is None or checked < item["_age"]:
                item["_age"] = checked

work = []
for key in sorted(items):
    item = items[key]
    item["targets"].sort()
    item["reason"] = item["_stale"][0] if item["_stale"] else "re-verify"
    work.append(item)

# Priority first, then oldest. Python's sort is stable and the input is already
# name-ordered, so ties break the same way on every run -- which is what makes
# a round-robin sweep actually reach every artifact instead of revisiting
# whichever one the dict happened to yield first.
work.sort(key=lambda i: (0 if i["_stale"] else 1, i["_age"]))

picked, per_leg = [], {}
for item in work:
    leg = (item["suite"], item["build_arch"])
    if per_leg.get(leg, 0) >= max_per_leg:
        continue
    per_leg[leg] = per_leg.get(leg, 0) + 1
    picked.append({k: v for k, v in item.items() if not k.startswith("_")})

picked.sort(key=lambda i: (i["suite"], i["build_arch"], i["package"]))
legs = [{"suite": s, "arch": a} for s, a in sorted(per_leg)]

print(json.dumps({
    "generated_at": datetime.datetime.now(datetime.timezone.utc)
                            .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "considered": len(work),
    "legs": legs,
    "items": picked,
}, indent=2))

print(f"planned {len(picked)} rebuild(s) across {len(legs)} leg(s) "
      f"from {len(work)} candidate(s)", file=sys.stderr)
PY
