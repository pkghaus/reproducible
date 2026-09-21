# reproducible.pkg.haus

Whether each package in the [pkg.haus](https://apt.pkg.haus) archive rebuilds
byte-for-byte from its own build record.

Live at **https://reproducible.pkg.haus**. The verdicts are also machine
readable: `/verify/<suite>/<arch>/<package>.json` for one artifact,
`/inventory.json` for what the archive publishes.

## The three words

The vocabulary is [rebuilderd](https://github.com/kpcyrd/rebuilderd)'s, so this
page reads the same way as reproducible.archlinux.org and reproduce.debian.net.

| | |
|---|---|
| `GOOD` | `debrebuild` compared every recorded checksum and they matched. |
| `BAD` | `debrebuild` compared them and one differed. |
| `UNKWN` | The comparison did not happen. |

`UNKWN` is the load-bearing third state, not a rounding error.
[snapshot.debian.org](https://snapshot.debian.org) is a rate-limited volunteer
service and it is the only source of the exact build-dependency versions a
record names. A timeout there, a dependency that is no longer resolvable, or a
rebuild that failed to build at all is not evidence about this archive, and
recording it as `BAD` would be a claim the run cannot support.

The percentage on the front page is over **decided** verdicts, never over
everything published: a denominator that grows with the fleet would fall every
time a package is added and would say nothing about reproducibility. Coverage
is reported separately, as `checked / published`, so an artifact nobody has
tried is visible as unchecked rather than silently absent.

## What this does not prove

These rebuilds run in the same CI that produced the packages. That makes this a
regression detector, not a trust root: if the build pipeline were compromised,
so is the rebuilder. What it reliably catches is unintentional non-determinism
- a build reading the host's CPU, a toolchain that was recorded rather than
pinned, a timestamp leaking into an archive - which is the failure that has
actually occurred here.

The property worth having is an *independent* rebuild, by someone who did not
build the package. Everything needed for that is published at
[buildinfos.pkg.haus](https://buildinfos.pkg.haus), in the same layout Debian's
own rebuilders consume. This repo is what makes that possible, not a substitute
for it.

## Checking one package yourself

```sh
B=https://buildinfos.pkg.haus/buildinfo-pool/c/croc
curl -fsSLO $B/croc_11.5.3-2_amd64.buildinfo
curl -fsSLO $B/croc_11.5.3-2.dsc
curl -fsSLO $B/croc_11.5.3-2.debian.tar.xz
curl -fsSLO $B/croc_11.5.3.orig.tar.gz

debrebuild --builder=dpkg --buildresult=./rebuilt croc_11.5.3-2_amd64.buildinfo
```

`verify/rebuild.sh` in this repo does the same thing inside a throwaway
container, which is what the mmdebstrap builder and the `dcmd` removal
described in its header make necessary.

## How a verdict gets made

```
inventory.sh   the six Packages indices  ->  what the archive publishes
plan.sh        that, minus the verdicts  ->  what to rebuild next
verify.sh      one artifact's inputs     ->  one rebuild, one verdict per target
publish.sh     the verdicts              ->  the bucket the Worker reads
```

`verify.yml` runs those four in that order, on two cadences:

- **On publish.** `pkghaus/apt` dispatches this repo at the end of an ingest
  that published something, so a freshly released package gets a verdict within
  minutes.
- **Throttled.** A daily sweep takes the oldest verdicts and re-checks them. A
  package can stop reproducing with nothing in the pipeline changing - zola's
  did, through a compiler that moved underneath it - so a verdict is only ever a
  statement about the day it was made.

`MAX_PER_LEG` bounds how many rebuilds one of the six legs starts per run. The
throttle is not about CI minutes; it is about how hard a volunteer service is
asked to work.

## Layout

```
scripts/     inventory, plan, verify, publish
verify/      the rebuild harness, byte-identical to pkghaus/apt's (see below)
worker/      the Cloudflare Worker that renders reproducible.pkg.haus
tests/       run.sh drives the scripts; worker/test drives the Worker
```

`verify/rebuild.sh` and `verify/Dockerfile` are byte-identical copies of
`pkghaus/apt`'s. The archive keeps them so a maintainer can check one package
without the verifier; this repo keeps them so a run needs nothing from another
repo. CI here fetches the archive's copies and diffs, so a change to either
turns that check red until both move.

## Verdict objects

One object per `(package, suite, architecture)`, overwritten in place.

```json
{
  "package": "croc",
  "version": "11.5.3-2",
  "suite": "unstable",
  "arch": "amd64",
  "status": "GOOD",
  "checked_at": "2026-09-21T07:57:54Z",
  "buildinfo": "https://buildinfos.pkg.haus/buildinfo-pool/c/croc/croc_11.5.3-2_amd64.buildinfo",
  "debrebuild": "all OK",
  "unknown_reason": null,
  "rebuilt_sha256": "5560b8a6...",
  "recorded_sha256": "5560b8a6...",
  "run": "https://github.com/pkghaus/reproducible/actions/runs/..."
}
```

An `Architecture: all` package is built once and published in every
architecture's index, so one rebuild writes a verdict for each target it
covers. `betterlockscreen` and `pkghaus-archive-keyring` are the fleet's two.

The verdicts live in their own R2 bucket, `pkghaus-reproducible`, not in the
archive's. A verifier that can write to what it verifies is making a weaker
claim than one that cannot.

## Running the tests

```sh
tests/run.sh
cd worker && npm ci && npm test
```

Neither needs a network, a credential, or docker.

## Licence

Apache-2.0.
