#!/usr/bin/env bash
#
# What the archive publishes, as one JSON object.
#
#   scripts/inventory.sh [outfile]
#
# Reads the six binary indices (three suites x two arches) and writes the set
# of published artifacts. Two consumers:
#
#  - plan.sh, which subtracts the verdicts already in the bucket to decide what
#    to verify next.
#  - the Worker, which needs a denominator. Coverage and reproducibility are
#    different numbers, and a page showing only the second turns an artifact
#    nobody has checked into a silent pass. The verdicts cannot supply the
#    first: an artifact with no verdict leaves nothing to count.
#
# Sends the pkghaus-ci User-Agent on every fetch. Index reads are not counted
# by the archive Worker (only a .deb out of the pool is), but a sweep is
# exactly the shape the marker exists for and the habit is the control.

set -euo pipefail
shopt -s inherit_errexit

ARCHIVE_URL="${ARCHIVE_URL:-https://apt.pkg.haus}"
BUILDINFOS_URL=https://buildinfos.pkg.haus
SUITES="${SUITES:-trixie testing unstable}"
ARCHES="${ARCHES:-amd64 arm64}"
UA="curl pkghaus-ci"

# The end-to-end test reaches this through a file:// ARCHIVE_URL.
fetch_index() { # suite arch
    curl -fsSL --max-time 120 -A "$UA" \
        "$ARCHIVE_URL/dists/$1/main/binary-$2/Packages"
}

# One "<package>\t<version>\t<source>\t<architecture>" line per binary in one
# index.
#
# Source defaults to the package name and is overridden by a Source: field.
# deb822 spells that field `Source: <name>` or `Source: <name> (<version>)`
# when the source version differs from the binary's, and the name is the first
# field either way, so $2 is the whole of it. Nothing in the fleet sets it
# today; reading it costs nothing and the alternative is a buildinfo path that
# 404s forever the day something does.
index_rows() { # reader suite arch
    "$1" "$2" "$3" | awk '
        function flush() {
            if (pkg != "") printf "%s\t%s\t%s\t%s\n", pkg, ver, (src != "" ? src : pkg), archf
            pkg = ""; ver = ""; src = ""; archf = ""
        }
        /^Package: /{ flush(); pkg = $2 }
        /^Version: /{ ver = $2 }
        /^Source: /{ src = $2 }
        /^Architecture: /{ archf = $2 }
        END { flush() }
    '
}

# The architecture the artifact was BUILT on, which is not always the index it
# appears in. An `Architecture: all` package is built once and listed in every
# arch's index: betterlockscreen and pkghaus-archive-keyring are the fleet's
# two, and buildinfos.pkg.haus carries only their `_amd64.buildinfo`, measured
# across all three suites 2026-09-21.
#
# Hardcoding amd64 here would be a guess that fails silently the day an
# arch:all package is built on the other leg. It is not one: a wrong build arch
# produces a URL that 404s, the verifier records UNKWN naming the URL it could
# not fetch, and the page says so. Visible beats clever.
build_arch() { # index-architecture
    case "$1" in
        all) printf 'amd64\n' ;;
        *)   printf '%s\n' "$1" ;;
    esac
}

# The published .buildinfo for one artifact, as a URL. Same sharding as the
# .deb pool, on the SOURCE name's first character: publish-buildinfo.sh writes
# buildinfo-pool/<initial>/<source>/<name>_<version>_<arch>.buildinfo. Debian
# folds lib* into lib<initial>; no fleet package starts with lib, so that case
# is deliberately not handled rather than guessed at.
buildinfo_url() { # package version arch source
    printf '%s/buildinfo-pool/%s/%s/%s_%s_%s.buildinfo\n' \
        "$BUILDINFOS_URL" "${4:0:1}" "$4" "$1" "$2" "$3"
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

OUT="${1:-inventory.json}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

: > "$work/rows.tsv"
for suite in $SUITES; do
    for arch in $ARCHES; do
        index_rows fetch_index "$suite" "$arch" > "$work/index.tsv"
        # An index that yields nothing is a broken fetch or a broken publish,
        # never an empty archive: every suite carries the whole fleet. Reporting
        # 0 published would make coverage read as a full sweep of nothing.
        [ -s "$work/index.tsv" ] || {
            printf 'FATAL: %s/%s published no packages\n' "$suite" "$arch" >&2
            exit 1
        }
        while IFS=$'\t' read -r pkg ver src indexarch; do
            barch="$(build_arch "$indexarch")"
            printf '%s/%s\t%s\t%s\t%s\t%s\n' "$suite" "$arch" "$pkg" "$ver" "$barch" \
                "$(buildinfo_url "$pkg" "$ver" "$barch" "$src")"
        done < "$work/index.tsv" >> "$work/rows.tsv"
    done
done

# The Worker answers a malformed inventory with zero published, which reads on
# the page as a fleet that does not exist, so a row missing a field is fatal.
python3 - "$OUT" "$ARCHIVE_URL" "$work/rows.tsv" <<'PY'
import datetime, json, sys
out, archive, rows = sys.argv[1:4]
FIELDS = ("package", "version", "build_arch", "buildinfo")
targets = {}
for line in open(rows, encoding="utf-8"):
    target, *values = line.rstrip("\n").split("\t")
    row = dict(zip(FIELDS, values))
    missing = [f for f in FIELDS if not row.get(f)]
    if missing:
        sys.exit(f"FATAL: {target} has a row missing {missing[0]}: {row!r}")
    targets.setdefault(target, []).append(row)
if not targets:
    sys.exit("FATAL: inventory has no targets")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(out, "w", encoding="utf-8") as handle:
    json.dump({"generated_at": now, "archive": archive, "targets": targets},
              handle, indent=2)
print(f"{sum(len(r) for r in targets.values())} artifacts across {len(targets)} targets",
      file=sys.stderr)
PY
