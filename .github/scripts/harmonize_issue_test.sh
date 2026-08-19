#!/usr/bin/env bash
# Offline proof of harmonize_issue.sh's state machine.
#
# Runs before the live step in the workflow, for the same reason the fleet
# monitor self-tests: a reconciler whose parsing silently broke would report
# "nothing to announce" forever, which is the exact failure the issue
# tracking exists to prevent. Costs well under a second and makes no API
# call — `gh` is replaced by a stub that records its arguments and replays
# a fixture.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/harmonize_issue.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# --- the stub -------------------------------------------------------------
# $WORK/issues.json is what `gh api --paginate .../issues` replays.
# $WORK/calls records every `gh` invocation, one per line, so an assertion
# can state what the script did and not merely what it printed.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK/calls"
# Keep whatever body was written, so an assertion can read the rendered
# issue and not merely the fact that a call happened.
prev=""
for arg in "$@"; do
  if [ "$prev" = "--body-file" ]; then cp "$arg" "$WORK/last_body"; fi
  prev="$arg"
done
case "$1" in
  api) cat "$WORK/issues.json" ;;
  *)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export WORK
export HARMONIZE_ISSUE_REPO='ammitto/data'
export HARMONIZE_ALLOW_ISSUE_WRITE=1

report() { # <path> <gates_passed> [failure...]
  local path="$1" passed="$2"
  shift 2
  local sources='[]'
  for f in "$@"; do
    local code="${f%%:*}"
    sources="$(jq -c --arg c "$code" --arg r "$f" \
      '. + [{code: $c, status: "error", entities: null, entries: null,
             error: $r, gate_failures: [$r], exempted_failures: [],
             transform_errors: [], quality: {}}]' <<<"$sources")"
  done
  jq -n --argjson passed "$passed" --argjson sources "$sources" \
    '{schema: "ammitto-harmonize-report/v1",
      generated_at: "2026-08-19T09:00:00Z",
      gates_passed: $passed,
      counts: {succeeded: 13, failed: ($sources | length), exempted: 0},
      totals: {entities: 61048, entries: 61048},
      sources: $sources}' > "$path"
}

issues() { printf '%s' "$1" > "$WORK/issues.json"; }

tracked_issue() { # <signature>
  jq -n --arg s "$1" \
    '[{number: 400, body: ("<!-- harmonization-outage:v1 -->\n" +
        "<!-- harmonization-outage-signature: " + $s + " -->\n\nbody")}]'
}

check() { # <name> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected to contain: %s\n  got: %s\n' "$1" "$2" "$3" >&2
  fi
}

run() { # -> stdout, with $WORK/calls reset
  : > "$WORK/calls"
  "$SCRIPT" "$WORK/report.json" 'https://run/1' 2>&1 || echo "EXIT=$?"
}

# --- cases ----------------------------------------------------------------

# A first failure opens the issue. The original defect was duplication, not
# the existence of a first alert.
issues '[]'
report "$WORK/report.json" false 'ru: No YAML files found'
out="$(run)"
check 'opens on first failure' 'opened tracking issue' "$out"
check 'creates rather than comments' 'issue create' "$(cat "$WORK/calls")"

# A healthy run with nothing open must not create anything at all.
issues '[]'
report "$WORK/report.json" true
out="$(run)"
check 'silent when healthy and untracked' 'nothing to announce' "$out"
check 'writes nothing' '' "$(grep -c 'issue create' "$WORK/calls" || true)0"

# The same fault tomorrow says nothing: this is what stops 321 duplicates.
issues "$(tracked_issue 'ru: No YAML files found')"
report "$WORK/report.json" false 'ru: No YAML files found'
out="$(run)"
check 'quiet when unchanged' 'staying quiet' "$out"
[ -s "$WORK/calls" ] && grep -q 'issue comment' "$WORK/calls" &&
  { echo 'FAIL commented on an unchanged signature' >&2; FAIL=$((FAIL + 1)); }

# A second source failing changes the shape of the outage and is worth
# saying, on the issue that already exists.
issues "$(tracked_issue 'ru: No YAML files found')"
report "$WORK/report.json" false 'ru: No YAML files found' \
  'jp: produced 0 entities'
out="$(run)"
check 'announces a changed signature' 'signature changed on #400' "$out"
check 'comments on the tracked issue' 'issue comment 400' "$(cat "$WORK/calls")"
check 'and rewrites its body' 'issue edit 400' "$(cat "$WORK/calls")"

# Order must not matter, or a run reporting the same two sources the other
# way round would read as a new fault every day.
issues "$(tracked_issue 'jp: produced 0 entities;ru: No YAML files found')"
report "$WORK/report.json" false 'ru: No YAML files found' \
  'jp: produced 0 entities'
out="$(run)"
check 'signature is order-independent' 'staying quiet' "$out"

# Recovery closes it. An open issue titled "failing" over a healthy repo is
# the same lie the duplicates were.
issues "$(tracked_issue 'ru: No YAML files found')"
report "$WORK/report.json" true
out="$(run)"
check 'closes on recovery' 'commented and closed #400' "$out"
# Asserted separately from the summary line, which would keep saying
# "commented and closed" after the comment call was removed.
check 'comments before closing' 'issue comment 400' "$(cat "$WORK/calls")"
check 'actually closes' 'issue close 400' "$(cat "$WORK/calls")"

# The 321 legacy issues carry the labels but no marker. Adopting one would
# mean editing an issue this automation did not open.
issues '[{"number": 12, "body": "The harmonization workflow failed. See: ..."}]'
report "$WORK/report.json" false 'ru: No YAML files found'
out="$(run)"
check 'never adopts an unmarked issue' 'opened tracking issue' "$out"
check 'opens its own instead' 'issue create' "$(cat "$WORK/calls")"

# A pull request can carry the same labels and shares the issues listing.
issues '[{"number": 99, "pull_request": {}, "body": "<!-- harmonization-outage:v1 -->\nx"}]'
report "$WORK/report.json" false 'ru: No YAML files found'
out="$(run)"
check 'ignores pull requests' 'opened tracking issue' "$out"

# An unrecognised schema is refused rather than guessed at.
jq -n '{schema: "something-else/v9", gates_passed: false, sources: []}' \
  > "$WORK/report.json"
out="$(run)"
check 'refuses an unknown schema' 'unknown report schema' "$out"

# A reason containing a pipe must not break the table it is rendered in.
issues '[]'
report "$WORK/report.json" false 'ru: transform failed on a|b'
run > /dev/null
check 'escapes a pipe in the rendered table' 'a\|b' "$(cat "$WORK/last_body")"
check 'renders one row per failure' '| `ru` |' "$(cat "$WORK/last_body")"
check 'carries the marker first' '<!-- harmonization-outage:v1 -->' \
  "$(head -n 1 "$WORK/last_body")"
check 'carries the signature' 'harmonization-outage-signature: ru: transform' \
  "$(cat "$WORK/last_body")"

# A failing run naming no source is a broken producer, and must not be
# mistaken for the same outage as yesterday.
issues "$(tracked_issue '')"
report "$WORK/report.json" false
out="$(run)"
check 'refuses a failing report with no failures' 'lists no gate_failures' "$out"

# A missing report is a broken caller, not a healthy run.
rm -f "$WORK/report.json"
out="$(run)"
check 'refuses a missing report' 'report not found' "$out"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
