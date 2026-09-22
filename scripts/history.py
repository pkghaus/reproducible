#!/usr/bin/env python3
"""Carry the last few verdicts forward onto the one this run produced.

    history.py <this run's verdict dir> <prior state dir>

Both directories hold <suite>/<arch>/<package>.json. Files in the first gain a
`history` array; the second is read only.

Why. A single verdict answers "did the most recent rebuild match", and that is
not the question anyone asks after a fix. On 2026-09-22 the page read
216/216 GOOD one rebuild after two arm64 legs had been failing about half the
time, and nothing on it distinguished "reproduced, and always has" from
"reproduced once, having flipped a coin last week". Both render the same word
and the same green. That ambiguity is what this removes.

It also removes the reason the consecutive-GOODs bar existed. With no history
the only way to tell a fix from luck is consecutive passes, and the sweep is a
round robin: 216 artifacts over 6 legs at MAX_PER_LEG=3 is a 12-day period, so
five in a row is about 48 days. Five stored verdicts answer the same question
whenever they happen to land.

Three decisions worth keeping:

  * STATUS AND TIMESTAMP ONLY. A run URL is the obvious third field and the
    wrong one to keep: Actions logs expire, so an old entry would carry a link
    that is dead by the time anyone follows it. The current verdict already
    holds the live run.
  * A VERSION CHANGE RESETS IT. History is about one artifact, and a new
    version is a different file. Carrying `0.23.6-3`'s failures onto `-4` would
    make a fix unprovable. Same scoping as sticky-bad.py, for the same reason.
  * NEWEST LAST. The page draws the strip left to right in time, and a reader
    who opens the JSON should see the same order they see rendered.
  * THE 216 VERDICTS THAT PREDATE THIS ARE NOT SEEDED. Their status is a real
    observation and carrying it in as a first entry is tempting, but a prior
    verdict's `status` may be a sticky BAD rather than its last rebuild, and
    `checked_at` then belongs to the run that set it. Seeding would need a
    branch that is only safe against today's data (216 GOOD, 0 flapped) and
    would live in the code forever for one migration. They fill in as the
    sweep reaches them, about twelve days, and read as an empty strip until
    then - which is what the page says an empty strip means.

Cost, measured 2026-09-22: verdicts.json was 114,090 bytes for 216 verdicts.
An entry is about 45 bytes, so four extra per artifact is about 38 KB and the
index grows by roughly a third. The Worker still reads it twice per render.
"""

import glob
import json
import os
import sys

# Five, because that is what it takes to be unconvinced by luck. On a leg that
# fails half the time, two agreeing rebuilds happen a quarter of the time and
# five happen about three percent of the time.
HISTORY_MAX = 5


def merged(new, prior):
    """The history array to store on `new`, given the prior verdict or None."""
    carried = []
    if prior and prior.get("version") == new.get("version"):
        carried = [e for e in (prior.get("history") or [])
                   if isinstance(e, dict) and e.get("status")]
    entry = {"status": new.get("status"), "at": new.get("checked_at")}
    return (carried + [entry])[-HISTORY_MAX:]


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: history.py <verdict dir> <prior state dir>")
    new_dir, prior_dir = sys.argv[1], sys.argv[2]

    written = 0
    for path in sorted(glob.glob(os.path.join(new_dir, "*", "*", "*.json"))):
        rel = os.path.relpath(path, new_dir)
        try:
            with open(path, encoding="utf-8") as handle:
                new = json.load(handle)
        except ValueError:
            # Same call the index roller makes: unreadable JSON is left alone
            # rather than guessed at. validate_verdicts has already refused
            # this run's side of it.
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
                print(f"WARNING: prior {rel} will not parse, starting its "
                      "history fresh", file=sys.stderr)

        new["history"] = merged(new, prior)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(new, handle, indent=2, sort_keys=True)
        written += 1

    if written:
        print(f"carried history onto {written} verdict(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
