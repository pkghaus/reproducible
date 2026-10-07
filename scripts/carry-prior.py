#!/usr/bin/env python3
"""Carry the prior verdict forward onto the one this run produced.

    carry-prior.py <this run's verdict dir> <prior state dir>

Both hold <suite>/<arch>/<package>.json. Files in the first are rewritten in
place; the second is read only. Each file gets its history first and the
sticky-BAD rule second, because a sticky BAD republishes the prior object and
has to take this run's history with it.

HISTORY. The last HISTORY_MAX outcomes, newest last (the order the page draws
them), each a status and a timestamp and nothing more: a run URL would outlive
the Actions log it points at. A version change resets it, because a new
version is a different file and carrying the old one's failures across would
make a fix unprovable.

STICKY BAD. A BAD is not cleared by a later non-BAD rebuild of the same
version. A published .deb is immutable, so one differing rebuild falsifies the
claim, and a later match proves non-determinism rather than repairing it.
Only a GOOD records that, as `flapped`; an UNKWN is kept as the last rebuild
and never sets it. A new version starts clean. Deleting the object from the
bucket is the only way to clear a BAD, deliberately: a verdict the pipeline
that writes it can clear is not evidence.

A file of this run's that will not parse is left alone, and a prior that is
absent or will not parse is treated as no prior at all.
"""

import glob
import json
import os
import sys

# Five: on a leg that fails half the time, two agreeing rebuilds happen a
# quarter of the time and five about three percent of the time.
HISTORY_MAX = 5


def history(new, prior):
    """The history array to store on `new`, given the prior verdict or None."""
    carried = []
    if prior and prior.get("version") == new.get("version"):
        carried = [e for e in (prior.get("history") or [])
                   if isinstance(e, dict) and e.get("status")]
    entry = {"status": new.get("status"), "at": new.get("checked_at")}
    return (carried + [entry])[-HISTORY_MAX:]


def carry(new, prior):
    """The verdict to publish: `new` with its history, or the prior BAD."""
    new["history"] = history(new, prior)
    if (prior is None or prior.get("status") != "BAD"
            or prior.get("version") != new.get("version")):
        return new
    if new.get("status") == "BAD":
        # Still failing. The fresher record wins, keeping any flapped marker.
        if prior.get("flapped"):
            new["flapped"] = True
        return new

    out = dict(prior)
    out["history"] = new["history"]
    out["last_rebuild_status"] = new.get("status")
    out["last_rebuild_at"] = new.get("checked_at")
    out["last_rebuild_run"] = new.get("run")
    if new.get("status") == "GOOD":
        out["flapped"] = True
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: carry-prior.py <verdict dir> <prior state dir>")
    new_dir, prior_dir = sys.argv[1], sys.argv[2]

    written = kept = 0
    for path in sorted(glob.glob(os.path.join(new_dir, "*", "*", "*.json"))):
        rel = os.path.relpath(path, new_dir)
        try:
            with open(path, encoding="utf-8") as handle:
                new = json.load(handle)
        except ValueError:
            # validate_verdicts has already refused this run's side of it.
            print(f"WARNING: {rel} will not parse, leaving it alone",
                  file=sys.stderr)
            continue

        prior = None
        prior_path = os.path.join(prior_dir, rel)
        if os.path.exists(prior_path):
            try:
                with open(prior_path, encoding="utf-8") as handle:
                    prior = json.load(handle)
            except ValueError:
                print(f"WARNING: prior {rel} will not parse, treating it as "
                      "absent", file=sys.stderr)

        out = carry(new, prior)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(out, handle, indent=2, sort_keys=True)
        written += 1
        if out is not new:
            kept += 1
            print(f"keeping BAD for {rel}: this run said "
                  f"{new.get('status')} for the same version "
                  f"{new.get('version')!r}", file=sys.stderr)

    print(f"carried history onto {written} verdict(s); {kept} BAD verdict(s) "
          "survived a later non-BAD rebuild", file=sys.stderr)


if __name__ == "__main__":
    main()
