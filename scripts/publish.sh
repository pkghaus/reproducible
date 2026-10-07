#!/usr/bin/env bash
#
# Put the verdicts and the inventory in the bucket reproducible.pkg.haus reads.
#
#   scripts/publish.sh <verdict-dir> [inventory.json]
#
# <verdict-dir> holds <suite>/<arch>/<package>.json as verify.sh left it. Each
# file replaces the object at the same path under verify/, once
# scripts/carry-prior.py has carried the prior verdict's history and any
# sticky BAD onto it.
#
# The bucket is pkghaus-reproducible, never the archive's; worker/wrangler.toml
# says why. verdicts.json, the index every page renders from
# (scripts/roll-index.py), is rebuilt from the WHOLE bucket, not this run's
# verdicts: a run verifies a handful per leg and the page shows all of them.
#
# No cache purge afterwards: pages and verdicts are served with max-age=300,
# and a verification wave takes longer than that anyway.

set -euo pipefail
shopt -s inherit_errexit

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

# Sourced by the tests; arguments are read below, only when executed.
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

VERDICT_DIR="${1:?usage: $0 <verdict-dir> [inventory.json]}"
INVENTORY="${2:-}"

R2_BUCKET="${R2_BUCKET:-pkghaus-reproducible}"

count="$(validate_verdicts "$VERDICT_DIR")"

# Prior state, fetched BEFORE the upload, so the verdicts this run replaces
# are still readable. carry-prior.py rewrites this run's verdicts in place:
# history carried forward, and a BAD kept where a later rebuild cannot clear it.
prior_dir="$(mktemp -d)"
trap 'rm -rf "$prior_dir"' EXIT
aws_ s3 sync "s3://$R2_BUCKET/verify/" "$prior_dir/" --only-show-errors
python3 "$(dirname "${BASH_SOURCE[0]}")/carry-prior.py" "$VERDICT_DIR" "$prior_dir"

printf 'uploading %s verdict(s) to s3://%s/verify/\n' "$count" "$R2_BUCKET" >&2
aws_ s3 sync "$VERDICT_DIR/" "s3://$R2_BUCKET/verify/" \
    --content-type 'application/json' --only-show-errors

# Everything now in the bucket, this run's uploads included, as one object.
# Synced down rather than merged from $VERDICT_DIR, which holds only what this
# run produced.
all_dir="$(mktemp -d)"
rolled="$(mktemp)"
trap 'rm -rf "$prior_dir" "$all_dir" "$rolled"' EXIT
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
