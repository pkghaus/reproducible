#!/usr/bin/env python3
"""Roll every verdict in a synced verify/ tree into one index object.

    roll-index.py <synced verify dir> <output file>

Why this exists. The Worker rendered a page by reading one R2 object per
artifact. At 75 verdicts that was 5.6 to 8.1 seconds on a cache miss,
measured 2026-09-21; at the fleet's 216 it would have been three times that.
Binding reads are also capped per Worker invocation on the free plan and a
render was already making about eighty of them. Reading one object instead of
216 fixes the latency and removes the cap from the picture.

The per-artifact files are NOT replaced. They are the documented
machine-readable endpoint, /verify/<suite>/<arch>/<package>.json, and this is
a derived view of them.

Zero is not a pass. An index built from nothing would render the page as a
fleet where nothing has been verified, which is the exact false negative the
whole surface exists to avoid, so an empty result is a hard failure.
"""

import datetime
import glob
import json
import os
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: roll-index.py <synced verify dir> <output file>")
    source, out = sys.argv[1], sys.argv[2]

    verdicts = []
    for path in sorted(glob.glob(os.path.join(source, "*", "*", "*.json"))):
        try:
            with open(path, encoding="utf-8") as handle:
                verdicts.append(json.load(handle))
        except ValueError:
            # The same call the Worker's reader made: a verdict that will not
            # parse is dropped rather than rendered half-read. It stays in the
            # bucket for whoever looks.
            print(f"WARNING: {path} is not valid JSON, leaving it out",
                  file=sys.stderr)

    if not verdicts:
        sys.exit("FATAL: no readable verdict under "
                 f"{source}; refusing to publish an index that would render "
                 "the page as a fleet where nothing has been verified")

    with open(out, "w", encoding="utf-8") as handle:
        json.dump({
            "generated_at": datetime.datetime.now(datetime.timezone.utc)
                                    .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "verdicts": verdicts,
        }, handle, separators=(",", ":"), sort_keys=True)
    print(f"rolled {len(verdicts)} verdict(s) into the index", file=sys.stderr)


if __name__ == "__main__":
    main()
