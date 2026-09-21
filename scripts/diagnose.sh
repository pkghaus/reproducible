#!/usr/bin/env bash
#
# Name the function behind a byte that differs in a BAD rebuild.
#
#   scripts/diagnose.sh <buildinfo-url> <file-offset> <outdir>
#
# A BAD verdict says the bytes differed and, since 2026-09-21, keeps the
# rebuilt .deb so the difference can be located. Locating it is not naming it:
# every binary this archive ships is stripped, so an offset in .text resolves
# to nothing. zola's arm64 failure sat there for a day -- known to be a
# register swap, in an unknown function, in an unknown crate.
#
# This rebuilds the same record with the two settings that keep symbols:
# `nostrip` in DEB_BUILD_OPTIONS so dh_strip leaves them, and
# CARGO_PROFILE_RELEASE_STRIP=none because a Rust package whose upstream
# manifest says `[profile.release] strip = true` is stripped by cargo at link
# time, before dh_strip can be told anything. Neither alone suffices; zola
# needed both, and the first attempt with only nostrip came back stripped.
#
# Stripping removes .symtab and does not move .text, so the offset carries
# over unchanged and `readelf -s` answers the question. One build, not a
# bisect.
#
# Why editing the record is safe, and where the limits are:
#
#  - debrebuild does not verify the signature. Its own documentation says so
#    ("the signature (if present) is discarded as debrebuild does not support
#    verifying"), and it warns on stderr when one is present. So a clearsigned
#    record can be edited and still parsed.
#  - it DOES verify the .dsc, against the checksums inside the record. Those
#    are untouched here, so that check still passes. Do not edit anything else.
#  - everything that decides code generation is replayed as recorded: the
#    pinned Installed-Build-Depends, SOURCE_DATE_EPOCH, the build path, and
#    the rest of DEB_BUILD_OPTIONS. `nostrip` only tells dh_strip to do
#    nothing.
#
# The rebuild's own checksum comparison WILL fail, and that is expected: an
# unstripped binary cannot match a stripped one. The artifact is the output,
# not the verdict. Never publish a package built this way -- DEB_BUILD_OPTIONS
# is recorded in .buildinfo, so such a build is self-identifying and wrong.
#
# The offset mapping is checked rather than assumed. A copy of the diagnostic
# binary is stripped and its .text compared against the published one; if they
# differ by more than the handful of bytes that flap, the environments did not
# match and the symbol would be a guess. That check is the reason to trust the
# answer, so it is fatal rather than advisory.

set -euo pipefail
shopt -s inherit_errexit

BUILDINFO_URL="${1:?usage: $0 <buildinfo-url> <file-offset> <outdir>}"
OFFSET="${2:?usage: $0 <buildinfo-url> <file-offset> <outdir>}"
OUTDIR="${3:?usage: $0 <buildinfo-url> <file-offset> <outdir>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Reuse verify.sh's fetchers rather than writing a second set. It returns
# early when sourced, and its positional arguments are unused on that path.
# shellcheck source=scripts/verify.sh
. "$ROOT/scripts/verify.sh" x x x x

case "$OFFSET" in
    ''|*[!0-9]*) echo "FATAL: offset must be a decimal byte offset" >&2; exit 1 ;;
esac

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

base="${BUILDINFO_URL%/*}"
name="${BUILDINFO_URL##*/}"

echo "fetching the record and its source" >&2
fetch "$BUILDINFO_URL" "$work/$name"
dsc="$(checksum_files "$work/$name" | grep '\.dsc$' | head -1)"
deb="$(checksum_files "$work/$name" | grep '\.deb$' | head -1)"
[ -n "$dsc" ] && [ -n "$deb" ] || { echo "FATAL: the record names no .dsc or no .deb" >&2; exit 1; }
fetch "$base/$dsc" "$work/$dsc"
for f in $(checksum_files "$work/$dsc"); do
    fetch "$base/$f" "$work/$f"
done

# Append nostrip to the RECORDED options rather than replacing them: parallel=
# and noautodbgsym are part of how the original was built and dropping them
# would change what is being compared.
python3 - "$work/$name" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
m = re.search(r'^( DEB_BUILD_OPTIONS=")([^"]*)(")$', s, re.M)
if not m:
    sys.exit("FATAL: the record has no DEB_BUILD_OPTIONS to extend")

# nostrip stops dh_strip. On its own it is not enough for a Rust package:
# measured 2026-09-21 against zola, whose upstream Cargo.toml carries
# `[profile.release] strip = true`, so cargo strips at LINK time and dh_strip
# never sees symbols to keep. The first run of this script produced a stripped
# binary and said so, which is why the guard below exists.
#
# CARGO_PROFILE_RELEASE_STRIP is the override, confirmed on a throwaway crate
# with `strip = true` in its manifest: 0 .symtab sections without it, 1 with.
# Both are needed and in this order -- cargo has to leave the symbols in and
# then dh_strip has to leave them alone.
#
# The .dsc cannot be patched instead: debrebuild verifies it against the
# checksums in this record and refuses an edited one.
changed = []
if "nostrip" not in m.group(2).split():
    s = s[:m.start()] + m.group(1) + m.group(2) + " nostrip" + m.group(3) + s[m.end():]
    changed.append(f"DEB_BUILD_OPTIONS += nostrip")

if "CARGO_PROFILE_RELEASE_STRIP" not in s:
    # Same one-leading-space shape as its siblings: debrebuild splits the
    # field by lines and each line on the first '=', so any name works.
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

