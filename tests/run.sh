#!/usr/bin/env bash
#
# The three decisions this repo makes that are dangerous to get wrong and
# invisible when they are:
#
#   what the archive publishes  (inventory.sh)   -- the page's denominator
#   what to rebuild next        (plan.sh)        -- what the fleet ever learns
#   what a rebuild proved       (verify.sh)      -- the word on the page
#
#   tests/run.sh
#
# No network and no docker. inventory.sh runs end to end against a file:// URL
# rather than against a stubbed fetch, so its guards are exercised on the path
# that actually runs. verify.sh's rebuild is the one thing not covered here --
# it needs a privileged container and half an hour -- so its classifier is
# driven against logs captured from real debrebuild runs instead.

# Two habits of this file that shellcheck reads as mistakes, both deliberate.
# Each group runs in a subshell so its environment and its overrides cannot
# leak into the next, hence the subshell-local assignment warnings. And the
# fixtures are reached only through function overrides applied after a script
# is sourced, which static analysis cannot follow.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# `fail` counts assertions and lives in each group's subshell, where it starts
# at the value it is given here and nothing in this scope ever moves it.
# Accumulating group failures into the SAME variable would fork every later
# group with a non-zero count, so one real failure would report every group
# after it as failing too -- which is how a one-line fix looks like a rewrite.
fail=0
groups_failed=0

# What stops this suite reporting success for work it did not do. Groups report
# failure by exit status, which catches an assertion that FAILS and says
# nothing about one that never RAN -- a group returning early, a renamed
# helper, a fixture that stopped being built. Without the count, a group that
# quietly stops asserting still prints "all tests passed".
#
# The count goes through a file because a variable incremented in a subshell
# never reaches this scope. Update the number deliberately: that edit is
# someone noticing it moved.
EXPECTED_ASSERTIONS=152
TALLY="$(mktemp)"
WORK="$(mktemp -d)"
trap 'rm -rf "$TALLY" "$WORK"' EXIT

ok() { printf '  ok   %s\n' "$1"; echo ok >> "$TALLY"; }
no() { printf '  FAIL %s\n    %s\n' "$1" "$2"; fail=$((fail + 1)); echo no >> "$TALLY"; }

eq() { # label expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$3] want [$2]"; fi
}

has() { # label needle haystack
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) no "$1" "[$3] does not contain [$2]" ;;
    esac
}

# A published archive on disk, reachable over file://. Two suites and two
# arches is enough to prove the loop and the qualifiers; the real one has
# three suites.
build_fixture_archive() { # dir
    local root="$1" suite arch dir qual
    for suite in trixie unstable; do
        qual=""
        [ "$suite" = trixie ] && qual='~haus13+1'
        for arch in amd64 arm64; do
            dir="$root/dists/$suite/main/binary-$arch"
            mkdir -p "$dir"
            cat > "$dir/Packages" <<EOF
Package: croc
Source: croc
Version: 11.5.3-2$qual
Architecture: $arch
Filename: pool/main/c/croc/croc_11.5.3-2${qual}_$arch.deb

Package: pkghaus-archive-keyring
Version: 2026.09.11$qual
Architecture: all
Filename: pool/main/p/pkghaus-archive-keyring/pkghaus-archive-keyring_2026.09.11${qual}_all.deb
EOF
        done
    done
}

