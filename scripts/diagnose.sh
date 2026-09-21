#!/usr/bin/env bash
#
# Name the functions a non-deterministic build disagrees with itself about.
#
#   scripts/diagnose.sh <buildinfo-url> <outdir>
#
# Builds the same record TWICE with symbols kept, diffs the two binaries
# against each other, and resolves every differing byte in .text to the symbol
# that contains it.
#
# Why twice, and not against the published build. The first version built once
# and mapped an offset taken from a published-versus-rebuilt diff. That is a
# cross-build offset translation, valid only if both binaries laid .text out
# identically. They did not: measured 2026-09-21 on zola/arm64, the diagnostic
# build's .text came out 19,456 bytes longer than the published one, so the
# offset pointed at different code and the symbol it produced was withdrawn.
# Keeping symbols can perturb what LTO internalises and what the linker
# collects, so ANY build that retains them risks disturbing what it measures.
#
# Two builds in one configuration removes the translation. Both halves share a
# layout by construction, both carry symbols, and a differing byte maps to a
# symbol in the same build family. Nothing has to be assumed about the
# published binary at all.
#
# What this establishes, and what it does not. It names the function that
# flapped in THIS configuration, which is a proxy for the shipped one, since
# keeping symbols is itself a change. The proxy is closed by verification
# rather than by argument: apply the fix, then require the published page to
# report GOOD on every leg. On a leg known to flap that means about five
# consecutive GOODs, because two in a row on a half-failing leg happen a
# quarter of the time by luck.
#
# A pair can come back identical. zola/arm64 fails roughly half the time, so
# that is the expected outcome about half of all runs. It is reported as a
# result, not an error. Run it again.
#
# Never publish a package built this way. DEB_BUILD_OPTIONS is recorded in
# .buildinfo, so a nostrip build is self-identifying and wrong to ship.

set -euo pipefail
shopt -s inherit_errexit

DIAG_URL="${1:?usage: $0 <buildinfo-url> <outdir>}"
DIAG_OUTDIR="${2:?usage: $0 <buildinfo-url> <outdir>}"

DIAG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# DIAG_ prefixes, and they are not decoration. verify.sh assigns OUTDIR and
# ROOT from its own arguments at the top of the file, before the guard that
# makes it sourceable, so the placeholders below OVERWRITE anything this
# script has already put there. An earlier version kept its output directory
# in OUTDIR; every run wrote to `x/` while the workflow looked in `out/` and
# failed the upload after a twelve-minute rebuild.
#
# shellcheck source=scripts/verify.sh
. "$DIAG_ROOT/scripts/verify.sh" x x x x

mkdir -p "$DIAG_OUTDIR"
DIAG_OUTDIR="$(cd "$DIAG_OUTDIR" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

base="${DIAG_URL%/*}"
name="${DIAG_URL##*/}"
inputs="$work/inputs"
mkdir -p "$inputs"

echo "fetching the record and its source" >&2
fetch "$DIAG_URL" "$inputs/$name"
dsc="$(checksum_files "$inputs/$name" | grep '\.dsc$' | head -1)"
[ -n "$dsc" ] || { echo "FATAL: the record names no .dsc" >&2; exit 1; }
fetch "$base/$dsc" "$inputs/$dsc"
for f in $(checksum_files "$inputs/$dsc"); do
    fetch "$base/$f" "$inputs/$f"
done

# Two settings, both needed, in this order. nostrip stops dh_strip.
# CARGO_PROFILE_RELEASE_STRIP stops cargo, which for a Rust package whose
# upstream manifest carries `[profile.release] strip = true` has already
# removed the symbols at LINK time before dh_strip sees anything. zola does,
# and an earlier run that set only nostrip came back stripped.
#
# Appended to the RECORDED options rather than replacing them: parallel= and
# noautodbgsym are part of how the original was built.
#
# The .dsc cannot be patched instead: debrebuild verifies it against the
# checksums in this record and refuses an edited one. The record itself can be
# edited because debrebuild states it discards the signature without verifying.
python3 - "$inputs/$name" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
m = re.search(r'^( DEB_BUILD_OPTIONS=")([^"]*)(")$', s, re.M)
if not m:
    sys.exit("FATAL: the record has no DEB_BUILD_OPTIONS to extend")
changed = []
if "nostrip" not in m.group(2).split():
    s = s[:m.start()] + m.group(1) + m.group(2) + " nostrip" + m.group(3) + s[m.end():]
    changed.append("DEB_BUILD_OPTIONS += nostrip")
if "CARGO_PROFILE_RELEASE_STRIP" not in s:
    # Same one-leading-space shape as its siblings: debrebuild splits the
    # field by line and each line on the first '=', so any name works but a
    # line without the space parses as a name that is not a variable.
    m2 = re.search(r'^( DEB_BUILD_OPTIONS="[^"]*")$', s, re.M)
    s = s[:m2.end()] + '\n CARGO_PROFILE_RELEASE_STRIP="none"' + s[m2.end():]
    changed.append('CARGO_PROFILE_RELEASE_STRIP="none"')
if changed:
    open(p, "w", encoding="utf-8").write(s)
    for c in changed:
        print(f"  record: {c}", file=sys.stderr)
else:
    print("  the record already asks for both", file=sys.stderr)
PY

# The binary under test: the largest ELF in the package, which for every Rust
# and Go package here is the program itself.
extract_binary() { # build-dir -> path on stdout
    local d="$1" built unpack
    built="$(find "$d/rebuilt" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null || true)"
    [ -n "$built" ] || return 1
    unpack="$d/unpack"; mkdir -p "$unpack"
    dpkg-deb --fsys-tarfile "$built" | tar -xf - -C "$unpack"
    # -printf rather than a pipe into xargs: no word splitting, and the size
    # comes out of find so the largest is picked without a second stat pass.
    find "$unpack" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; \
        -printf '%s\t%p\n' | sort -rn | head -1 | cut -f2-
}

