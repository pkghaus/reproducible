#!/usr/bin/env python3
"""Keep a BAD verdict from being cleared by a later non-BAD one.

    sticky-bad.py <this run's verdict dir> <prior state dir>

Both directories hold <suite>/<arch>/<package>.json. Files in the first are
rewritten in place where the rule below applies; the second is read only.

Why. Reproducibility is quantified over EVERY rebuild of an artifact, and a
published .deb is immutable. One differing rebuild falsifies the claim, and a
later matching rebuild does not repair it -- it proves the build is
non-deterministic, which is worse news than a consistent failure. Overwriting
in place would publish that as good news and leave the evidence only in a CI
log that expires.

zola 0.23.6-3 is the case that forced this, 2026-09-21: BAD on testing/arm64
and unstable/arm64, GOOD on all three amd64 legs and on trixie/arm64. Its
documented cause is LLVM pass-ordering non-determinism, so a re-run could
plausibly have come back GOOD and erased the only record of the failure.

Scope, and the three ways this could be got wrong:

  * SAME VERSION ONLY. A new version is a new artifact and starts clean.
    plan.sh already treats a version change as stale for the same reason, so
    a fixed package clears itself by being rebuilt, with no manual step.
  * AN UNKWN NEVER CLEARS A BAD EITHER. "could not tell" is not evidence of
    reproducing. It is recorded as the last outcome but does not set flapped.
  * FLAPPED MEANS A REBUILD ACTUALLY MATCHED. Only a GOOD sets it, because
    that is the bit that distinguishes a consistently irreproducible package
    from a non-deterministic one -- which is the whole finding for zola.

The escape hatch is deleting the object from the bucket, which is a
deliberate act and is what a genuinely fixed artifact on an unchanged version
would need. There is intentionally no flag for it: a verdict that can be
cleared by the same pipeline that writes it is not evidence.
"""

import glob
import json
import os
import sys


def merge(new, prior):
    """Return the verdict to publish, or None to keep what the run produced."""
    if prior.get("status") != "BAD":
        return None
    if prior.get("version") != new.get("version"):
        return None
    if new.get("status") == "BAD":
        # Still failing. The fresher record is the better one; carry any
        # flapped marker forward so a single later GOOD is not forgotten.
        if prior.get("flapped"):
            out = dict(new)
            out["flapped"] = True
            return out
        return None

    out = dict(prior)
    out["last_rebuild_status"] = new.get("status")
    out["last_rebuild_at"] = new.get("checked_at")
    out["last_rebuild_run"] = new.get("run")
    if new.get("status") == "GOOD":
        out["flapped"] = True
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: sticky-bad.py <verdict dir> <prior state dir>")
    new_dir, prior_dir = sys.argv[1], sys.argv[2]

    kept = 0
    for path in sorted(glob.glob(os.path.join(new_dir, "*", "*", "*.json"))):
        rel = os.path.relpath(path, new_dir)
        prior_path = os.path.join(prior_dir, rel)
        if not os.path.exists(prior_path):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                new = json.load(handle)
            with open(prior_path, encoding="utf-8") as handle:
                prior = json.load(handle)
        except ValueError:
            # Same call the index roller makes: unreadable JSON is left alone
            # rather than guessed at. validate_verdicts has already refused
            # this run's side of it.
            print(f"WARNING: {rel} or its prior state is not valid JSON, "
                  "leaving it alone", file=sys.stderr)
            continue

        merged = merge(new, prior)
        if merged is None:
            continue
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(merged, handle, indent=2, sort_keys=True)
        kept += 1
        print(f"keeping BAD for {rel}: this run said "
              f"{new.get('status')} for the same version "
              f"{new.get('version')!r}", file=sys.stderr)

    if kept:
        print(f"{kept} BAD verdict(s) survived a later non-BAD rebuild",
              file=sys.stderr)


if __name__ == "__main__":
    main()
