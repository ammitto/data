#!/usr/bin/env bash
# Offline proof of publish_aggregates.sh's state machine.
#
# Runs before the live step, for the same reason the outage reconciler
# self-tests: the failure this script exists to prevent is invisible when it
# regresses. An earlier inline version of this logic logged "release exists"
# and then clobbered the published assets anyway, which is precisely the
# window the draft-first sequence is for. A test that exercises the
# published-and-valid branch would have caught it.
#
# Makes no API call: `gh` is a stub that records its arguments and replays a
# fixture. Costs well under a second.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/publish_aggregates.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

# --- the stub -------------------------------------------------------------
# Argument-aware, and it owns the state. A stub that accepts anything lets a
# missing --draft or --clobber pass, which is the difference between testing
# the transitions and testing that some command ran.
#
#   $WORK/state   absent | draft | published | published-bad | draft-partial
#   $WORK/calls   every subcommand, so we can assert what did NOT run
#   $WORK/tagsha  what the git ref API reports, empty for "no such tag"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
state="$(cat "$WORK/state")"

emit() { # $1 = isDraft
  case "$(cat "$WORK/assets")" in
    good) printf '{"isDraft":%s,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' "$1" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
    partial) printf '{"isDraft":%s,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"}]}\n' "$1" "$(cat "$WORK/dig_a")" ;;
    wrongdigest) printf '{"isDraft":%s,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"sha256:WRONG"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"sha256:WRONG"}]}\n' "$1" ;;
  esac
}

if [ "$1" = "api" ]; then
  t="$(cat "$WORK/tagsha")"
  [ -z "$t" ] && exit 1
  echo "$t"
  exit 0
fi

case "$2" in
  view)
    case "$state" in
      absent)         echo 'release not found' >&2; exit 1 ;;
      draft|draft-partial) emit true ;;
      published)      emit false ;;
      published-bad)  emit false ;;
      authfail)       echo 'HTTP 401: Bad credentials' >&2; exit 1 ;;
    esac ;;
  create)
    case "$*" in *--draft*) : ;; *) echo "create without --draft" >&2; exit 1 ;; esac
    case "$*" in *--target*) : ;; *) echo "create without --target" >&2; exit 1 ;; esac
    echo draft > "$WORK/state" ;;
  upload)
    case "$*" in *--clobber*) : ;; *) echo "upload without --clobber" >&2; exit 1 ;; esac
    echo good > "$WORK/assets" ;;
  edit)
    case "$*" in *--draft=false*) : ;; *) echo "edit without --draft=false" >&2; exit 1 ;; esac
    case "$*" in *--latest*) : ;; *) echo "edit without --latest" >&2; exit 1 ;; esac
    echo published > "$WORK/state" ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" WORK GITHUB_REPOSITORY=ammitto/data

# --- fixtures -------------------------------------------------------------
printf 'x%.0s' $(seq 1 100) > "$WORK/all.jsonld"   # 100 bytes
printf 'y%.0s' $(seq 1 50)  > "$WORK/all.ttl"      # 50 bytes
echo "sha256:$(sha256sum "$WORK/all.jsonld" | cut -d' ' -f1)" > "$WORK/dig_a"
echo "sha256:$(sha256sum "$WORK/all.ttl"    | cut -d' ' -f1)" > "$WORK/dig_b"

# Run from the repository, not $WORK: the script asks git for the commit it
# is publishing, so it needs a work tree. The asset paths are absolute.
# Run from the repository, not $WORK: the script asks git for the commit it
# is publishing, so it needs a work tree. The asset paths are absolute.
run() { # sets $out and $rc
  set +e
  out="$("$SCRIPT" "$WORK/all.jsonld" "$WORK/all.ttl" 2>&1)"
  rc=$?
  set -e
}

reset() { # $1 = state, $2 = assets, $3 = tag sha (optional)
  : > "$WORK/calls"
  echo "$1" > "$WORK/state"
  echo "${2:-good}" > "$WORK/assets"
  echo "${3:-}" > "$WORK/tagsha"
}

# grep -c prints 0 AND exits 1 when there is no match, so a `|| echo 0`
# fallback prints it twice. Swallow the status instead.
calls() { grep -c "$1" "$WORK/calls" 2>/dev/null || true; }

# --- 1. published and valid: must NOT touch it ----------------------------
reset published good
run
check "published+valid exits 0"          "0" "$rc"
check "published+valid uploads nothing"  "0" "$(calls upload)"
check "published+valid edits nothing"    "0" "$(calls ' edit ')"

# --- 2. published, an asset missing: fail, never clobber ------------------
reset published partial
run
check "published+partial fails"          "1" "$rc"
check "published+partial never uploads"  "0" "$(calls upload)"

# --- 3. published, right sizes but WRONG BYTES: fail ----------------------
# Size equality alone would pass this. The digest is what catches it.
reset published wrongdigest
run
check "published+wrong-digest fails"         "1" "$rc"
check "published+wrong-digest never uploads" "0" "$(calls upload)"

# --- 4. draft: upload, verify, publish ------------------------------------
reset draft partial
run
check "draft exits 0"     "0" "$rc"
check "draft uploads"     "1" "$(calls upload)"
check "draft publishes"   "1" "$(calls ' edit ')"

# --- 5. absent: create a draft, fill it, publish --------------------------
reset absent partial
run
check "absent exits 0"          "0" "$rc"
check "absent creates"          "1" "$(calls create)"
check "absent uploads"          "1" "$(calls upload)"
check "absent publishes"        "1" "$(calls ' edit ')"

# --- 6. a tag that already resolves elsewhere: fail before any write ------
reset absent good "0000000000000000000000000000000000000000"
run
check "stale tag fails"           "1" "$rc"
check "stale tag creates nothing" "0" "$(calls create)"
check "stale tag uploads nothing" "0" "$(calls upload)"

# --- 7. a lookup failure that is NOT absence must not read as absence ----
reset authfail good
run
check "auth failure fails"           "1" "$rc"
check "auth failure creates nothing" "0" "$(calls create)"

# --- 8. a missing aggregate must fail before any API call ----------------
reset published good
: > "$WORK/empty"
set +e
out="$("$SCRIPT" "$WORK/empty" "$WORK/all.ttl" 2>&1)"; rc=$?
set -e
check "empty aggregate fails"       "1" "$rc"
check "empty aggregate calls no gh" "0" "$(grep -c . "$WORK/calls" 2>/dev/null || true)"

printf '\npublish_aggregates_test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