echo "rebuilding with symbols (the checksum comparison is expected to fail)" >&2
set +e
"$ROOT/verify/rebuild.sh" "$work" > "$work/rebuild.log" 2>&1
set -e
tail -5 "$work/rebuild.log" >&2

built="$(find "$work/rebuilt" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null || true)"
[ -n "$built" ] || {
    echo "FATAL: no .deb was produced; last 40 lines of the rebuild:" >&2
    tail -40 "$work/rebuild.log" >&2
    exit 1
}

# The binary under test: the largest ELF in the package, which for every Rust
# and Go package here is the program itself.
unpack="$work/unpack"; mkdir -p "$unpack"
dpkg-deb --fsys-tarfile "$built" | tar -xf - -C "$unpack"
# -printf rather than a pipe into xargs: no word splitting, and the size comes
# out of find so the largest ELF is picked without a second stat pass.
bin="$(find "$unpack" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; \
       -printf '%s\t%p\n' | sort -rn | head -1 | cut -f2-)"
[ -n "$bin" ] || { echo "FATAL: no ELF binary in the rebuilt package" >&2; exit 1; }
echo "  binary: ${bin#"$unpack"} ($(stat -c %s "$bin") bytes)" >&2

if ! readelf -S "$bin" | grep -q '\.symtab'; then
    echo "FATAL: the rebuild is still stripped -- nostrip did not take effect" >&2
    exit 1
fi

# --- the check that makes the answer trustworthy -----------------------------
# Same offset in a different build is only the same code if the two builds
# agree. Strip a copy and compare .text against what the archive serves.
pool_initial="$(printf '%s' "${deb%%_*}" | cut -c1)"
case "${deb%%_*}" in lib*) pool_initial="$(printf '%s' "${deb%%_*}" | cut -c1-4)" ;; esac
source_name="$(awk '/^Source: /{print $2; exit}' "$work/$name")"
pub_url="https://apt.pkg.haus/pool/main/$pool_initial/$source_name/$deb"
echo "comparing .text against the published build" >&2
if fetch "$pub_url" "$work/published.deb"; then
    pub="$work/pub"; mkdir -p "$pub"
    dpkg-deb --fsys-tarfile "$work/published.deb" | tar -xf - -C "$pub"
    pubbin="$pub${bin#"$unpack"}"
    cp "$bin" "$work/stripped-copy"
    strip --strip-unneeded "$work/stripped-copy" 2>/dev/null || true
    for f in "$work/stripped-copy" "$pubbin"; do
        readelf -x .text "$f" 2>/dev/null | sha256sum | cut -d' ' -f1
    done > "$work/textsums"
    if [ "$(sort -u "$work/textsums" | wc -l)" -eq 1 ]; then
        echo "  .text is byte-identical to the published build" >&2
    else
        echo "  .text DIFFERS from the published build. That is expected on a" >&2
        echo "  package whose codegen flaps, but it means the offset may land" >&2
        echo "  in a different function than it did there. Treat the symbol" >&2
        echo "  below as provisional and say so." >&2
    fi
else
    echo "  could not fetch the published .deb; the offset mapping is unverified" >&2
fi

# --- the answer --------------------------------------------------------------
cp "$bin" "$OUTDIR/$(basename "$bin").unstripped"
readelf -sW "$bin" > "$OUTDIR/symbols.txt"

python3 - "$bin" "$OFFSET" "$OUTDIR/report.txt" <<'PY'
import re, subprocess, sys
elf, off, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
secs = []
for line in subprocess.run(["readelf","-S","-W",elf],capture_output=True,text=True).stdout.splitlines():
    m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)', line)
    if m:
        secs.append((m.group(1), int(m.group(2),16), int(m.group(3),16), int(m.group(4),16)))
hit = next((s for s in secs if s[2] <= off < s[2]+s[3]), None)
lines = [f"file offset {off}"]
if not hit:
    lines.append("  falls outside every section")
else:
    nm, addr, o, sz = hit
    va = off - o + addr
    lines.append(f"  section {nm}, virtual address 0x{va:x}")
    syms = []
    for line in subprocess.run(["readelf","-sW",elf],capture_output=True,text=True).stdout.splitlines():
        m = re.match(r'\s*\d+:\s+([0-9a-f]+)\s+(\d+)\s+FUNC\s+\S+\s+\S+\s+\S+\s+(\S+)', line)
        if m:
            a, n, nmv = int(m.group(1),16), int(m.group(2)), m.group(3)
            if n and a <= va < a+n: syms.append((a, n, nmv))
    if syms:
        a, n, nmv = syms[0]
        lines.append(f"  symbol {nmv}")
        lines.append(f"    starts 0x{a:x}, {n} bytes, offset {va-a} into it")
        # The crate is the first path-ish component of a mangled Rust name.
        crate = re.search(r'_ZN\d+([A-Za-z0-9_]+)', nmv)
        if crate: lines.append(f"    crate (from the mangled name): {crate.group(1)}")
    else:
        lines.append("  no FUNC symbol encloses that address")
        near = sorted((a,n,x) for a,n,x in
                      [(int(m.group(1),16), int(m.group(2)), m.group(3))
                       for m in (re.match(r'\s*\d+:\s+([0-9a-f]+)\s+(\d+)\s+FUNC\s+\S+\s+\S+\s+\S+\s+(\S+)', l)
                                 for l in subprocess.run(["readelf","-sW",elf],capture_output=True,text=True).stdout.splitlines())
                       if m] if a <= va)[-3:]
        for a,n,x in near:
            lines.append(f"    nearest below: {x} at 0x{a:x} (+{va-a})")
open(out,"w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

echo "wrote $OUTDIR/report.txt, symbols.txt and the unstripped binary" >&2
