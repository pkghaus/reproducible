#!/usr/bin/env bash
#
# Rebuild one leg's planned artifacts and write a verdict for each.
#
#   scripts/verify.sh <plan.json> <suite> <build-arch> <outdir>
#
# Reads the items plan.sh assigned to this leg, fetches each one's published
# inputs from buildinfos.pkg.haus, hands them to verify/rebuild.sh, and writes
# <outdir>/<suite>/<arch>/<package>.json per target.
#
# Nothing here touches the archive's storage, and nothing needs a credential to
# read: every input is a public URL, fetched over the same path an independent
# rebuilder would use. That is the point. A verifier reading the archive's own
# bucket would be checking a copy no outsider can see.
#
# THE THREE WORDS, and what earns each. rebuilderd's vocabulary, so this reads
# the same way as reproducible.archlinux.org and reproduce.debian.net.
#
#   GOOD   debrebuild compared every recorded checksum and they matched.
#   BAD    debrebuild compared them and one differed.
#   UNKWN  the comparison did not happen.
#
# UNKWN covers a missing record, an unreachable snapshot.debian.org, a build
# dependency that is no longer resolvable, and a rebuild that failed to build
# at all. None of those is evidence about this archive, and recording them as
# BAD would be a claim the run cannot support. It is the load-bearing third
# state, not a rounding error: snapshot.debian.org is a rate-limited volunteer
# service and it decides how much of this page is ever populated.
#
# Classification is written against debrebuild's SOURCE rather than its manual.
# Its comparison loop prints "checking <file>: size... sha256... all OK" per
# file and `die`s -- to stderr, exit non-zero -- with one of four fixed
# wordings when something differs. Everything before that loop dies with a
# different wording and means the environment, not the package. The four
# patterns below are those wordings; tests/run.sh drives each of them through
# classify() against a captured log.

set -euo pipefail
shopt -s inherit_errexit

PLAN="${1:?usage: $0 <plan.json> <suite> <build-arch> <outdir>}"
SUITE="${2:?usage: $0 <plan.json> <suite> <build-arch> <outdir>}"
BUILD_ARCH="${3:?usage: $0 <plan.json> <suite> <build-arch> <outdir>}"
OUTDIR="${4:?usage: $0 <plan.json> <suite> <build-arch> <outdir>}"

# Where a BAD's rebuilt .deb is kept. The RECORDED half is public and
# permanent -- anyone can fetch it from the archive -- so the half worth
# saving is the one that otherwise evaporates with the work directory. With
# it and the published original, diffoscope can be run later at full strength
# on a machine of the right architecture, which is what zola's arm64 failure
# needed and could not have.
EVIDENCE="${EVIDENCE:-evidence}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UA="${PKGHAUS_UA:-curl pkghaus-ci}"
# An hour per artifact. A Rust rebuild of the larger packages runs to tens of
# minutes, and snapshot.debian.org stalls rather than refusing, so the bound
# has to exist: without it one stalled fetch eats the leg's whole budget and
# every artifact behind it goes unverified with nothing recorded. The timeout
# kills this script's child, not the container it started -- the runner is
# destroyed with the job, so nothing outlives it there.
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-3600}"

fetch() { # url dest
    curl -fsSL --max-time 600 --retry 3 --retry-all-errors --retry-delay 5 \
        -A "$UA" -o "$2" "$1"
}

# The names a .buildinfo or .dsc lists in its Checksums-Sha256 block. Both are
# deb822 with the same block shape and both may be clearsigned; a continuation
# line starts with a space, which is what ends the block.
checksum_files() { # file
    awk '
        /^Checksums-Sha256:/ { inblock = 1; next }
        inblock && /^ / { print $3; next }
        inblock { exit }
    ' "$1"
}

# The recorded sha256 of one file, from the same block.
checksum_of() { # file name
    awk -v want="$2" '
        /^Checksums-Sha256:/ { inblock = 1; next }
        inblock && /^ / { if ($3 == want) { print $1; exit }; next }
        inblock { exit }
    ' "$1"
}

# And its recorded size. Field 2 of the same line, verified against a real
# record rather than the spec: zola_0.23.6-3_arm64.buildinfo carries
# "<sha256> 10569132 zola_0.23.6-3_arm64.deb". Free, because the record is
# already fetched -- which matters, since the recorded .deb itself is not
# downloaded and fetching one only to size it would be a real cost on a host
# whose downloads are counted.
size_of() { # file name
    awk -v want="$2" '
        /^Checksums-Sha256:/ { inblock = 1; next }
        inblock && /^ / { if ($3 == want) { print $2; exit }; next }
        inblock { exit }
    ' "$1"
}