echo "inventory: the index parser reads what the archive actually emits"
(
    # shellcheck source=scripts/inventory.sh
    . "$ROOT/scripts/inventory.sh"
    # Sourcing a script brings its `set -euo pipefail` into this subshell, and
    # a group that dies on the first non-zero status reports a failure without
    # ever printing which assertion it was. The suite drives its own errexit.
    set +e; shopt -u inherit_errexit

    stanzas() { cat <<'EOF'
Package: croc
Version: 11.5.3-2
Architecture: amd64
Filename: pool/main/c/croc/croc_11.5.3-2_amd64.deb

Package: superfile
Source: superfile (1.2.3-1)
Version: 1.2.3-1+b1
Architecture: amd64
EOF
    }
    rows="$(index_rows stanzas unused unused)"
    eq "one row per stanza" "2" "$(printf '%s\n' "$rows" | wc -l)"
    eq "source defaults to the package name" \
       "croc	11.5.3-2	croc	amd64" "$(printf '%s\n' "$rows" | head -1)"
    # A Source: field may carry "name (version)" when the source version
    # differs from the binary's, and the buildinfo path is sharded on the
    # NAME. Nothing in the fleet sets it today, and the cost of getting it
    # wrong is a URL that 404s forever.
    eq "Source: name (version) keeps only the name" \
       "superfile	1.2.3-1+b1	superfile	amd64" "$(printf '%s\n' "$rows" | tail -1)"

    # The last stanza has no blank line after it. An END-less parser drops it,
    # which reads as one fewer published package and is invisible in a count
    # of 36 versus 35.
    one() { printf 'Package: zig\nVersion: 0.16.0-3\nArchitecture: amd64\n'; }
    eq "the final stanza is not dropped" "zig	0.16.0-3	zig	amd64" \
       "$(index_rows one x y)"

    eq "an arch:all package is built on amd64" "amd64" "$(build_arch all)"
    eq "every other architecture is its own build arch" "arm64" "$(build_arch arm64)"

    eq "the buildinfo path shards on the source initial" \
       "https://buildinfos.pkg.haus/buildinfo-pool/c/croc/croc_11.5.3-2_amd64.buildinfo" \
       "$(buildinfo_url croc 11.5.3-2 amd64 croc)"
    # The arch in the filename is the BUILD arch, not the index's. Composing
    # it from the index would ask buildinfos for an _arm64 record that was
    # never built, and every arch:all package would read as unverifiable.
    eq "an arch:all record is named for the build arch" \
       "https://buildinfos.pkg.haus/buildinfo-pool/p/pkghaus-archive-keyring/pkghaus-archive-keyring_2026.09.11_amd64.buildinfo" \
       "$(buildinfo_url pkghaus-archive-keyring 2026.09.11 amd64 pkghaus-archive-keyring)"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "inventory: end to end against a published tree, no network"
(
    archive="$WORK/archive"
    build_fixture_archive "$archive"
    out="$WORK/inventory.json"
    ARCHIVE_URL="file://$archive" SUITES="trixie unstable" ARCHES="amd64 arm64" \
        "$ROOT/scripts/inventory.sh" "$out" >/dev/null 2>&1
    eq "it wrote an inventory" "yes" "$([ -s "$out" ] && echo yes || echo no)"

    read_json() { python3 -c "
import json,sys
inv=json.load(open('$out'))
$1" ; }
    eq "four targets" "4" "$(read_json 'print(len(inv["targets"]))')"
    eq "two artifacts per target" "2" "$(read_json 'print(len(inv["targets"]["trixie/amd64"]))')"
    eq "trixie carries the stable qualifier" "11.5.3-2~haus13+1" \
       "$(read_json 'print(inv["targets"]["trixie/amd64"][0]["version"])')"
    eq "unstable carries the bare version" "11.5.3-2" \
       "$(read_json 'print(inv["targets"]["unstable/amd64"][0]["version"])')"
    # The arch:all row appears in the arm64 index and still points at the
    # amd64 record.
    eq "arch:all in the arm64 index keeps its amd64 build arch" "amd64" \
       "$(read_json 'print([r for r in inv["targets"]["unstable/arm64"] if r["package"]=="pkghaus-archive-keyring"][0]["build_arch"])')"
    eq "the arch:all record URL names _amd64" "yes" \
       "$(read_json 'r=[r for r in inv["targets"]["unstable/arm64"] if r["package"]=="pkghaus-archive-keyring"][0]
print("yes" if r["buildinfo"].endswith("_2026.09.11_amd64.buildinfo") else "no")')"

    # octodns-cloudflare renders an auth error as an EMPTY zone and this is the
    # same shape: a fetch that fails, or a suite that publishes nothing, must
    # not produce an inventory reading "0 published". Coverage would then show
    # a full sweep of nothing.
    : > "$archive/dists/unstable/main/binary-arm64/Packages"
    if ARCHIVE_URL="file://$archive" SUITES="trixie unstable" ARCHES="amd64 arm64" \
        "$ROOT/scripts/inventory.sh" "$WORK/empty.json" >/dev/null 2>&1
    then empty=no; else empty=yes; fi
    eq "an empty index is fatal" "yes" "$empty"
    eq "and it wrote no inventory anyone could read" "no" \
       "$([ -s "$WORK/empty.json" ] && echo yes || echo no)"

    # A missing suite is a failed fetch, not an empty archive.
    rm -rf "$archive/dists/unstable"
    # Non-zero, not 1: pipefail surfaces curl's own status (37 for a file it
    # cannot read), and pinning the number would make this test a statement
    # about curl's exit codes rather than about the guard.
    if ARCHIVE_URL="file://$archive" SUITES="trixie unstable" ARCHES="amd64 arm64" \
        "$ROOT/scripts/inventory.sh" "$WORK/gone.json" >/dev/null 2>&1
    then unfetchable=no; else unfetchable=yes; fi
    eq "an unfetchable index is fatal" "yes" "$unfetchable"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "plan: priority, throttle, and the arch:all fold"
(
    archive="$WORK/plan-archive"
    build_fixture_archive "$archive"
    inv="$WORK/plan-inventory.json"
    ARCHIVE_URL="file://$archive" SUITES="trixie unstable" ARCHES="amd64 arm64" \
        "$ROOT/scripts/inventory.sh" "$inv" >/dev/null 2>&1

    verdict() { # suite arch package version checked_at
        mkdir -p "$WORK/state/$1/$2"
        cat > "$WORK/state/$1/$2/$3.json" <<EOF
{"package":"$3","version":"$4","suite":"$1","arch":"$2","status":"GOOD","checked_at":"$5"}
EOF
    }
    plan() { MAX_PER_LEG="${MAX_PER_LEG:-9}" "$ROOT/scripts/plan.sh" "$inv" "$WORK/state" 2>/dev/null; }
    field() { python3 -c "
import json,sys
plan=json.load(sys.stdin)
$1"; }

    rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    out="$(plan)"
    # croc is two items (one per arch) per suite; the keyring is one item with
    # two targets per suite. Four suites-arches, two suites: 4 croc + 2 keyring.
    eq "an empty state plans everything" "6" "$(printf '%s' "$out" | field 'print(len(plan["items"]))')"
    eq "arch:all folds into one item" "1" \
       "$(printf '%s' "$out" | field 'print(len([i for i in plan["items"] if i["package"]=="pkghaus-archive-keyring" and i["suite"]=="unstable"]))')"
    eq "and that item covers both arches" "unstable/amd64 unstable/arm64" \
       "$(printf '%s' "$out" | field 'print(" ".join([i for i in plan["items"] if i["package"]=="pkghaus-archive-keyring" and i["suite"]=="unstable"][0]["targets"]))')"
    eq "every planned item says why" "0" \
       "$(printf '%s' "$out" | field 'print(len([i for i in plan["items"] if not i.get("reason")]))')"
    eq "never checked is the reason on a cold start" "never checked" \
       "$(printf '%s' "$out" | field 'print(plan["items"][0]["reason"])')"

    # A current verdict does not remove an artifact, it deprioritises it: the
    # sweep still comes back round. What changes is the reason, and that is
    # what the cap below sorts on.
    verdict unstable amd64 croc 11.5.3-2 2026-09-20T10:00:00Z
    out="$(plan)"
    eq "a current verdict is a re-verify, not a gap" "re-verify" \
       "$(printf '%s' "$out" | field 'print([i for i in plan["items"] if i["package"]=="croc" and i["suite"]=="unstable" and i["build_arch"]=="amd64"][0]["reason"])')"
    # Priority decides what the cap keeps, not the order it is printed in:
    # the emitted list is re-sorted by name so a run's log reads sensibly.
    # With one slot on that leg, the unchecked package takes it.
    eq "and it loses its slot to something unchecked" "pkghaus-archive-keyring" \
       "$(MAX_PER_LEG=1 plan | field 'print([i["package"] for i in plan["items"]
if i["suite"]=="unstable" and i["build_arch"]=="amd64"][0])')"

    # The version is in the object, not the key, so a stale verdict is only
    # visible by reading it. This is the case that would otherwise leave a
    # released package showing the previous release's word forever.
    verdict unstable arm64 croc 11.0.0-1 2026-09-20T10:00:00Z
    out="$(plan)"
    has "a verdict for another version is stale" "verdict is for" \
        "$(printf '%s' "$out" | field 'print([i for i in plan["items"] if i["package"]=="croc" and i["build_arch"]=="arm64" and i["suite"]=="unstable"][0]["reason"])')"

    # A half-written object must re-verify rather than be trusted, and it must
    # say so in the words a reader can act on. Treating it as an empty record
    # instead re-verifies too, and reports the reason as "verdict is for
    # None", which sends whoever reads it looking for a version.
    printf 'not json' > "$WORK/state/unstable/amd64/croc.json"
    out="$(plan)"
    eq "an unparseable verdict counts as absent" "never checked" \
       "$(printf '%s' "$out" | field 'print([i for i in plan["items"] if i["package"]=="croc" and i["suite"]=="unstable" and i["build_arch"]=="amd64"][0]["reason"])')"

    # The throttle is per leg, not per run: six legs work in parallel and the
    # constraint is how hard one of them leans on snapshot.debian.org.
    rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    out="$(MAX_PER_LEG=1 plan)"
    eq "MAX_PER_LEG caps each leg" "1" \
       "$(printf '%s' "$out" | field '
import collections
c=collections.Counter((i["suite"],i["build_arch"]) for i in plan["items"])
print(max(c.values()))')"
    # Two suites x two build arches in this fixture, so the cap of one each
    # yields four rebuilds, not one.
    eq "and not the run" "4" "$(printf '%s' "$out" | field 'print(len(plan["items"]))')"
    eq "legs are reported for the matrix" "4" \
       "$(printf '%s' "$out" | field 'print(len(plan["legs"]))')"
    eq "a leg is a suite and an arch" "arch suite" \
       "$(printf '%s' "$out" | field 'print(" ".join(sorted(plan["legs"][0])))')"

    # Everything current, so the sweep is ordered by age alone.
    rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    verdict unstable amd64 croc 11.5.3-2 2026-09-01T00:00:00Z
    verdict trixie amd64 croc '11.5.3-2~haus13+1' 2026-09-19T00:00:00Z
    verdict unstable arm64 croc 11.5.3-2 2026-09-10T00:00:00Z
    verdict trixie arm64 croc '11.5.3-2~haus13+1' 2026-09-15T00:00:00Z
    verdict unstable amd64 pkghaus-archive-keyring 2026.09.11 2026-09-18T00:00:00Z
    verdict unstable arm64 pkghaus-archive-keyring 2026.09.11 2026-09-18T00:00:00Z
    verdict trixie amd64 pkghaus-archive-keyring '2026.09.11~haus13+1' 2026-09-17T00:00:00Z
    verdict trixie arm64 pkghaus-archive-keyring '2026.09.11~haus13+1' 2026-09-17T00:00:00Z
    out="$(MAX_PER_LEG=1 plan)"
    eq "with everything current the oldest goes first" "croc" \
       "$(printf '%s' "$out" | field 'print([i for i in plan["items"] if i["suite"]=="unstable" and i["build_arch"]=="amd64"][0]["package"])')"
    eq "and the reason says re-verify" "re-verify" \
       "$(printf '%s' "$out" | field 'print([i for i in plan["items"] if i["suite"]=="unstable" and i["build_arch"]=="amd64"][0]["reason"])')"
    # An item's age is the OLDEST of its targets. An arch:all package whose
    # two cells were written at different times must be driven by the stale
    # one, not averaged into looking fresh.
    eq "considered counts folded items, not index rows" "6" \
       "$(printf '%s' "$out" | field 'print(plan["considered"])')"

    # An UNKWN carries no information about the archive, and its commonest
    # cause is snapshot.debian.org refusing under load. Ranked with the
    # decided verdicts, one transient timeout cost a full sweep of the fleet
    # before anything looked at that artifact again.
    rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    verdict unstable amd64 croc 11.5.3-2 2026-09-20T00:00:00Z
    verdict unstable amd64 pkghaus-archive-keyring 2026.09.11 2026-09-01T00:00:00Z
    verdict unstable arm64 pkghaus-archive-keyring 2026.09.11 2026-09-01T00:00:00Z
    # croc is NEWER but UNKWN; the keyring is older and GOOD.
    python3 - "$WORK/state/unstable/amd64/croc.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
v = json.load(open(p)); v["status"] = "UNKWN"
json.dump(v, open(p, "w"))
PYEOF
    out="$(MAX_PER_LEG=1 plan)"
    eq "an UNKWN outranks an older decided verdict" "croc" \
       "$(printf '%s' "$out" | field 'print([i["package"] for i in plan["items"]
if i["suite"]=="unstable" and i["build_arch"]=="amd64"][0])')"
    eq "and says why it was picked" "last verdict was UNKWN" \
       "$(printf '%s' "$out" | field 'print([i["reason"] for i in plan["items"]
if i["suite"]=="unstable" and i["build_arch"]=="amd64"][0])')"
    # But a never-checked artifact still outranks an UNKWN: an empty cell is
    # a worse silence than an honest "could not tell".
    rm -f "$WORK/state/unstable/amd64/pkghaus-archive-keyring.json"
    out="$(MAX_PER_LEG=1 plan)"
    eq "never checked still comes before UNKWN" "pkghaus-archive-keyring" \
       "$(printf '%s' "$out" | field 'print([i["package"] for i in plan["items"]
