#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/suppress_unpublished_ru.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
    echo "FAIL: $1: expected $2, got $3" >&2; FAIL=$((FAIL + 1))
  fi
}
reset() {
  mkdir -p "$WORK/api/sources"
  printf old-ru > "$WORK/api/sources/ru.jsonld"
  printf old-ttl > "$WORK/api/sources/ru.ttl"
  printf healthy-un > "$WORK/api/sources/un.jsonld"
  printf '{"sources":{"un":{"entities":1,"entries":1}}}' > "$WORK/api/stats.json"
  cat > "$WORK/report.json" <<'JSON'
{"schema":"ammitto-harmonize-report/v1","gates_passed":true,"sources":[{"code":"ru","status":"error","entities":null,"entries":null,"error":"No YAML files found","gate_failures":[],"exempted_failures":["ru: No YAML files found"],"transform_errors":[]},{"code":"un","status":"success","entities":1,"entries":1,"gate_failures":[],"exempted_failures":[],"transform_errors":[]}]}
JSON
}
change() { jq "$1" "$WORK/report.json" > "$WORK/changed"; mv "$WORK/changed" "$WORK/report.json"; }
run() { rc=0; bash "$SCRIPT" "$WORK/report.json" "$WORK/api" > "$WORK/out" 2>&1 || rc=$?; }
unchanged() {
  check "$1 fails" 1 "$rc"
  check "$1 preserves RU JSON-LD" old-ru "$(cat "$WORK/api/sources/ru.jsonld")"
  check "$1 preserves RU Turtle" old-ttl "$(cat "$WORK/api/sources/ru.ttl")"
  check "$1 preserves active source" healthy-un "$(cat "$WORK/api/sources/un.jsonld")"
}
reset; run
check 'excluded RU succeeds' 0 "$rc"
check 'stale JSON-LD removed' absent "$([ -e "$WORK/api/sources/ru.jsonld" ] && echo present || echo absent)"
check 'stale Turtle removed' absent "$([ -e "$WORK/api/sources/ru.ttl" ] && echo present || echo absent)"
check 'healthy source preserved' healthy-un "$(cat "$WORK/api/sources/un.jsonld")"
run; check 'already absent endpoints succeed' 0 "$rc"
reset; change '.sources[0] |= (.status="success" | .entities=0 | .entries=0 | .error=null)'; run
check 'measured zero RU succeeds' 0 "$rc"
reset; change '.sources[0] |= (.status="success" | .entities=2 | .entries=2 | .error=null | .exempted_failures=[])'
printf '{"sources":{"ru":{"entities":2,"entries":2},"un":{"entities":1}}}' > "$WORK/api/stats.json"
run; check 'active RU succeeds' 0 "$rc"
check 'active RU preserved' old-ru "$(cat "$WORK/api/sources/ru.jsonld")"
reset; change '.gates_passed=false'; run; unchanged 'failed gates'
reset; printf '{bad' > "$WORK/report.json"; run; unchanged 'invalid JSON'
reset; change '.schema="future"'; run; unchanged 'unknown schema'
reset; change 'del(.sources[0].transform_errors)'; run; unchanged 'missing error list'
reset; change '.sources[0].transform_errors=["bad YAML"]'; run; unchanged 'transform errors'
reset; change '.sources[0].gate_failures=["bad source"]'; run; unchanged 'source gate failure'
reset; change '.sources += [.sources[0]]'; run; unchanged 'duplicate RU'
reset; change '.sources |= map(select(.code != "ru"))'; run; unchanged 'missing RU'
reset; change '.sources[0].error="unexpected exporter failure"'; run; unchanged 'unexpected exemption'
reset; printf '{"sources":{"ru":{"entities":2}}}' > "$WORK/api/stats.json"; run; unchanged 'contradictory statistics'
reset; printf '{"sources":[]}' > "$WORK/api/stats.json"; run; unchanged 'malformed statistics'
reset; change '.sources[0] |= (.status="success" | .entities=2 | .entries=2 | .exempted_failures=[])'; run; unchanged 'active RU missing statistics'
reset; change '.sources[0] |= (.status="success" | .entities=2 | .entries=2)'; run; unchanged 'active RU exempted quality failure'
reset; printf '%s' "$(cat "$WORK/report.json")" >> "$WORK/report.json"; run; unchanged 'concatenated reports'
reset; printf '{"sources":{}}' >> "$WORK/api/stats.json"; run; unchanged 'concatenated statistics'
reset; : > "$WORK/report.json"; run; unchanged 'empty report'
reset; : > "$WORK/api/stats.json"; run; unchanged 'empty statistics'
reset; change '.sources += [.sources[1]]'; run; unchanged 'duplicate active source'
reset; change '.sources[1].status="error"'; run; unchanged 'non-RU source error'
reset; change '.sources[0] |= (.status="success" | .entities=2 | .entries=2 | .exempted_failures=[])'
printf '{"sources":{"ru":{"entities":1,"entries":1}}}' > "$WORK/api/stats.json"
run; check 'deduplicated active RU succeeds' 0 "$rc"
check 'deduplicated active RU preserved' old-ru "$(cat "$WORK/api/sources/ru.jsonld")"
reset; change '.sources[0] |= (.status="success" | .entities=2 | .entries=2 | .exempted_failures=[])'
printf '{"sources":{"ru":{"entities":3,"entries":3}}}' > "$WORK/api/stats.json"
run; unchanged 'statistics exceed ingested count'
reset; change '.sources[0] |= (.status="success" | .entities=2.5 | .entries=2 | .exempted_failures=[])'
printf '{"sources":{"ru":{"entities":2,"entries":2}}}' > "$WORK/api/stats.json"
run; unchanged 'fractional ingested count'
reset; change '.sources[0] |= (.status="success" | .entities=2 | .entries=2 | .exempted_failures=[])'
printf '{"sources":{"ru":{"entities":1.5,"entries":2}}}' > "$WORK/api/stats.json"
run; unchanged 'fractional statistics count'
printf '\nsuppress_unpublished_ru_test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