# The four wordings debrebuild's comparison loop dies with. Kept in one place
# because classify() and summarise_log() must agree: a verdict of BAD whose
# summary came up empty would print a blank cell on the page.
#
# NOT anchored to the start of a line, and that is the whole reason this was
# checked against a captured run rather than against the source. The loop
# prints "checking <file>: " with no newline and then `die`s; print goes to
# stdout and die to stderr, and this script merges the two. A real mismatch
# therefore arrives as
#
#   checking x_all.deb: size... md5... sha1... value of sha256 differs for x_all.deb
#
# on ONE line. An anchored pattern matches none of it, every BAD reads as
# UNKWN, and the page reports "could not be checked" for the one case it
# exists to report. Captured 2026-09-21 from pkghaus-archive-keyring
# 2026.09.11 with one byte of its recorded sha256 altered.
DIFFERS='(value of [a-z0-9]+ differs for |size differs for |different checksum files at position |new buildinfo contains a different number of files)'

# GOOD, BAD or UNKWN from the rebuild's exit status and its log.
#
# Exit 0 is not enough on its own. The comparison loop runs once per recorded
# file, and a record listing nothing but the .dsc -- which the loop skips --
# exits 0 having compared nothing. "all OK" is the only line the loop prints on
# a match, so requiring it is what stops an empty comparison reading as a pass.
classify() { # exit-status log
    if [ "$1" -eq 0 ] && grep -q '^checking .*all OK$' "$2"; then
        printf 'GOOD\n'
    elif grep -qE "$DIFFERS" "$2"; then
        printf 'BAD\n'
    else
        printf 'UNKWN\n'
    fi
}

# The one line a reader should see. For GOOD the comparison's own verdict; for
# BAD the wording naming what differed; for UNKWN the last line that said
# anything, which is usually debrebuild's die or curl's error.
summarise_log() { # verdict log
    case "$1" in
        GOOD) printf 'all OK\n' ;;
        BAD)  grep -oE "$DIFFERS.*" "$2" | head -1 ;;
        # An empty log is possible and `grep` on one exits 1, which under
        # pipefail fails the assignment this feeds. Say so instead.
        *)    grep -v '^[[:space:]]*$' "$2" | tail -1 | cut -c1-300 \
                  || printf 'the rebuild produced no output\n' ;;
    esac
}

emit_verdict() { # outfile package version suite arch verdict buildinfo summary reason rebuilt recorded rebuilt_size recorded_size
    python3 - "$@" <<'PY'
import datetime, json, os, sys
(out, package, version, suite, arch, status, buildinfo,
 summary, reason, rebuilt, recorded, rebuilt_size, recorded_size) = sys.argv[1:14]
with open(out, "w", encoding="utf-8") as handle:
    json.dump({
        "package": package,
        "version": version,
        "suite": suite,
        "arch": arch,
        "status": status,
        "checked_at": datetime.datetime.now(datetime.timezone.utc)
                              .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "buildinfo": buildinfo,
        "debrebuild": summary or None,
        "unknown_reason": reason or None,
        "rebuilt_sha256": rebuilt or None,
        "recorded_sha256": recorded or None,
        # "size differs" is debrebuild's commonest BAD wording and it prints
        # neither size. Both are free here -- one from the record, one from
        # the file on disk -- and the pair is the first thing anyone
        # diagnosing a BAD wants.
        "rebuilt_size": int(rebuilt_size) if rebuilt_size else None,
        "recorded_size": int(recorded_size) if recorded_size else None,
        "run": os.environ.get("VERIFY_RUN_URL") or None,
    }, handle, indent=2, sort_keys=True)
PY
}

# Sourced by the tests; everything below runs only when executed.
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

mkdir -p "$OUTDIR"

# One line per item: package, version, buildinfo URL, then its targets.
items="$(python3 - "$PLAN" "$SUITE" "$BUILD_ARCH" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
for item in plan["items"]:
    if item["suite"] == sys.argv[2] and item["build_arch"] == sys.argv[3]:
        print("\t".join([item["package"], item["version"], item["buildinfo"],
                         " ".join(item["targets"])]))
PY
)"

if [ -z "$items" ]; then
    printf 'nothing planned for %s/%s\n' "$SUITE" "$BUILD_ARCH" >&2
    exit 0
fi

work=""
trap 'rm -rf "${work:?}"' EXIT
written=0