if i["suite"]=="unstable" and i["build_arch"]=="amd64"][0])')"

    rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    verdict unstable amd64 croc 11.5.3-2 2026-09-01T00:00:00Z
    verdict trixie amd64 croc '11.5.3-2~haus13+1' 2026-09-19T00:00:00Z
    verdict unstable arm64 croc 11.5.3-2 2026-09-10T00:00:00Z
    verdict trixie arm64 croc '11.5.3-2~haus13+1' 2026-09-15T00:00:00Z
    verdict unstable amd64 pkghaus-archive-keyring 2026.09.11 2026-09-18T00:00:00Z
    verdict unstable arm64 pkghaus-archive-keyring 2026.09.11 2026-09-18T00:00:00Z
    verdict trixie amd64 pkghaus-archive-keyring '2026.09.11~haus13+1' 2026-09-17T00:00:00Z
    verdict trixie arm64 pkghaus-archive-keyring '2026.09.11~haus13+1' 2026-09-17T00:00:00Z
    out="$(ONLY_PACKAGES=croc plan)"
    eq "ONLY_PACKAGES filters" "croc" \
       "$(printf '%s' "$out" | field 'print(" ".join(sorted({i["package"] for i in plan["items"]})))')"
    eq "ONLY_PACKAGES ignores the age order" "4" \
       "$(printf '%s' "$out" | field 'print(len(plan["items"]))')"
    out="$(ONLY_PACKAGES=nosuchpackage plan)"
    eq "an unknown name plans nothing rather than everything" "0" \
       "$(printf '%s' "$out" | field 'print(len(plan["items"]))')"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "verify: reading a record"
