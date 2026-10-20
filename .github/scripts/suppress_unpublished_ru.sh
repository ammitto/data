#!/usr/bin/env bash
# Run only after successful harmonization. A skipped RU export must not leave
# the previous run's endpoint looking like current published data.
set -euo pipefail

report="${1:?path to harmonize report}"
output="${2:?path to API output directory}"
fail() { echo "::error::Cannot reconcile RU publication: $*" >&2; exit 1; }

# Refuse malformed or failed reports before touching either endpoint. The
# current workflow requires RU. Explicit legacy no-input exemptions are
# still recognized for reconciliation; transform errors remain fatal.
if ! jq -s -e '
  length == 1 and (.[0] |
  .schema == "ammitto-harmonize-report/v1" and .gates_passed == true
  and (.sources | type == "array" and length > 0)
  and all(.sources[];
    (.code | type == "string")
    and (.status == "success" or .status == "error")
    and (.gate_failures | type == "array" and length == 0)
    and (.transform_errors | type == "array" and length == 0)
    and (.exempted_failures | type == "array")
    and (.code == "ru" or (.status == "success" and (.exempted_failures | length == 0))))
  and ([.sources[].code] | length == (unique | length))
  and ([.sources[] | select(.code == "ru")] | length == 1))
' "$report" >/dev/null; then
  fail 'report is malformed, failed, or lacks one RU outcome'
fi
if ! jq -s -e 'length == 1 and (.[0].sources | type == "object")' "$output/stats.json" >/dev/null; then
  fail 'current statistics are missing or malformed'
fi

ru="$(jq -c '.sources[] | select(.code == "ru")' "$report")"
if jq -e '
  .status == "success" and (.entities | type == "number" and . > 0 and floor == .)
  and (.exempted_failures | length == 0)
' <<<"$ru" >/dev/null; then
  # The report counts ingested records; statistics count first-seen IDs.
  # Valid deduplication can reduce this count, but cannot increase it.
  ingested="$(jq '.entities' <<<"$ru")"
  jq -e --argjson ingested "$ingested" '
    .sources.ru.entities | type == "number" and . > 0 and floor == . and . <= $ingested
  ' "$output/stats.json" >/dev/null || fail 'active RU statistics disagree with its ingested count'
  if [ ! -s "$output/sources/ru.jsonld" ] || [ ! -s "$output/sources/ru.ttl" ]; then
    fail 'active RU aggregate is missing or empty'
  fi
  echo 'RU is active; preserving its current aggregates.'
  exit 0
fi

# Only the known no-input and measured-zero outcomes justify suppression.
# A different exempted fault needs investigation, never silent publication.
jq -e '
  (.exempted_failures | length > 0)
  and ((.status == "error" and .entities == null and .entries == null
        and (.error == "No input directory found" or .error == "No YAML files found"))
       or (.status == "success" and .entities == 0 and .entries == 0))
' <<<"$ru" >/dev/null || fail 'RU was exempted for an unexpected reason'
jq -e '.sources | has("ru") | not' "$output/stats.json" >/dev/null ||
  fail 'excluded RU is still present in current statistics'

rm -f -- "$output/sources/ru.jsonld" "$output/sources/ru.ttl"
echo 'RU contributed no current data; suppressed its stale aggregates.'
