#!/usr/bin/env bash
#
# Put the verdicts and the inventory in the bucket reproducible.pkg.haus reads.
#
#   scripts/publish.sh <verdict-dir> [inventory.json]
#
# <verdict-dir> holds verify/<suite>/<arch>/<package>.json as verify.sh left
# it; every file under it is uploaded under the same relative path.
#
# The bucket is pkghaus-reproducible, NOT the archive's pkghaus-apt. A verifier
# that can write to what it verifies is making a weaker claim than one that
# cannot, and the split is the only thing enforcing that: the credentials here
# have no reach into the archive at all.
#
# A verdict object is overwritten in place, once per (package, suite, arch).
# Unlike a pool file there is nothing immutable about it -- it is the current
# answer, and the previous answer is in the run that produced it.
#
# It also writes verdicts.json, the rolled-up index every page is rendered
# from. The Worker used to read one R2 object per artifact: 75 of them took
# 5.6 to 8.1 seconds on a cache miss, measured 2026-09-21, and 216 would have
# been three times that. Binding reads are also capped per invocation on the
# free plan, and a render was already making about eighty. One object fixes
# both, and the per-artifact files stay exactly where they are because they
# are the documented machine-readable endpoint.
#
# The index is built from the WHOLE bucket, not from this run's verdicts: a
# run verifies a handful per leg and the page has to show all of them.
#
# No cache purge afterwards. The Worker serves pages and verdicts with
# max-age=300, so an edge holds a stale page for at most five minutes, and a
# verification wave takes longer than that to finish anyway.

set -euo pipefail
shopt -s inherit_errexit

VERDICT_DIR="${1:?usage: $0 <verdict-dir> [inventory.json]}"
INVENTORY="${2:-}"

R2_BUCKET="${R2_BUCKET:-pkghaus-reproducible}"

require_r2() {
    if [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ] \
       || [ -z "${R2_ENDPOINT:-}" ]; then
        printf 'FATAL: R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and R2_ENDPOINT are required\n' >&2
        exit 1
    fi
}

aws_() {
    require_r2
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
        aws --endpoint-url "$R2_ENDPOINT" "$@"
}

# Every file, before anything is uploaded, and the count on stdout.
#
# A verdict that will not parse would be dropped by the Worker's reader and the
# artifact would read as never checked -- the exact silence this whole surface
# exists to remove. And a run that verified nothing has nothing to publish: an
# `aws s3 sync` of an empty tree succeeds silently, so refusing here is what
# separates "no work was planned", which the caller skips, from "the work
# vanished", which nothing else would report.
validate_verdicts() { # dir
    local count=0 file
    while IFS= read -r file; do
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" \
            || { printf 'FATAL: %s is not valid JSON\n' "$file" >&2; return 1; }
        count=$((count + 1))
    done < <(find "$1" -name '*.json' -type f 2>/dev/null)

    if [ "$count" -eq 0 ]; then
        printf 'FATAL: no verdicts under %s\n' "$1" >&2
        return 1
    fi
    printf '%s\n' "$count"
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

count="$(validate_verdicts "$VERDICT_DIR")"

printf 'uploading %s verdict(s) to s3://%s/verify/\n' "$count" "$R2_BUCKET" >&2
aws_ s3 sync "$VERDICT_DIR/" "s3://$R2_BUCKET/verify/" \
    --content-type 'application/json' --only-show-errors

# Everything now in the bucket, this run's uploads included, as one object.
# Synced down rather than merged from $VERDICT_DIR, which holds only what this
# run produced.
all_dir="$(mktemp -d)"
rolled="$(mktemp)"
trap 'rm -rf "$all_dir" "$rolled"' EXIT
aws_ s3 sync "s3://$R2_BUCKET/verify/" "$all_dir/" --only-show-errors
python3 "$(dirname "${BASH_SOURCE[0]}")/roll-index.py" "$all_dir" "$rolled"
aws_ s3 cp "$rolled" "s3://$R2_BUCKET/verdicts.json" \
    --content-type 'application/json' --only-show-errors

if [ -n "$INVENTORY" ]; then
    [ -s "$INVENTORY" ] || {
        printf 'FATAL: %s is missing or empty\n' "$INVENTORY" >&2; exit 1; }
    printf 'uploading the inventory\n' >&2
    aws_ s3 cp "$INVENTORY" "s3://$R2_BUCKET/inventory.json" \
        --content-type 'application/json' --only-show-errors
fi