(
    # shellcheck source=scripts/verify.sh
    . "$ROOT/scripts/verify.sh" x x x x
    # Sourcing a script brings its `set -euo pipefail` into this subshell, and
    # a group that dies on the first non-zero status reports a failure without
    # ever printing which assertion it was. The suite drives its own errexit.
    set +e; shopt -u inherit_errexit

    # Clearsigned, because every .buildinfo published since 2026-09-12 is, and
    # a parser tested only on the unsigned shape would stop at the PGP header.
    cat > "$WORK/rec.buildinfo" <<'EOF'
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

Format: 1.0
Source: croc
Checksums-Md5:
 ac1761ca2e76eee4b1702a4f219ddbd8 1156 croc_11.5.3-2.dsc
Checksums-Sha256:
 210d5811c975e205bd0ee3efe69be08d5b7291b5dde99787bbd17afe2635f1e9 1156 croc_11.5.3-2.dsc
 632c9c3a82ddcfcdad2ce7c9a6a1ca1264b809fff821728b7376813b53709e92 7186716 croc_11.5.3-2_amd64.deb
Build-Origin: Debian
Build-Architecture: amd64
EOF
    eq "the sha256 block yields both files" \
       "croc_11.5.3-2.dsc croc_11.5.3-2_amd64.deb" \
       "$(checksum_files "$WORK/rec.buildinfo" | tr '\n' ' ' | sed 's/ $//')"
    # The md5 block has the same shape and comes first. A parser that matched
    # any indented line would return the .dsc twice and the .deb never.
    eq "the md5 block is not mistaken for it" "2" \
       "$(checksum_files "$WORK/rec.buildinfo" | wc -l)"
    eq "the block ends at the next field" "0" \
       "$(checksum_files "$WORK/rec.buildinfo" | grep -c 'Build-Origin')"
    eq "a named file's checksum comes back" \
       "632c9c3a82ddcfcdad2ce7c9a6a1ca1264b809fff821728b7376813b53709e92" \
       "$(checksum_of "$WORK/rec.buildinfo" croc_11.5.3-2_amd64.deb)"
    eq "an unknown name yields nothing" "" \
       "$(checksum_of "$WORK/rec.buildinfo" nosuchfile.deb)"
    # betterlockscreen and pkghaus-archive-keyring are the fleet's two arch:all
    # packages: their record is named _amd64 and their binary _all, so the .deb
    # name has to come from the record rather than be composed.
    cat > "$WORK/all.buildinfo" <<'EOF'
Checksums-Sha256:
 aaa 719 pkghaus-archive-keyring_2026.09.11.dsc
 bbb 4024 pkghaus-archive-keyring_2026.09.11_all.deb
EOF
    eq "an arch:all record names an _all.deb" \
       "pkghaus-archive-keyring_2026.09.11_all.deb" \
       "$(checksum_files "$WORK/all.buildinfo" | grep '\.deb$')"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "verify: the three words"
(
    # shellcheck source=scripts/verify.sh
    . "$ROOT/scripts/verify.sh" x x x x
    # Sourcing a script brings its `set -euo pipefail` into this subshell, and
    # a group that dies on the first non-zero status reports a failure without
    # ever printing which assertion it was. The suite drives its own errexit.
    set +e; shopt -u inherit_errexit

    log() { printf '%s\n' "$@" > "$WORK/log"; printf '%s\n' "$WORK/log"; }

    # Captured from a real run: pkghaus-archive-keyring 2026.09.11, sid image,
    # 2026-09-21. The trailing algorithms vary by record; the anchor is the
    # line's shape.
    good="$(log 'dpkg-buildpackage: info: binary-only upload (no source included)' \
        'build artifacts stored in /p/rebuilt' \
        'checking pkghaus-archive-keyring_2026.09.11_all.deb: size... sha1... md5... sha256... all OK')"
    eq "a completed comparison that matched is GOOD" "GOOD" "$(classify 0 "$good")"
    eq "and its summary is the comparison's own word" "all OK" \
       "$(summarise_log GOOD "$good")"

    # Exit 0 alone is not a pass. debrebuild's loop skips the .dsc, so a record
    # listing nothing else exits 0 having compared nothing -- which is the
    # difference between "verified" and "did not look".
    empty="$(log 'skipping croc_11.5.3-2.dsc')"
    eq "exit 0 with nothing compared is not GOOD" "UNKWN" "$(classify 0 "$empty")"

    # The shape a real mismatch arrives in, captured 2026-09-21 by altering one
    # byte of pkghaus-archive-keyring 2026.09.11's recorded sha256 and running
    # the rebuild for real. The die lands on the END of the `checking ` line
    # because print has no newline and the two streams are merged, so a
    # pattern anchored to the start of a line -- which is what reading
    # debrebuild's source alone suggests -- matches nothing and every BAD in
    # the fleet would have been published as UNKWN.
    real="$(log 'build artifacts stored in /p/rebuilt' \
        'checking pkghaus-archive-keyring_2026.09.11_all.deb: size... md5... sha1... value of sha256 differs for pkghaus-archive-keyring_2026.09.11_all.deb')"
    eq "a captured real mismatch is BAD" "BAD" "$(classify 255 "$real")"
    eq "and the summary starts at the die, not the line" \
       "value of sha256 differs for pkghaus-archive-keyring_2026.09.11_all.deb" \
       "$(summarise_log BAD "$real")"

    # The four wordings debrebuild's comparison loop dies with, read from its
    # source. Each one means the rebuild happened and the result differed.
    for line in \
        'value of sha256 differs for croc_11.5.3-2_amd64.deb' \
        'size differs for croc_11.5.3-2_amd64.deb' \
        'different checksum files at position 1' \
        'new buildinfo contains a different number of files'
    do
        l="$(log 'checking croc_11.5.3-2_amd64.deb: size... ' "$line")"
        eq "BAD: $line" "BAD" "$(classify 1 "$l")"
        has "and it is quoted back" "${line%% *}" "$(summarise_log BAD "$l")"
    done

    # Everything debrebuild dies with BEFORE the comparison is the environment,
    # not the package. Recording it as BAD would be a claim about this archive
    # that the run cannot support -- the whole reason UNKWN exists.
    for line in \
        'apt-get install failed' \
        'dpkg-buildpackage failed' \
        'E: Failed to fetch http://snapshot.debian.org/archive/debian/... Connection timed out' \
        'debootsnap failed'
    do
        l="$(log 'some earlier output' "$line")"
        eq "UNKWN: $line" "UNKWN" "$(classify 1 "$l")"
        eq "and the reason is the last thing said" "$line" "$(summarise_log UNKWN "$l")"
    done

    # A BAD wording anywhere in the log wins over a non-zero exit with no
    # explanation, and a GOOD line does not rescue a comparison that then died.
    mixed="$(log 'checking a.deb: size... sha256... all OK' \
        'value of sha256 differs for b.deb')"
    eq "one differing file is BAD even beside a matching one" "BAD" "$(classify 1 "$mixed")"

    : > "$WORK/log"
    eq "an empty log is UNKWN, not a crash" "UNKWN" "$(classify 1 "$WORK/log")"
    has "and it says so" "no output" "$(summarise_log UNKWN "$WORK/log")"

    # 300 characters. A debrebuild failure can print a whole apt transcript on
    # one line, and the reason is rendered into a table cell.
    python3 -c 'print("x" * 5000)' > "$WORK/log"
    eq "a runaway reason is truncated" "300" \
       "$(summarise_log UNKWN "$WORK/log" | tr -d '\n' | wc -c | tr -d ' ')"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "verify: the verdict object is what the worker reads"
(
    # shellcheck source=scripts/verify.sh
    . "$ROOT/scripts/verify.sh" x x x x
    # Sourcing a script brings its `set -euo pipefail` into this subshell, and
    # a group that dies on the first non-zero status reports a failure without
    # ever printing which assertion it was. The suite drives its own errexit.
    set +e; shopt -u inherit_errexit

    out="$WORK/v.json"
    VERIFY_RUN_URL="https://example.invalid/run/1" \
    emit_verdict "$out" croc 11.5.3-2 unstable amd64 GOOD \
        https://buildinfos.pkg.haus/x.buildinfo 'all OK' '' deadbeef deadbeef \
        4096 4096
    read_json() { python3 -c "
import json
v=json.load(open('$out'))
$1"; }
    eq "it parses" "0" "$?"
    # Every field the Worker reads. A renamed key here renders an empty cell
    # rather than an error, which is the failure mode that survives review.
    eq "the worker's fields are all present" \
       "arch buildinfo checked_at debrebuild package rebuilt_sha256 rebuilt_size recorded_sha256 recorded_size run status suite unknown_reason version" \
       "$(read_json 'print(" ".join(sorted(v)))')"
    eq "the timestamp carries seconds and a zone" "yes" \
       "$(read_json '
import re
print("yes" if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", v["checked_at"]) else "no")')"
    eq "an absent reason is null, not the empty string" "None" \
       "$(read_json 'print(v["unknown_reason"])')"
    eq "the run is recorded so a verdict can be traced" "https://example.invalid/run/1" \
       "$(read_json 'print(v["run"])')"

    VERIFY_RUN_URL="" emit_verdict "$out" croc 11.5.3-2 unstable amd64 UNKWN \
        https://x/y '' 'snapshot.debian.org timed out' '' '' '' ''
    eq "an unset run url is null rather than empty" "None" "$(read_json 'print(v["run"])')"
    eq "and the reason survives" "snapshot.debian.org timed out" \
       "$(read_json 'print(v["unknown_reason"])')"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "publish: what it refuses to upload"
(
    # shellcheck source=scripts/publish.sh
    . "$ROOT/scripts/publish.sh" x
    # Sourcing a script brings its `set -euo pipefail` into this subshell, and
    # a group that dies on the first non-zero status reports a failure without
    # ever printing which assertion it was. The suite drives its own errexit.
    set +e; shopt -u inherit_errexit

    mkdir -p "$WORK/pub/unstable/amd64"
    eq "an empty tree is refused" "1" \
       "$(validate_verdicts "$WORK/pub" >/dev/null 2>&1; echo $?)"
    eq "a missing tree is refused too" "1" \
       "$(validate_verdicts "$WORK/nosuchdir" >/dev/null 2>&1; echo $?)"

    printf '{"package":"croc"}' > "$WORK/pub/unstable/amd64/croc.json"
    eq "a valid tree passes and reports its count" "1" \
       "$(validate_verdicts "$WORK/pub" 2>/dev/null)"

    # A truncated upload would be dropped by the Worker's reader, and the
    # artifact would read as never checked rather than as broken.
    printf '{"package":' > "$WORK/pub/unstable/amd64/zola.json"
    eq "one unparseable verdict fails the whole upload" "1" \
       "$(validate_verdicts "$WORK/pub" >/dev/null 2>&1; echo $?)"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "deploy-time route assertion"
(
    # check-routes.py is copied verbatim into six repos and its tests live
    # here. The comparison is a pure function precisely so this needs no
    # network, no token and no zone.
    rt() { # script declared-json routes-json
        python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "cr", pathlib.Path(__file__).parent if False else "scripts/check-routes.py")
cr = importlib.util.module_from_spec(spec); spec.loader.exec_module(cr)
out = cr.problems(sys.argv[1], "wrangler.toml",
                  set(json.loads(sys.argv[2])), json.loads(sys.argv[3]))
print("\n".join(out) if out else "OK")
PYEOF
    }
    live() { printf '[{"pattern":"a/*","script":"w","request_limit_fail_open":false}]'; }

    eq "declared and live agree" "OK" "$(rt w '["a/*"]' "$(live)")"

    # The direction that nobody notices: a route added by hand keeps working,
    # so nothing complains and the config quietly stops describing production.
    # This is the pkg.haus/zk/* case, reproduced.
    has "a live route missing from the config fails" "absent from" \
        "$(rt w '["a/*"]' '[{"pattern":"a/*","script":"w"},{"pattern":"b/*","script":"w"}]')"
    has "  and it names the route" "b/*" \
        "$(rt w '["a/*"]' '[{"pattern":"a/*","script":"w"},{"pattern":"b/*","script":"w"}]')"
    has "  and says to add it, not delete it" "do not delete" \
        "$(rt w '["a/*"]' '[{"pattern":"a/*","script":"w"},{"pattern":"b/*","script":"w"}]')"

    has "a declared route that did not deploy fails" "declared but not live" \
        "$(rt w '["a/*","c/*"]' "$(live)")"

    # There is no wrangler field for fail-open, so a route created after the
    # 2026-09-04 sweep starts at whatever Cloudflare defaults to.
    has "fail-open ON fails" "fail-open is ON" \
        "$(rt w '["a/*"]' '[{"pattern":"a/*","script":"w","request_limit_fail_open":true}]')"
    has "  and names the route" "a/*" \
        "$(rt w '["a/*"]' '[{"pattern":"a/*","script":"w","request_limit_fail_open":true}]')"

    # Another Worker's routes are not ours to police, and must not be read as
    # ours either.
    eq "a sibling Worker's routes are ignored" "OK" \
       "$(rt w '["a/*"]' '[{"pattern":"a/*","script":"w"},{"pattern":"z/*","script":"other"}]')"

    # Zero is not a pass. Both of these compare equal-and-empty.
    has "a config with no routes is refused" "declares no routes" \
        "$(rt w '[]' "$(live)")"
    has "no live route for this script is refused" "no live route is bound" \
        "$(rt w '["a/*"]' '[{"pattern":"z/*","script":"other"}]')"
    has "  and it says which scripts the zone does have" "other" \
        "$(rt w '["a/*"]' '[{"pattern":"z/*","script":"other"}]')"

    # Both directions at once must report both, not stop at the first.
    both="$(rt w '["a/*","c/*"]' '[{"pattern":"a/*","script":"w"},{"pattern":"b/*","script":"w"}]')"
    has "both directions are reported: missing" "declared but not live" "$both"
    has "both directions are reported: undeclared" "absent from" "$both"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "the rolled-up index"
(
    set +e; shopt -u inherit_errexit
    W="$WORK/roll"; rm -rf "$W"; mkdir -p "$W/trixie/amd64" "$W/unstable/arm64"
    printf '{"package":"croc","status":"GOOD","suite":"trixie","arch":"amd64"}' > "$W/trixie/amd64/croc.json"
    printf '{"package":"zola","status":"BAD","suite":"unstable","arch":"arm64"}'  > "$W/unstable/arm64/zola.json"

    "$ROOT/scripts/roll-index.py" "$W" "$WORK/idx.json" 2>/dev/null
    eq "it rolls every verdict in the tree" "2" \
       "$(python3 -c "import json;print(len(json.load(open('$WORK/idx.json'))['verdicts']))")"
    eq "and stamps when" "yes" \
       "$(python3 -c "
import json,re
d=json.load(open('$WORK/idx.json'))
print('yes' if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', d['generated_at']) else 'no')")"

    # A half-written object must not take the whole index down with it, and
    # must not appear in it either.
    printf '{"package":' > "$W/trixie/amd64/broken.json"
    "$ROOT/scripts/roll-index.py" "$W" "$WORK/idx2.json" 2>/dev/null
    eq "one unparseable verdict is dropped, the rest survive" "2" \
       "$(python3 -c "import json;print(len(json.load(open('$WORK/idx2.json'))['verdicts']))")"

    # An index built from nothing renders the page as a fleet where nothing
    # has been verified - the one false negative this surface must not emit.
    rm -rf "$W"; mkdir -p "$W"
    if "$ROOT/scripts/roll-index.py" "$W" "$WORK/idx3.json" >/dev/null 2>&1
    then empty=no; else empty=yes; fi
    eq "an empty tree is refused" "yes" "$empty"
    eq "  and it wrote no index to serve" "no" \
       "$([ -s "$WORK/idx3.json" ] && echo yes || echo no)"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
echo "conventions that nothing else asserts"
(
    eq "there are scripts to search" "yes" \
       "$([ "$(find "$ROOT/scripts" -name '*.sh' | wc -l)" -gt 0 ] && echo yes || echo no)"

    # Our own reads of the archive are not counted. Every fetch this repo makes
    # goes to apt.pkg.haus or buildinfos.pkg.haus, and a sweep of 216 artifacts
    # is exactly the shape the marker exists for.
    #
    # Whole invocations, continuation lines joined. A line-at-a-time grep gets
    # this wrong in both directions: `-A "$UA"` sits on the second line of one
    # helper, and the `UA=` default itself contains the word curl.
    # shellcheck disable=SC2016  # the literal $UA is what is being searched for
    unmarked() {
        awk '''
            /^[[:space:]]*curl /{
                cmd = $0
                while (cmd ~ /\\$/) { if ((getline nxt) <= 0) break; cmd = cmd nxt }
                if (cmd !~ /-A "\$UA"/) print FILENAME ": " cmd
            }
        ''' "$ROOT"/scripts/*.sh
    }
    eq "there are curl invocations to check" "2" \
       "$(grep -hc '^[[:space:]]*curl ' "$ROOT"/scripts/*.sh | paste -sd+ | bc)"
    eq "every one of them carries the pkghaus-ci marker" "" "$(unmarked)"

    # The verifier must not be able to write to what it verifies. Both files
    # NAME the archive's bucket in a comment saying why they do not use it, so
    # this counts executable lines rather than mentions.
    eq "no executable line names the archive's bucket" "0" \
       "$(grep -rn 'pkghaus-apt' "$ROOT/scripts" "$ROOT/worker/wrangler.toml" \
          | grep -vc '^[^:]*:[0-9]*:[[:space:]]*#')"
    eq "the worker binds the verifier's own bucket" "1" \
       "$(grep -c 'bucket_name = "pkghaus-reproducible"' "$ROOT/worker/wrangler.toml")"

    # verify/ is a byte-identical copy of pkghaus/apt's. The `twins` job in CI
    # diffs it against the published original; this only checks the copy is
    # still here, because a deleted file would make that job pass by fetching
    # and comparing nothing.
    eq "the rebuild harness is present" "2" \
       "$(find "$ROOT/verify" -maxdepth 1 -type f \( -name rebuild.sh -o -name Dockerfile \) | wc -l)"
    # Nothing inside those two files may mark them as twins. A header saying so
    # is itself a change to them, which is drift until pkghaus/apt merges the
    # same header -- measured on this repo's first push, where exactly that
    # turned the twins job red. The note belongs in both READMEs.
    eq "and nothing inside them claims to be a twin" "0" \
       "$(grep -lc 'TWIN' "$ROOT/verify/rebuild.sh" "$ROOT/verify/Dockerfile" 2>/dev/null | wc -l)"
    has "while the README does say so" "byte-identical" "$(cat "$ROOT/README.md")"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo "a BAD carries the evidence needed to diagnose it"
(
    # shellcheck source=scripts/verify.sh
    . "$ROOT/scripts/verify.sh" x x x x
    set +e; shopt -u inherit_errexit

    # A real record's shape, clearsigned like every one published since
    # 2026-09-12. Field 2 is the size; this is the line zola's own arm64
    # record carries.
    rec="$(mktemp)"
    cat > "$rec" <<'BIFIX'
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

Format: 1.0
Checksums-Sha256:
 b96e8d26ef3fea7c35b442dbcd9e4e28bc16ae84c21fc03231fb10db7336c381 1143 zola_0.23.6-3.dsc
 5ced33258b9f1a51517e4eb1dcc4cd3a9e671b290e85621c11a8b0b0ae947d74 10569132 zola_0.23.6-3_arm64.deb
Build-Path: /build
BIFIX

    eq "size_of reads the recorded size" \
       "10569132" "$(size_of "$rec" zola_0.23.6-3_arm64.deb)"
    eq "size_of and checksum_of read the same line" \
       "5ced33258b9f1a51517e4eb1dcc4cd3a9e671b290e85621c11a8b0b0ae947d74" \
       "$(checksum_of "$rec" zola_0.23.6-3_arm64.deb)"
    eq "size_of on the .dsc, not just the .deb" \
       "1143" "$(size_of "$rec" zola_0.23.6-3.dsc)"
    # A name not in the block yields nothing rather than the wrong file's size.
    eq "size_of refuses a name the record does not carry" \
       "" "$(size_of "$rec" nosuch_1.0_amd64.deb)"
    # The block ends at the first unindented line; Build-Path must not be read
    # as a checksum row.
    eq "size_of stops at the end of the block" \
       "" "$(size_of "$rec" Build-Path:)"

    # The verdict carries both sizes, as integers rather than strings, so a
    # consumer can subtract them without parsing.
    out="$(mktemp)"
    emit_verdict "$out" zola 0.23.6-3 unstable arm64 BAD \
        https://example.invalid/z.buildinfo "size differs for z.deb" "" \
        a4b9001e 5ced3325 10569260 10569132
    python3 - "$out" <<'PYV'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["rebuilt_size"] == 10569260, d
assert d["recorded_size"] == 10569132, d
assert isinstance(d["rebuilt_size"], int), type(d["rebuilt_size"])
PYV
    eq "the verdict carries both sizes as integers" "0" "$?"

    # Absent sizes stay null. Every verdict written before these fields
    # existed has none, and a "" would become 0 and render as a real delta.
    emit_verdict "$out" zola 0.23.6-3 unstable arm64 UNKWN \
        https://example.invalid/z.buildinfo "" "no record" "" "" "" ""
    python3 - "$out" <<'PYN'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["rebuilt_size"] is None and d["recorded_size"] is None, d
PYN
    eq "absent sizes are null, not zero" "0" "$?"
    rm -f "$rec" "$out"
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo "only a BAD keeps its rebuilt artifact"
(
    set +e; shopt -u inherit_errexit
    vs="$(cat "$ROOT/scripts/verify.sh")"

    # The copy must be gated on the verdict. Keeping a GOOD would upload a
    # byte-identical copy of a file the archive already serves, on every run.
    # No '$' in the pattern: shellcheck reads it as a missed expansion
    # (SC2016) and this repo's lint has no severity filter.
    cp_at="$(printf '%s\n' "$vs" | grep -n 'cp .*built.*EVIDENCE' | head -1 | cut -d: -f1)"
    gate_at="$(printf '%s\n' "$vs" | grep -n 'verdict" = BAD' \
               | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)"
    if [ -n "$cp_at" ] && [ -n "$gate_at" ] && [ "$gate_at" -lt "$cp_at" ]; then
        ok "the rebuilt artifact is copied only under a BAD gate"
    else
        no "the rebuilt artifact is copied only under a BAD gate" \
           "gate at ${gate_at:-none}, cp at ${cp_at:-none}"
    fi

    # And the workflow has to collect it, or the copy dies with the runner.
    wf="$(cat "$ROOT/.github/workflows/verify.yml")"
    case "$wf" in
        *"path: evidence/"*) ok "the workflow uploads the evidence directory" ;;
        *) no "the workflow uploads the evidence directory" "no evidence path in verify.yml" ;;
    esac
    # ignore, not error: most legs produce no BAD and an absent directory is
    # the healthy case here, unlike the verdicts upload beside it.
    ev="$(printf '%s\n' "$wf" | sed -n '/name: evidence-/,/if-no-files-found/p')"
    case "$ev" in
        *"if-no-files-found: ignore"*) ok "an empty evidence directory is not a failure" ;;
        *) no "an empty evidence directory is not a failure" "block was [$ev]" ;;
    esac
    # The verdicts upload must still be strict; a blanket relaxation would
    # undo the assertion that a leg which planned work produced some.
    # Scoped to the verdicts upload. verify.yml has two strict uploads, plan
    # and verdicts, so a bare count read 2 and said nothing about which.
    vb="$(printf '%s\n' "$wf" | sed -n '/name: verdicts-/,/if-no-files-found/p')"
    case "$vb" in
        *"if-no-files-found: error"*) ok "the verdicts upload still errors on empty" ;;
        *) no "the verdicts upload still errors on empty" "block was [$vb]" ;;
    esac
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo "a BAD is not cleared by a later non-BAD verdict"
(
    set +e; shopt -u inherit_errexit

    sb="$ROOT/scripts/sticky-bad.py"
    eq "sticky-bad.py exists" "yes" "$([ -f "$sb" ] && echo yes || echo no)"

    # new-status prior-status same-version -> writes the pair and runs the merge.
    # Returns the resulting status, and sets STICKY_JSON to the whole object.
    run_sticky() { # new_status prior_status new_version prior_version [prior_extra]
        local nd pd
        nd="$(mktemp -d)"; pd="$(mktemp -d)"
        mkdir -p "$nd/testing/arm64" "$pd/testing/arm64"
        python3 - "$nd/testing/arm64/zola.json" "$1" "$3" <<'PYNEW'
import json, sys
json.dump({"package": "zola", "suite": "testing", "arch": "arm64",
           "status": sys.argv[2], "version": sys.argv[3],
           "checked_at": "2026-09-21T18:00:00Z",
           "run": "https://example.invalid/new"},
          open(sys.argv[1], "w"), indent=2, sort_keys=True)
PYNEW
        python3 - "$pd/testing/arm64/zola.json" "$2" "$4" "${5:-}" <<'PYOLD'
import json, sys
obj = {"package": "zola", "suite": "testing", "arch": "arm64",
       "status": sys.argv[2], "version": sys.argv[3],
       "checked_at": "2026-09-21T16:56:44Z",
       "run": "https://example.invalid/old"}
if sys.argv[4] == "flapped":
    obj["flapped"] = True
json.dump(obj, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PYOLD
        python3 "$sb" "$nd" "$pd" >/dev/null 2>&1
        STICKY_JSON="$(cat "$nd/testing/arm64/zola.json")"
        printf '%s' "$STICKY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'
        rm -rf "$nd" "$pd"
    }

    # The rule itself.
    eq "a GOOD does not clear a BAD on the same version" \
       "BAD" "$(run_sticky GOOD BAD 1.0-1 1.0-1)"
    eq "an UNKWN does not clear a BAD either" \
       "BAD" "$(run_sticky UNKWN BAD 1.0-1 1.0-1)"

    # A new version is a new artifact. Without this a fixed package would stay
    # red forever and the only way out would be editing the bucket by hand.
    eq "a GOOD on a NEW version does clear the BAD" \
       "GOOD" "$(run_sticky GOOD BAD 1.0-2 1.0-1)"

    # Nothing else is made sticky: a GOOD must be replaceable or the page
    # freezes at the first sweep.
    eq "a BAD replaces a prior GOOD" \
       "BAD" "$(run_sticky BAD GOOD 1.0-1 1.0-1)"
    eq "a GOOD replaces a prior GOOD" \
       "GOOD" "$(run_sticky GOOD GOOD 1.0-1 1.0-1)"
    eq "a GOOD replaces a prior UNKWN" \
       "GOOD" "$(run_sticky GOOD UNKWN 1.0-1 1.0-1)"

    # flapped is the load-bearing bit: it separates "this package never
    # reproduces" from "this package reproduces sometimes", which for zola is
    # the entire finding.
    run_sticky GOOD BAD 1.0-1 1.0-1 >/dev/null
    case "$STICKY_JSON" in
        *'"flapped": true'*) ok "a BAD survived by a GOOD is marked flapped" ;;
        *) no "a BAD survived by a GOOD is marked flapped" "json was [$STICKY_JSON]" ;;
    esac
    case "$STICKY_JSON" in
        *'"last_rebuild_status": "GOOD"'*) ok "and records what the later rebuild said" ;;
        *) no "and records what the later rebuild said" "json was [$STICKY_JSON]" ;;
    esac

    # An UNKWN is not a matching rebuild, so it must NOT claim the build
    # flapped -- that would turn a snapshot.debian.org outage into a
    # non-determinism finding.
    run_sticky UNKWN BAD 1.0-1 1.0-1 >/dev/null
    case "$STICKY_JSON" in
        *'"flapped": true'*) no "an UNKWN does not mark the BAD flapped" "json was [$STICKY_JSON]" ;;
        *) ok "an UNKWN does not mark the BAD flapped" ;;
    esac

    # Once seen, non-determinism is not forgotten by a later repeat failure.
    run_sticky BAD BAD 1.0-1 1.0-1 flapped >/dev/null
    case "$STICKY_JSON" in
        *'"flapped": true'*) ok "flapped is carried forward across a repeat BAD" ;;
        *) no "flapped is carried forward across a repeat BAD" "json was [$STICKY_JSON]" ;;
    esac

    # publish.sh must actually call it, and BEFORE the upload -- afterwards the
    # BAD is already gone and the merge reads what it just overwrote.
    pub="$(cat "$ROOT/scripts/publish.sh")"
    # Comments excluded, same idiom as apt's -force-replace check. The header
    # comment names scripts/sticky-bad.py thirty lines above the call, so a
    # bare head -1 measured the comment and the ordering assertion passed
    # whatever the code did -- caught by mutating the call's position and
    # seeing nothing fail.
    sticky_at="$(printf '%s\n' "$pub" | grep -n 'sticky-bad.py' \
                 | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)"
    # No '$' in the pattern: shellcheck reads it as a missed expansion (SC2016)
    # and the repo's lint has no severity filter. 'sync .*VERDICT_DIR' matches
    # the upload line only -- the prior-state sync names no VERDICT_DIR and the
    # sticky-bad.py call has no 'sync'.
    upload_at="$(printf '%s\n' "$pub" | grep -n 'sync .*VERDICT_DIR' | head -1 | cut -d: -f1)"
    if [ -n "$sticky_at" ] && [ -n "$upload_at" ] && [ "$sticky_at" -lt "$upload_at" ]; then
        ok "publish.sh runs sticky-bad.py before uploading"
    else
        no "publish.sh runs sticky-bad.py before uploading" \
           "sticky at ${sticky_at:-none}, upload at ${upload_at:-none}"
    fi
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo "the diagnostic names a symbol without changing what it measures"
(
    set +e; shopt -u inherit_errexit
    dg="$ROOT/scripts/diagnose.sh"
    eq "diagnose.sh exists and is executable" "yes" \
       "$([ -x "$dg" ] && echo yes || echo no)"

    # The load-bearing edit, run as the shipped script runs it. Extracted from
    # diagnose.sh rather than copied here, so a change to the real regex is
    # what this exercises.
    edit="$(mktemp)"
    awk '/^python3 - "\$inputs\/\$name" <<.PY.$/{f=1;next} f&&/^PY$/{exit} f' "$dg" > "$edit"
    eq "the nostrip edit was extracted from the shipped script" "yes" \
       "$([ -s "$edit" ] && echo yes || echo no)"

    rec="$(mktemp)"
    cat > "$rec" <<'BIFIX'
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

Format: 1.0
Environment:
 DEB_BUILD_OPTIONS="parallel=4 noautodbgsym"
 SOURCE_DATE_EPOCH="1789560674"
BIFIX
    python3 "$edit" "$rec" >/dev/null 2>&1
    got="$(grep 'DEB_BUILD_OPTIONS' "$rec")"

    # Appended, not replaced. parallel= and noautodbgsym are part of how the
    # original was built; dropping them would change what is being compared,
    # which would make the symbol a statement about a different binary.
    case "$got" in
        *'parallel=4'*) ok "the recorded options survive the edit" ;;
        *) no "the recorded options survive the edit" "line is [$got]" ;;
    esac
    case "$got" in
        *nostrip*) ok "and nostrip is added" ;;
        *) no "and nostrip is added" "line is [$got]" ;;
    esac
    eq "SOURCE_DATE_EPOCH is untouched" "1" \
       "$(grep -c 'SOURCE_DATE_EPOCH="1789560674"' "$rec")"

    # nostrip alone is not enough for a Rust package. zola's upstream manifest
    # carries `[profile.release] strip = true`, so cargo strips at link time
    # and dh_strip never sees symbols to keep -- the first diagnostic run came
    # back stripped and said so. Both levers, or the answer is "no enclosing
    # function" from a binary that has no symbols at all.
    eq "the cargo strip override is added too" "1" \
       "$(grep -c 'CARGO_PROFILE_RELEASE_STRIP="none"' "$rec")"
    # One leading space, matching its siblings: debrebuild splits the field by
    # line and each line on the first '=', so a line without it parses as a
    # name that is not a variable.
    eq "and it keeps the block's one-space continuation shape" "1" \
       "$(grep -c '^ CARGO_PROFILE_RELEASE_STRIP=' "$rec")"

    # Idempotent: a second pass must not append it twice, or the record grows
    # a token per run and stops matching what it claims to replay.
    python3 "$edit" "$rec" >/dev/null 2>&1
    eq "running the edit twice adds nostrip once" "1" \
       "$(grep -o 'nostrip' "$rec" | wc -l | tr -d ' ')"
    eq "and the cargo override once" "1" \
       "$(grep -c 'CARGO_PROFILE_RELEASE_STRIP' "$rec")"

    # A record with nothing to extend must fail loudly rather than build
    # something that is silently still stripped.
    bad="$(mktemp)"; printf 'Format: 1.0\nEnvironment:\n SOURCE_DATE_EPOCH="1"\n' > "$bad"
    python3 "$edit" "$bad" >/dev/null 2>&1
    eq "a record without DEB_BUILD_OPTIONS is refused" "1" "$?"
    rm -f "$edit" "$rec" "$bad"

    body="$(cat "$dg")"
    # The answer is only as good as the claim that both builds laid out .text
    # the same way, so the script has to check that rather than assume it.
    # Two builds, diffed against each other. A single build mapped against the
    # published one is a cross-build offset translation, and it was wrong:
    # keeping symbols moved .text by 19,456 bytes on zola/arm64, so the
    # offset pointed at different code.
    eq "it builds twice" "1" \
       "$(printf '%s\n' "$body" | grep -c '^for i in 1 2; do')"
    case "$body" in
        *"no offset has to be"*|*"cross-build offset translation"*|*"Two builds in one configuration"*)
            ok "and says why one build against the published one is wrong" ;;
        *) no "and says why one build against the published one is wrong" "rationale absent" ;;
    esac
    # An identical pair is a RESULT, not a failure: this package flaps about
    # half the time, so half of all runs legitimately catch nothing.
    case "$body" in
        *IDENTICAL*) ok "an identical pair is reported rather than failed" ;;
        *) no "an identical pair is reported rather than failed" "no identical branch" ;;
    esac
    # A length change is more than register flap and has to be called out, or
    # a reader takes a section-size difference for a code difference.
    case "$body" in
        *"differ in LENGTH"*) ok "a length difference is distinguished from byte flap" ;;
        *) no "a length difference is distinguished from byte flap" "no length branch" ;;
    esac
    # The offset-to-symbol step must resolve against one of the two builds it
    # compared, never a third binary.
    # Double quotes with \$ rather than single quotes: a '$' inside single
    # quotes is SC2016, and this repo's lint has no severity filter.
    case "$body" in
        *"python3 - \"\$a\" \"\$b\""*)
            ok "symbols are resolved from the compared builds themselves" ;;
        *) no "symbols are resolved from the compared builds themselves" "resolves elsewhere" ;;
    esac

    # verify.sh assigns OUTDIR and ROOT from its own arguments before the
    # guard that makes it sourceable, so a sourcing script that keeps state
    # under those names has it silently overwritten. It did: output went to
    # `x/` and the upload failed after a twelve-minute rebuild.
    clash="$(comm -12 \
        <(awk '/^if \[ "\$\{BASH_SOURCE\[0\]\}" != "\$\{0\}" \]/{exit} /^[A-Z_]+=/{sub(/=.*/,""); print}' \
            "$ROOT/scripts/verify.sh" | sort -u) \
        <(awk '/^[A-Z_]+=/{sub(/=.*/,""); print}' "$dg" | sort -u) | tr '\n' ' ')"
    eq "diagnose.sh assigns no variable verify.sh clobbers" "" "$(printf '%s' "$clash" | tr -d ' ')"
    # And it must refuse a build that came back stripped anyway, which is the
    # silent-failure shape: a symbol lookup on a stripped binary finds nothing
    # and would read as "no enclosing function".
    case "$body" in
        *"stripped, so no symbol can be resolved"*)
            ok "a rebuild that came back stripped is fatal" ;;
        *) no "a rebuild that came back stripped is fatal" "no guard found" ;;
    esac
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo "the diagnostic workflow builds natively and keeps what it produces"
(
    set +e; shopt -u inherit_errexit
    wf="$ROOT/.github/workflows/diagnose.yml"
    eq "diagnose.yml exists" "yes" "$([ -f "$wf" ] && echo yes || echo no)"
    body="$(cat "$wf")"

    # Native arm, never QEMU: a cross-emulated build takes hours and the whole
    # point is to reproduce one architecture's code layout.
    case "$body" in
        *"ubuntu-24.04-arm"*) ok "arm64 runs on a native arm runner" ;;
        *) no "arm64 runs on a native arm runner" "no ubuntu-24.04-arm" ;;
    esac
    # Manual only. A schedule would spend the snapshot.debian.org budget the
    # verifier rations, to answer a question nobody asked.
    eq "it is dispatch-only, with no schedule" "0" \
       "$(printf '%s\n' "$body" | grep -c '^  schedule:')"
    # Here an empty artifact IS a failure, unlike the evidence upload in
    # verify.yml: this workflow exists to produce those files.
    case "$body" in
        *"if-no-files-found: error"*) ok "producing nothing is a failure here" ;;
        *) no "producing nothing is a failure here" "not strict" ;;
    esac
    exit $((fail > 0))
) || groups_failed=$((groups_failed + 1))

echo
ran="$(wc -l < "$TALLY")"
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
    echo "FAIL: $ran assertions ran, expected $EXPECTED_ASSERTIONS."
    echo "      An assertion was skipped, not failed -- look for a group that"
    echo "      exited early, a renamed helper, or a fixture that stopped being"
    echo "      built. If the change was deliberate, update EXPECTED_ASSERTIONS."
    exit 1
fi

if [ "$groups_failed" -eq 0 ]; then
    echo "all $ran assertions passed"
else
    echo "$groups_failed failing test group(s)"
fi
exit $((groups_failed > 0))