while IFS=$'\t' read -r package version buildinfo targets; do
    [ -n "$package" ] || continue
    printf '\n=== %s %s (%s/%s)\n' "$package" "$version" "$SUITE" "$BUILD_ARCH" >&2

    rm -rf "${work:-/nonexistent}"
    work="$(mktemp -d)"
    log="$work/rebuild.log"
    : > "$log"
    verdict=""; summary=""; reason=""; rebuilt=""; recorded=""
    rebuilt_size=""; recorded_size=""
    base="${buildinfo%/*}"
    name="${buildinfo##*/}"

    if ! fetch "$buildinfo" "$work/$name" 2>>"$log"; then
        verdict=UNKWN
        reason="no build record published at $buildinfo"
    fi

    if [ -z "$verdict" ]; then
        # The .dsc is named in the record; the tarballs are named in the .dsc.
        # Fetching by the names they give, rather than by pattern, is what
        # keeps this right if a package ever ships more than one tarball.
        dsc="$(checksum_files "$work/$name" | grep '\.dsc$' | head -1 || true)"
        deb="$(checksum_files "$work/$name" | grep '\.deb$' | head -1 || true)"
        # Read from the record, not rebuilt from the package name: an
        # `Architecture: all` package's record is named _amd64.buildinfo and
        # its binary _all.deb, so composing the name from the two would miss.
        if [ -n "$deb" ]; then
            recorded="$(checksum_of "$work/$name" "$deb")"
            recorded_size="$(size_of "$work/$name" "$deb")"
        fi
        if [ -z "$dsc" ]; then
            verdict=UNKWN
            reason="the record names no .dsc, so the source cannot be fetched"
        elif ! fetch "$base/$dsc" "$work/$dsc" 2>>"$log"; then
            verdict=UNKWN
            reason="the record's source package $dsc is not published"
        else
            for f in $(checksum_files "$work/$dsc"); do
                if ! fetch "$base/$f" "$work/$f" 2>>"$log"; then
                    verdict=UNKWN
                    reason="the source package names $f, which is not published"
                    break
                fi
            done
        fi
    fi

    if [ -z "$verdict" ]; then
        set +e
        timeout --kill-after=60 "$VERIFY_TIMEOUT" \
            "$ROOT/verify/rebuild.sh" "$work" >>"$log" 2>&1
        status=$?
        set -e
        if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
            verdict=UNKWN
            reason="the rebuild did not finish within ${VERIFY_TIMEOUT}s"
        else
            verdict="$(classify "$status" "$log")"
            summary="$(summarise_log "$verdict" "$log")"
            if [ "$verdict" = UNKWN ]; then
                reason="$summary"
            fi
            built="$(find "$work/rebuilt" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null || true)"
            if [ -n "$built" ]; then
                rebuilt="$(sha256sum "$built" | cut -d' ' -f1)"
                rebuilt_size="$(stat -c %s "$built")"
                # Only on BAD. A GOOD rebuild is byte-identical to a file the
                # archive already serves, so keeping it would upload a copy of
                # something public on every run; an UNKWN has nothing to
                # compare. BAD is rare by construction -- two of 216 on the
                # first full sweep -- so this costs nothing until it matters.
                if [ "$verdict" = BAD ]; then
                    mkdir -p "$EVIDENCE/$SUITE/$BUILD_ARCH"
                    cp "$built" "$EVIDENCE/$SUITE/$BUILD_ARCH/"
                    printf 'kept the rebuilt %s for diffing against the published one\n' \
                        "${built##*/}" >&2
                fi
            fi
        fi
        tail -30 "$log" >&2
    fi

    printf '%s: %s %s\n' "$package" "$verdict" "${summary:-$reason}" >&2

    # One rebuild, one verdict per target it covers. An `Architecture: all`
    # package is served to both arches out of one build, so writing only the
    # build arch's cell would leave the other reading as never checked.
    for target in $targets; do
        mkdir -p "$OUTDIR/$target"
        emit_verdict "$OUTDIR/$target/$package.json" \
            "$package" "$version" "${target%/*}" "${target#*/}" \
            "$verdict" "$buildinfo" "$summary" "$reason" "$rebuilt" "$recorded" \
            "$rebuilt_size" "$recorded_size"
        written=$((written + 1))
    done
done <<< "$items"

# A leg that planned work and produced no file did nothing; zero is not a pass
# here any more than anywhere else in this estate.
printf '\n%s verdict(s) written to %s\n' "$written" "$OUTDIR" >&2
if [ "$written" -eq 0 ]; then
    printf 'FATAL: the leg planned work and wrote nothing\n' >&2
    exit 1
fi
