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
#   $WORK/tagkind commit (lightweight) or tag (annotated, needing a peel)
#   $WORK/latest  tag_name the Latest endpoint reports, empty for "no Latest"
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
  case "$2" in
    */releases/latest)
      l="$(cat "$WORK/latest")"
      if [ -z "$l" ]; then echo 'HTTP 404: Not Found' >&2; exit 1; fi
      echo "$l"; exit 0 ;;
    *git/tags/*)                            # peeling an annotated tag object
      echo "$(cat "$WORK/tagsha")"; exit 0 ;;
  esac
  # the ref lookup, which answers with the object's TYPE and sha
  t="$(cat "$WORK/tagsha")"
  if [ -z "$t" ]; then echo 'HTTP 404: Not Found' >&2; exit 1; fi
  echo "$(cat "$WORK/tagkind") $t"
  exit 0
fi

# Every release subcommand names the tag as its third argument, and the stub
# has to check it. Dispatching on the subcommand alone means a production
# change that addressed a DIFFERENT tag still passes every assertion here,
# which is the invariant this file exists to hold: the release named for a
# commit carries that commit's bytes.
# Boolean flags by TOKEN, not substring. Real gh accepts `--latest=false`
# and `--clobber=false`, which mean the OPPOSITE of the bare flag, and a
# `*--latest*` glob matches both. A stub that cannot tell them apart passes
# the exact transitions it exists to catch: a reclaim that unsets Latest, an
# upload that refuses to overwrite.
#   flag <name> "$@"      -> on | off | absent   (off = an explicit =false)
#   value_of <name> "$@"  -> the value after `--name` or in `--name=value`
flag() {
  name="$1"; shift
  for a in "$@"; do
    [ "$a" = "$name" ] && { echo on; return; }
    case "$a" in
      "$name"=true)  echo on;  return ;;
      "$name"=*)     echo off; return ;;
    esac
  done
  echo absent
}

# `--name value` for a flag that TAKES a value (--target), `--name=value`
# for either. A boolean must be read with `boolean_value` instead: pflag does
# not consume a space-separated value for one, so `--draft false` is gh
# creating a draft and then choking on a stray argument, not gh setting
# draft to false. A stub that read it as false would pass a mutation that
# fails in CI.
value_of() {
  name="$1"; shift; prev=''
  for a in "$@"; do
    [ "$prev" = "$name" ] && { echo "$a"; return; }
    case "$a" in "$name"=*) echo "${a#"$name"=}"; return ;; esac
    prev="$a"
  done
}

boolean_value() {
  name="$1"; shift
  for a in "$@"; do
    case "$a" in "$name"=*) echo "${a#"$name"=}"; return ;; esac
  done
}

case "$3" in
  "$(cat "$WORK/tag")") : ;;
  *) echo "release $2 addressed '$3', not $(cat "$WORK/tag")" >&2; exit 1 ;;
esac

case "$2" in
  view)
    # Honour the requested fields. Real gh exports ONLY what --json names, so
    # a stub that always supplies isDraft hides a production change to
    # `--json assets`: `.isDraft` would be null there and the script would
    # take the draft-and-upload path for a published release.
    for want in isDraft assets; do
      case "$*" in
        *--json*"$want"*) : ;;
        *) echo "release view without --json $want" >&2; exit 1 ;;
      esac
    done
    case "$state" in
      absent)         echo 'release not found' >&2; exit 1 ;;
      draft|draft-partial) emit true ;;
      published)      emit false ;;
      published-bad)  emit false ;;
      authfail)       echo 'HTTP 401: Bad credentials' >&2; exit 1 ;;
    esac ;;
  create)
    # Token match, not substring. Real gh accepts `--draft=false`, which
    # creates a NON-draft release, and a `*--draft*` glob happily matches it.
    # The stub would then pass the exact unsafe transition it exists to catch.
    seen_draft=$(flag --draft "$@")
    [ "$seen_draft" = on ] || { echo "create without a bare --draft" >&2; exit 1; }
    # --target's VALUE, not merely its presence. A create aimed at another
    # commit would otherwise pass, and it is the one thing a draft cannot be
    # corrected for afterwards.
    target="$(value_of --target "$@")"
    [ -n "$target" ] || { echo "create without --target" >&2; exit 1; }
    [ "$target" = "$(cat "$WORK/head")" ] ||
      { echo "create targeted '$target', not HEAD" >&2; exit 1; }
    # Creating a release CREATES ITS TAG. Leaving tagsha empty here left the
    # post-create guards answering 404 for the whole run, so the stub taught
    # the script that a missing tag after creation is normal -- the exact
    # false success the strict guard exists to catch.
    echo "$target" > "$WORK/tagsha"
    echo draft > "$WORK/state" ;;
  upload)
    [ "$(flag --clobber "$@")" = on ] ||
      { echo "upload without a bare --clobber" >&2; exit 1; }
    echo good > "$WORK/assets" ;;
  edit)
    # Two shapes are legitimate and they mean different things. Publishing a
    # finished draft carries BOTH flags; reclaiming Latest on an already
    # published release carries only --latest, and must not silently also
    # flip a draft. Anything else is a mistake worth failing on.
    latest="$(flag --latest "$@")"
    undraft="$(boolean_value --draft "$@")"
    [ "$latest" = on ] || { echo "edit without a usable --latest" >&2; exit 1; }
    case "$undraft" in
      false)
        # `--draft=false --latest` publishes AND claims Latest.
        echo published > "$WORK/state"
        cat "$WORK/tag" > "$WORK/latest" ;;
      '')
        [ "$(cat "$WORK/state")" = published ] ||
          { echo "reclaim --latest on a $(cat "$WORK/state") release" >&2; exit 1; }
        cat "$WORK/tag" > "$WORK/latest" ;;
      *) echo "edit with --draft=$undraft" >&2; exit 1 ;;
    esac ;;
esac
STUB
chmod +x "$WORK/bin/gh"
cp "$WORK/bin/gh" "$WORK/bin/gh.orig"
export PATH="$WORK/bin:$PATH" WORK GITHUB_REPOSITORY=ammitto/data

# --- fixtures -------------------------------------------------------------
# The script derives both from HEAD, so the test has to agree with git rather
# than invent a sha: a fixture tag that does not match HEAD exercises the
# stale-tag refusal, which is a different case.
HEAD_SHA="$(git -C "$HERE" rev-parse HEAD)"
TAG="api-v1-$HEAD_SHA"
echo "$TAG" > "$WORK/tag"
echo "$HEAD_SHA" > "$WORK/head"

printf 'x%.0s' $(seq 1 100) > "$WORK/all.jsonld"   # 100 bytes
printf 'y%.0s' $(seq 1 50)  > "$WORK/all.ttl"      # 50 bytes
echo "sha256:$(sha256sum "$WORK/all.jsonld" | cut -d' ' -f1)" > "$WORK/dig_a"
echo "sha256:$(sha256sum "$WORK/all.ttl"    | cut -d' ' -f1)" > "$WORK/dig_b"

# Run from the repository, not $WORK: the script asks git for the commit it
# is publishing, so it needs a work tree. The asset paths are absolute.
run() { # sets $out and $rc
  set +e
  out="$("$SCRIPT" "$WORK/all.jsonld" "$WORK/all.ttl" 2>&1)"
  rc=$?
  set -e
}

# $3 defaults to the real HEAD sha for every state that implies the release
# already exists, because a release cannot exist without its tag. Leaving it
# empty made the stub answer 404 to the ref lookup in those cases, so the
# tag-resolves-and-matches path -- the normal one on every re-run -- was
# never executed by any test.
reset() { # $1 = state, $2 = assets, $3 = tag sha, $4 = tag kind, $5 = Latest
  : > "$WORK/calls"
  echo "$1" > "$WORK/state"
  echo "${2:-good}" > "$WORK/assets"
  case "$1" in
    absent|authfail) default_sha='' ;;
    *)               default_sha="$HEAD_SHA" ;;
  esac
  echo "${3-$default_sha}" > "$WORK/tagsha"
  echo "${4:-commit}" > "$WORK/tagkind"
  echo "${5-$TAG}" > "$WORK/latest"
}

# grep -c prints 0 AND exits 1 when there is no match, so a `|| echo 0`
# fallback prints it twice. Swallow the status instead.
# -e and -- are both required: a pattern such as `--latest` is otherwise
# read as grep's own options, and grep then waits on stdin forever with no
# file argument left.
calls() { grep -c -e "$1" -- "$WORK/calls" 2>/dev/null || true; }

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

# --- 6b. a tag lookup that fails for a reason OTHER than absence ---------
# The guard must not fail open: an auth or transport fault looks nothing like
# "no such tag" and must stop before any write.
reset absent good
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then echo 'HTTP 403: Forbidden' >&2; exit 1; fi
echo 'release not found' >&2; exit 1
STUB
chmod +x "$WORK/bin/gh"
run
check "tag lookup 403 fails"           "1" "$rc"
check "tag lookup 403 creates nothing" "0" "$(calls create)"
# The message has to REACH the log. `resolve_tag`'s stdout is a value read
# through command substitution, so a diagnostic written there is captured
# into the caller's variable and the run fails with no explanation at all.
case "$out" in
  *"could not resolve tag"*) check "tag lookup 403 says why" "1" "1" ;;
  *)                         check "tag lookup 403 says why" "1" "0" ;;
esac
# restore the shared stub for the remaining cases
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

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

# --- 9. published and valid, but something else took Latest --------------
# The one thing the do-nothing state still has to do. Losing the slot is
# silent: the release is intact, its assets are intact, and only the URL the
# site is told to use has moved.
reset published good "$HEAD_SHA" commit "some-other-release"
run
check "lost Latest exits 0"        "0" "$rc"
check "lost Latest never uploads"  "0" "$(calls upload)"
check "lost Latest reclaims"       "1" "$(calls '--latest')"
check "lost Latest is reclaimed"   "$TAG" "$(cat "$WORK/latest")"

# The reclaim must not carry --draft=false. On a published release the flag
# is a no-op, but the stub treats the pair as the publish transition, and a
# test that cannot tell the two calls apart cannot prove either.
check "reclaim is not a publish"   "0" "$(calls '--draft=false')"

# --- 10. published and valid, and the repository has no Latest at all -----
# Every release a draft or a prerelease. The endpoint 404s, which is a state
# and not a fault, and the slot is free to take.
reset published good "$HEAD_SHA" commit ""
run
check "no Latest exits 0"      "0" "$rc"
check "no Latest reclaims"     "1" "$(calls '--latest')"

# --- 11. the Latest lookup fails for a reason other than absence ----------
reset published good
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo 'HTTP 403: Forbidden' >&2; exit 1 ;;
    *) echo "commit $(cat "$WORK/tagsha")"; exit 0 ;;
  esac
fi
if [ "$2" = view ]; then
  printf '{"isDraft":false,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
    "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")"
  exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/gh"
run
check "Latest lookup 403 fails"      "1" "$rc"
check "Latest lookup 403 edits none" "0" "$(calls ' edit ')"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 12. an ANNOTATED tag pointing at this commit is not a stale tag ------
# The ref API answers with the tag object's own sha, which never equals a
# commit sha. Comparing it directly would refuse every annotated tag, and
# the refusal would read as "someone moved the tag".
reset published good "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" tag
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "$(cat "$WORK/latest")"; exit 0 ;;
    *git/tags/*)       echo "$(cat "$WORK/peeled")"; exit 0 ;;
    *)                 echo "tag $(cat "$WORK/tagsha")"; exit 0 ;;
  esac
fi
if [ "$2" = view ]; then
  printf '{"isDraft":false,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
    "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")"
  exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/gh"
echo "$HEAD_SHA" > "$WORK/peeled"
run
check "annotated tag peeling to HEAD is accepted" "0" "$rc"

# ... and one peeling somewhere else is still refused.
echo "0000000000000000000000000000000000000000" > "$WORK/peeled"
run
check "annotated tag peeling elsewhere fails"   "1" "$rc"
check "annotated stale tag uploads nothing"     "0" "$(calls upload)"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 13. a boolean flag's FALSE spelling must not read as its true one ---
# `--latest=false` and `--clobber=false` mean the opposite of the bare flag,
# and a substring match accepts both. Each of these mutates the production
# call and must fail; a stub that passes them is proving nothing.
#
# Every probe uses $TAG. An earlier version used a placeholder tag, so the
# stub's tag gate rejected each probe before the flag parser ran and all
# three assertions passed for the wrong reason: they would have passed with
# no flag parsing at all.
reset published good
for probe in "edit $TAG --latest=false" \
             "upload $TAG all.jsonld --clobber=false" \
             "edit $TAG --draft=false"; do
  set +e
  # shellcheck disable=SC2086
  ( cd "$WORK" && gh release $probe ) >/dev/null 2>&1
  prc=$?
  set -e
  check "stub rejects '${probe#* }'" "1" "$prc"
done

# ...and the =true spellings, which real gh accepts and which mean the same
# as the bare flag. Rejecting these would be a stub stricter than gh, which
# is its own kind of lie.
reset draft good
for probe in "upload $TAG all.jsonld --clobber=true" \
             "create $TAG --draft=true --target $HEAD_SHA"; do
  set +e
  # shellcheck disable=SC2086
  ( cd "$WORK" && gh release $probe ) >/dev/null 2>&1
  prc=$?
  set -e
  check "stub accepts '${probe#* }'" "0" "$prc"
done

# --- 14. the tag is re-checked immediately before the release goes live ---
# Everything between the first check and the publish is remote work on a
# draft, and a draft's tag is not frozen. The stub moves the tag after the
# upload, which is exactly that window.
reset draft partial
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "$(cat "$WORK/latest")"; exit 0 ;;
  esac
  # The first ref lookup answers honestly; every one after the upload
  # reports the tag pointing somewhere else.
  if grep -q upload "$WORK/calls"; then
    echo "commit 0000000000000000000000000000000000000000"
  else
    echo "commit $(cat "$WORK/tagsha")"
  fi
  exit 0
fi
case "$2" in
  view) printf '{"isDraft":true,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
          "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   echo published > "$WORK/state" ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "tag moved under a draft fails"          "1" "$rc"
check "tag moved under a draft never publishes" "0" "$(calls ' edit ')"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 15. the release is read back after publishing --------------------
# The checks before the edit are time-of-check. Nothing here makes the window
# atomic, so the requirement is that a mismatch is loud. The stub swaps an
# asset digest at the moment of publication, which is that window.
reset draft good
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "$(cat "$WORK/latest")"; exit 0 ;;
  esac
  echo "commit $(cat "$WORK/tagsha")"; exit 0
fi
case "$2" in
  view)
    # Good until the edit lands, wrong immediately after it: exactly the
    # shape of another writer clobbering an asset mid-publish.
    if grep -q ' edit ' "$WORK/calls"; then
      printf '{"isDraft":false,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"sha256:WRONG"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"sha256:WRONG"}]}\n'
    else
      printf '{"isDraft":true,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
        "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")"
    fi ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "assets swapped at publish time fails" "1" "$rc"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 16. the tag is DELETED under the draft ---------------------------
# Absence means opposite things on either side of the release existing. An
# earlier version used one assertion for both positions and returned success
# on absence everywhere, so this state published the release and exited 0.
reset draft good
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "$(cat "$WORK/latest")"; exit 0 ;;
  esac
  # Present at the opening check, gone once the upload has happened.
  if grep -q upload "$WORK/calls"; then
    echo 'HTTP 404: Not Found' >&2; exit 1
  fi
  echo "commit $(cat "$WORK/tagsha")"; exit 0
fi
case "$2" in
  view) printf '{"isDraft":true,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
          "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   echo published > "$WORK/state" ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "tag deleted under a draft fails"           "1" "$rc"
check "tag deleted under a draft never publishes" "0" "$(calls ' edit ')"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 17. Latest does not stick after being claimed ---------------------
# Claiming a repository-global slot and not holding it is the same outcome as
# never claiming it, so the claim is read back.
reset published good "$HEAD_SHA" commit "some-other-release"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "some-other-release"; exit 0 ;;  # never moves
  esac
  echo "commit $(cat "$WORK/tagsha")"; exit 0
fi
case "$2" in
  view) printf '{"isDraft":false,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
          "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  edit) : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a reclaim that does not stick fails" "1" "$rc"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 18. Latest does not stick after PUBLISHING either -----------------
# The sibling of case 17, on the other write. Without it, dropping the
# postcondition after `--draft=false --latest` fails nothing, because the
# other cases all have a stub that grants the claim.
reset draft good
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo 'HTTP 404: Not Found' >&2; exit 1 ;;  # never granted
  esac
  echo "commit $(cat "$WORK/tagsha")"; exit 0
fi
case "$2" in
  view)
    if grep -q ' edit ' "$WORK/calls"; then d=false; else d=true; fi
    printf '{"isDraft":%s,"assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
      "$d" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a publish whose Latest claim does not stick fails" "1" "$rc"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 19. a PUBLISHED release whose tag was deleted ---------------------
# Valid assets, holding Latest, and no tag. The do-nothing path used to be
# reached without any strict tag check at all, so this exited 0 and said
# there was nothing to do, about a release whose name claims a commit its
# tag no longer resolves to.
reset published good ""
run
check "published release with no tag fails"          "1" "$rc"
check "published release with no tag edits nothing"  "0" "$(calls ' edit ')"
check "published release with no tag uploads nothing" "0" "$(calls upload)"

printf '\npublish_aggregates_test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