for i in 1 2; do
    d="$work/b$i"
    mkdir -p "$d"
    cp "$inputs"/* "$d/"
    echo "build $i of 2 (its checksum comparison is expected to fail: an" >&2
    echo "  unstripped binary cannot match a stripped record)" >&2
    set +e
    "$DIAG_ROOT/verify/rebuild.sh" "$d" > "$d/rebuild.log" 2>&1
    set -e
    bin="$(extract_binary "$d" || true)"
    [ -n "$bin" ] || {
        echo "FATAL: build $i produced no .deb; last 40 lines:" >&2
        tail -40 "$d/rebuild.log" >&2
        exit 1
    }
    if ! readelf -S "$bin" | grep -q '\.symtab'; then
        echo "FATAL: build $i came back stripped, so no symbol can be resolved." >&2
        echo "       A lookup on a stripped binary answers 'no enclosing" >&2
        echo "       function', which reads like a fact about the code." >&2
        exit 1
    fi
    printf '%s\n' "$bin" > "$d/binpath"
    echo "  build $i: ${bin##*/} $(stat -c %s "$bin") bytes" >&2
done

a="$(cat "$work/b1/binpath")"
b="$(cat "$work/b2/binpath")"
cp "$a" "$DIAG_OUTDIR/build1.unstripped"
cp "$b" "$DIAG_OUTDIR/build2.unstripped"
readelf -sW "$a" > "$DIAG_OUTDIR/symbols.txt"

python3 - "$a" "$b" "$DIAG_OUTDIR/report.txt" <<'PY'
import bisect, re, subprocess, sys

a, b, out = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
def say(s):
    lines.append(s)
    print(s)

def sections(elf):
    r = []
    for line in subprocess.run(["readelf", "-S", "-W", elf],
                               capture_output=True, text=True).stdout.splitlines():
        m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)',
                     line)
        if m:
            r.append((m.group(1), int(m.group(2), 16),
                      int(m.group(3), 16), int(m.group(4), 16)))
    return r

def funcs(elf):
    r = []
    for line in subprocess.run(["readelf", "-sW", elf],
                               capture_output=True, text=True).stdout.splitlines():
        m = re.match(r'\s*\d+:\s+([0-9a-f]+)\s+(\d+)\s+FUNC\s+\S+\s+\S+\s+\S+\s+(\S+)', line)
        if m and int(m.group(2)):
            r.append((int(m.group(1), 16), int(m.group(2)), m.group(3)))
    r.sort()
    return r

da, db = open(a, 'rb').read(), open(b, 'rb').read()
say(f"build 1: {len(da)} bytes")
say(f"build 2: {len(db)} bytes")

if da == db:
    say("")
    say("IDENTICAL: this pair caught no flap. The package fails roughly half")
    say("the time, so that is the expected outcome about half of all runs.")
    say("Run the workflow again.")
    open(out, "w").write("\n".join(lines) + "\n")
    sys.exit(0)

if len(da) != len(db):
    say("")
    say(f"the builds differ in LENGTH by {len(db) - len(da):+d} bytes, which is more")
    say("than register-level flap; differing section sizes follow.")
    sa = {s[0]: s for s in sections(a)}
    sb = {s[0]: s for s in sections(b)}
    for nm in sorted(set(sa) | set(sb)):
        x, y = sa.get(nm), sb.get(nm)
        if x and y and x[3] != y[3]:
            say(f"  section {nm}: {x[3]} vs {y[3]} bytes")

secs = sections(a)
fs = funcs(a)
starts = [f[0] for f in fs]

n = min(len(da), len(db))
diffs = [i for i in range(n) if da[i] != db[i]]
say("")
say(f"{len(diffs)} differing byte(s) across the first {n} shared bytes")

hits, other = {}, {}
for off in diffs:
    sec = next((s for s in secs if s[2] <= off < s[2] + s[3]), None)
    if not sec:
        other["(outside any section)"] = other.get("(outside any section)", 0) + 1
        continue
    nm, addr, o, sz = sec
    if nm != ".text":
        other[nm] = other.get(nm, 0) + 1
        continue
    va = off - o + addr
    i = bisect.bisect_right(starts, va) - 1
    if i >= 0 and fs[i][0] <= va < fs[i][0] + fs[i][1]:
        hits[fs[i][2]] = hits.get(fs[i][2], 0) + 1
    else:
        other[".text (no enclosing FUNC)"] = other.get(".text (no enclosing FUNC)", 0) + 1

if other:
    say("")
    say("outside .text functions:")
    for k, v in sorted(other.items(), key=lambda kv: -kv[1]):
        say(f"  {v:6d}  {k}")

say("")
if hits:
    say(f"FUNCTIONS THAT DIFFER ({len(hits)}):")
    for nm, cnt in sorted(hits.items(), key=lambda kv: -kv[1]):
        # Rust v0 mangling puts the defining crate after an Nt...Cs<hash>_
        # marker as <len><name>. Best effort only: the label is a hint for a
        # human, and the full symbol is printed beside it either way.
        m = re.search(r'Cs[A-Za-z0-9]+_(\d+)([A-Za-z0-9_]+)', nm)
        tag = ""
        if m:
            tag = f"   [crate: {m.group(2)[:int(m.group(1))]}]"
        say(f"  {cnt:6d} byte(s)  {nm}{tag}")
else:
    say("no differing byte fell inside a named .text function")

open(out, "w").write("\n".join(lines) + "\n")
PY

echo "wrote $DIAG_OUTDIR/report.txt, symbols.txt and both binaries" >&2
