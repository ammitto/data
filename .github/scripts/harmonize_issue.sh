#!/usr/bin/env bash
# Keep ONE open issue describing the current harmonization outage.
#
# Called by .github/workflows/harmonize.yml on every run, healthy or not.
# Reads the JSON `ammitto harmonize --report` writes; it does not parse the
# command's output. Parsing the log meant keying on the wording of a raised
# Thor::Error, which the gem is free to change without warning.
#
# Why one issue
# -------------
# The step this replaces created an issue per failing run. That produced
# 321 open issues carrying the `harmonization` label, the oldest from
# February, and buried the outage it was reporting inside its own
# duplicates. Nobody reads a channel that repeats itself daily.
#
# Identity is a BODY MARKER, never the title
# ------------------------------------------
# The issue is found by its body starting with $MARKER. Two consequences,
# both deliberate:
#
#   - the 321 legacy issues carry the same labels and cannot be adopted,
#     edited or closed from here, because none of them carries the marker;
#   - a human may rename the issue and it stays tracked.
#
# State rides in the marker line rather than a repo file, because a failure
# can happen before anything is committed and operational state does not
# belong in the published dataset history.
#
# Only changes are announced
# --------------------------
# The signature is the sorted set of "code: reason" lines. Unchanged
# signature means the same fault as yesterday and the script stays silent;
# a different one means the shape of the outage moved and is worth a
# comment; "healthy" means recovery, which comments and closes.
#
# Usage: harmonize_issue.sh <report.json> <run-url>
# Environment:
#   GH_TOKEN                        token with issues:write
#   HARMONIZE_ISSUE_REPO            target repo (default $GITHUB_REPOSITORY)
#   HARMONIZE_ALLOW_ISSUE_WRITE=1   permit writes outside GitHub Actions
set -euo pipefail

REPORT="${1:?usage: harmonize_issue.sh <report.json> <run-url>}"
RUN_URL="${2:?usage: harmonize_issue.sh <report.json> <run-url>}"

MARKER='<!-- harmonization-outage:v1 -->'
SIGNATURE_PREFIX='<!-- harmonization-outage-signature: '
SIGNATURE_SUFFIX=' -->'
TITLE='Harmonization is failing'
LABELS='automation,harmonization'
# The schema this script knows how to read. A report stamped with anything
# else is refused rather than guessed at, which is the whole point of
# reporting instead of scraping.
SCHEMA='ammitto-harmonize-report/v1'

REPO="${HARMONIZE_ISSUE_REPO:-${GITHUB_REPOSITORY:-}}"

[ -f "$REPORT" ] || { echo "report not found: $REPORT" >&2; exit 66; }
[ -n "$REPO" ] || {
  echo "no target repo: set GITHUB_REPOSITORY or HARMONIZE_ISSUE_REPO" >&2
  exit 64
}
if [ "${GITHUB_ACTIONS:-}" != "true" ] &&
   [ "${HARMONIZE_ALLOW_ISSUE_WRITE:-}" != "1" ]; then
  echo "refusing to write issues outside GitHub Actions" \
       "(set HARMONIZE_ALLOW_ISSUE_WRITE=1 to override)" >&2
  exit 78
fi

schema="$(jq -r '.schema // ""' "$REPORT")"
[ "$schema" = "$SCHEMA" ] || {
  echo "unknown report schema ${schema:-(none)}; expected $SCHEMA" >&2
  exit 65
}

gates_passed="$(jq -r '.gates_passed' "$REPORT")"
# Sorted so that two runs failing on the same sources in a different order
# read as the same fault rather than a new one.
failures="$(jq -r '[.sources[] | select((.gate_failures | length) > 0)
                   | .gate_failures[]] | sort | .[]' "$REPORT")"

if [ "$gates_passed" = "true" ]; then
  signature='healthy'
else
  signature="$(printf '%s' "$failures" | tr '\n' ';' | sed 's/;$//')"
  # A failing run that names no source means the producer changed shape or
  # broke. Refusing is the point: an empty signature compares equal to the
  # empty one already stored, so the unchanged path below would read it as
  # "same outage as yesterday" and say nothing at all.
  [ -n "$signature" ] || {
    echo "report says the gates failed but lists no gate_failures" >&2
    exit 65
  }
fi

# Every open issue is fetched rather than searched: the marker lives in an
# HTML comment, which the search index does not reliably see, and this repo
# has 300+ open issues so the tracked one is not guaranteed to be on the
# first page.
open_json="$(gh api --paginate \
  "repos/$REPO/issues?state=open&labels=harmonization&per_page=100" \
  | jq -s 'add // []')"

tracked="$(jq -r --arg m "$MARKER" \
  '[.[] | select(has("pull_request") | not)
        | select((.body // "") | startswith($m))]
   | .[0].number // empty' <<<"$open_json")"

old_signature=''
if [ -n "$tracked" ]; then
  old_signature="$(jq -r --arg m "$MARKER" --arg p "$SIGNATURE_PREFIX" \
    '[.[] | select(has("pull_request") | not)
          | select((.body // "") | startswith($m))] | .[0].body // ""' \
    <<<"$open_json" \
    | sed -n "s/.*${SIGNATURE_PREFIX}\(.*\)${SIGNATURE_SUFFIX}.*/\1/p" \
    | head -n 1)"
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

write_body() {
  {
    printf '%s\n' "$MARKER"
    printf '%s%s%s\n\n' "$SIGNATURE_PREFIX" "$signature" "$SIGNATURE_SUFFIX"
    printf 'Harmonization has been failing since this issue was opened. '
    printf 'It is updated in place rather than reopened per run, and closes '
    printf 'itself when a run succeeds.\n\n'
    printf 'Latest failing run: %s\n\n' "$RUN_URL"
    printf '| Source | Gate failure |\n| --- | --- |\n'
    jq -r '.sources[] | select((.gate_failures | length) > 0)
           | . as $s | .gate_failures[]
           | "| `\($s.code)` | \(. | gsub("[|]"; "\\|")) |"' "$REPORT"
    printf '\n%s succeeded, %s failed, %s exempted.\n' \
      "$(jq -r '.counts.succeeded' "$REPORT")" \
      "$(jq -r '.counts.failed' "$REPORT")" \
      "$(jq -r '.counts.exempted' "$REPORT")"
  } > "$body_file"
}

# The unchanged check comes FIRST, before the healthy/failing split.
# Ordering it the other way makes a healthy repo with an open issue comment
# "recovered" and close it on every single run.
if [ -z "$tracked" ]; then
  if [ "$signature" = 'healthy' ]; then
    echo 'harmonize healthy, no open tracking issue — nothing to announce'
    exit 0
  fi
  write_body
  gh issue create --repo "$REPO" --title "$TITLE" \
    --label "$LABELS" --body-file "$body_file"
  echo "opened tracking issue for: $signature"
  exit 0
fi

if [ "$old_signature" = "$signature" ]; then
  echo "no change since the last announcement ($signature) — staying quiet"
  exit 0
fi

if [ "$signature" = 'healthy' ]; then
  gh issue comment "$tracked" --repo "$REPO" \
    --body "Recovered. Harmonization succeeded in $RUN_URL. Closing; a new outage opens a fresh issue."
  gh issue close "$tracked" --repo "$REPO"
  echo "recovered — commented and closed #$tracked"
  exit 0
fi

write_body
gh issue comment "$tracked" --repo "$REPO" --body-file "$body_file"
gh issue edit "$tracked" --repo "$REPO" --body-file "$body_file"
echo "signature changed on #$tracked: '${old_signature:-none}' -> '$signature'"
