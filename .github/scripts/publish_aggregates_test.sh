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

# Real `gh release view --json a,b` exports ONLY a and b. The stub does the
# same, and that fidelity is load-bearing rather than tidiness: a version of
# this script asking for fewer fields must receive fewer, so that running
# this suite against an older script reproduces THAT script's failure and
# not an argument-shape complaint from the stub.
emit() { # $1 = isDraft, $2... = the gh argv, so --json can be read from it
  local draft="$1"; shift
  local want; want="$(value_of --json "$@")"
  local t; t="$(cat "$WORK/target")"
  local assets
  case "$(cat "$WORK/assets")" in
    good)
      assets='[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"DIG_A"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"DIG_B"}]' ;;
    partial)
      assets='[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"DIG_A"}]' ;;
    wrongdigest)
      assets='[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"sha256:WRONG"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"sha256:WRONG"}]' ;;
  esac
  assets="${assets//DIG_A/$(cat "$WORK/dig_a")}"
  assets="${assets//DIG_B/$(cat "$WORK/dig_b")}"

  local out="" sep=""
  case ",$want," in *,isDraft,*) out="$out$sep\"isDraft\":$draft"; sep=, ;; esac
  case ",$want," in *,targetCommitish,*) out="$out$sep\"targetCommitish\":\"$t\""; sep=, ;; esac
  case ",$want," in *,assets,*) out="$out$sep\"assets\":$assets"; sep=, ;; esac
  printf '{%s}\n' "$out"
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
    # Real gh rejects a bare `--json` with a missing-argument error, so the
    # stub does too. Accepting it would let an empty field list through and
    # emit `{}`, which every downstream `jq` reads as null and no assertion
    # would notice.
    case "$*" in
      *--json*) : ;;
      *) echo "release view without --json" >&2; exit 1 ;;
    esac
    [ -n "$(value_of --json "$@")" ] ||
      { echo "release view with an empty --json list" >&2; exit 1; }
    case "$state" in
      absent)         echo 'release not found' >&2; exit 1 ;;
      draft|draft-partial) emit true "$@" ;;
      published)      emit false "$@" ;;
      published-bad)  emit false "$@" ;;
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
    # CREATING A DRAFT DOES NOT CREATE ITS TAG. GitHub mints the ref when the
    # release is PUBLISHED; until then the draft has none, which is why its
    # own URL reads .../releases/tag/untagged-<id> and the ref API answers
    # 404. An earlier version of this stub wrote the tag here, and the script
    # it proved could not survive one real run: every first publish died on a
    # post-create tag assertion. What pins a draft to a commit is its
    # targetCommitish, so that is what is recorded.
    echo "$target" > "$WORK/target"
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
        # `--draft=false --latest` publishes AND claims Latest. Publishing is
        # also the moment GitHub creates the tag, so the ref appears here and
        # not at create time.
        echo published > "$WORK/state"
        cat "$WORK/target" > "$WORK/tagsha"
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
# already exists: these fixtures model a pre-existing matching tag, which is
# what a re-run of an already-published sha meets. Leaving it empty made the
# stub answer 404 to the ref lookup in those cases, so the
# tag-resolves-and-matches path -- the normal one on every re-run -- was
# never executed by any test. A draft reached through `create` is the other
# shape, and case 5 covers it: the stub writes no tag there.
reset() { # state, assets, tag sha, tag kind, Latest, draft target
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
  # A release that already exists was created for HEAD; an absent one has no
  # target until a create writes it. ${6-} lets a case aim a draft elsewhere.
  echo "${6-$HEAD_SHA}" > "$WORK/target"
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

# --- 14. the identity is re-checked immediately before it goes live ------
# Everything between the first check and the publish is remote work on a
# draft, and a draft is not frozen. On the path this script takes there is no
# tag yet, GitHub mints it at publish, so what changes under us here is the
# target. The stub retargets the draft after the upload, which is that window.
# The other half of the window, someone creating the tag itself mid-upload,
# is what assert_tag_absent_or_ours covers immediately before the publish.
reset draft partial
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "$(cat "$WORK/latest")"; exit 0 ;;
  esac
  echo 'HTTP 404: Not Found' >&2; exit 1   # a draft has no tag
fi
case "$2" in
  view)
    # Honest until the upload; retargeted afterwards.
    if grep -q upload "$WORK/calls"; then
      t=0000000000000000000000000000000000000000
    else
      t="$(cat "$WORK/target")"
    fi
    printf '{"isDraft":true,"targetCommitish":"%s","assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
      "$t" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   echo published > "$WORK/state" ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "draft retargeted under us fails"           "1" "$rc"
check "draft retargeted under us never publishes" "0" "$(calls ' edit ')"
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
      printf '{"isDraft":true,"targetCommitish":"%s","assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
        "$(cat "$WORK/target")" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")"
    fi ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "assets swapped at publish time fails" "1" "$rc"
# The point of this case is a POST-publication failure, so the publish has to
# have happened. Without this the case passes just as well when the run dies
# before the edit, which is how it read while the draft carried no target.
check "assets swapped at publish time did publish" "1" "$(calls ' edit ')"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 16. a draft whose view carries no target at all ---------------------
# The tag-deleted-under-a-draft case this slot used to hold is not reachable
# on this path: nothing has created the tag yet when the draft is built.
# What CAN happen is the shape underneath it changing -- a `gh` release, a
# `--json` field dropped in this script -- and `.targetCommitish` then reads
# as null. That must fail LOUDLY rather than
# compare null against the sha by accident and happen to be right. It is the
# same discipline the stub already applies to `--json isDraft`.
reset draft good
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "$(cat "$WORK/latest")"; exit 0 ;;
  esac
  echo 'HTTP 404: Not Found' >&2; exit 1
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
check "draft with no target fails"           "1" "$rc"
check "draft with no target never publishes" "0" "$(calls ' edit ')"
# The message has to name the real problem. A bare `jq -r` renders the absent
# key as "null" and the refusal then reads "targets null", which sends whoever
# is holding the pager looking for a retarget that never happened.
case "$out" in
  *"carries no targetCommitish"*) said=missing-field ;;
  *"targets null"*)               said=reads-as-retarget ;;
  *)                              said="$out" ;;
esac
check "no-target failure names the missing field" "missing-field" "$said"
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
    printf '{"isDraft":%s,"targetCommitish":"%s","assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
      "$d" "$(cat "$WORK/target")" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a publish whose Latest claim does not stick fails" "1" "$rc"
check "a publish whose Latest claim does not stick did publish" "1" "$(calls ' edit ')"
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

# --- 19b. the tag is CREATED under the draft, mid-upload ------------------
# The other half of the publish window, and the one the pre-publish
# `assert_tag_absent_or_ours` exists for. A draft has no tag, but the NAME it
# will claim is not reserved: another writer can create it, pointing
# anywhere, while the upload runs. Publishing then binds this release to
# someone else's ref. The stub answers 404 until the upload and a DIFFERENT
# sha afterwards, which is exactly that.
reset draft partial
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then
  case "$2" in
    */releases/latest) echo "$(cat "$WORK/latest")"; exit 0 ;;
  esac
  if grep -q upload "$WORK/calls"; then
    echo "commit 0000000000000000000000000000000000000000"; exit 0
  fi
  echo 'HTTP 404: Not Found' >&2; exit 1
fi
case "$2" in
  view) printf '{"isDraft":true,"targetCommitish":"%s","assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
          "$(cat "$WORK/target")" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   echo published > "$WORK/state" ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a tag created mid-upload fails"           "1" "$rc"
check "a tag created mid-upload never publishes" "0" "$(calls ' edit ')"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 19c. the release is created and then cannot be read back -------------
# `create` succeeds, the read-back after it fails. The release certainly
# exists at that point, so this is a fault rather than absence, and it has to
# say so and stop before anything is uploaded.
reset absent good
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WORK/calls"
if [ "$1" = "api" ]; then echo 'HTTP 404: Not Found' >&2; exit 1; fi
case "$2" in
  view)
    if [ -f "$WORK/made" ]; then
      printf 'upstream broke\nsecond line\n' >&2; exit 1
    fi
    echo 'release not found' >&2; exit 1 ;;
  create) : > "$WORK/made"; echo made ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a failed read-back after create fails"      "1" "$rc"
check "a failed read-back uploads nothing"         "0" "$(calls upload)"
check "a failed read-back publishes nothing"       "0" "$(calls ' edit ')"
case "$out" in
  *"could not read "*" back: upstream broke second line"*) said=one-line ;;
  *) said="$out" ;;
esac
check "a failed read-back says so in one line" "one-line" "$said"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 19d. isDraft is missing from the payload -----------------------------
# `jq -r` renders an absent key as "null", and "null" is not "false", so
# without the guard the script reads a possibly-PUBLISHED release as a draft
# and takes the upload-and-clobber path against it.
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
  view) printf '{"targetCommitish":"%s","assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
          "$(cat "$WORK/target")" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a missing isDraft fails"           "1" "$rc"
check "a missing isDraft uploads nothing" "0" "$(calls upload)"
check "a missing isDraft publishes nothing" "0" "$(calls ' edit ')"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 19e. the read after UPLOAD fails ------------------------------------
# and 19f, the read after PUBLISH. Every read past the first one is of a
# release known to exist, so each must annotate and stop rather than abort
# bare. These two were the last bare ones in the file.
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
    if grep -q upload "$WORK/calls"; then printf 'upload read broke\n' >&2; exit 1; fi
    printf '{"isDraft":true,"targetCommitish":"%s","assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
      "$(cat "$WORK/target")" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a failed read after upload fails"        "1" "$rc"
check "a failed read after upload never publishes" "0" "$(calls ' edit ')"
case "$out" in
  *"uploaded to "*"could not read "*"upload read broke"*) said=named ;;
  *) said="$out" ;;
esac
check "a failed read after upload names the step" "named" "$said"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

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
    if grep -q ' edit ' "$WORK/calls"; then printf 'publish read broke\n' >&2; exit 1; fi
    printf '{"isDraft":true,"targetCommitish":"%s","assets":[{"name":"all.jsonld","size":100,"state":"uploaded","digest":"%s"},{"name":"all.ttl","size":50,"state":"uploaded","digest":"%s"}]}\n' \
      "$(cat "$WORK/target")" "$(cat "$WORK/dig_a")" "$(cat "$WORK/dig_b")" ;;
  upload) : ;;
  edit)   : ;;
esac
STUB
chmod +x "$WORK/bin/gh"
run
check "a failed read after publish fails" "1" "$rc"
case "$out" in
  *"published "*"could not read "*"publish read broke"*) said=named ;;
  *) said="$out" ;;
esac
check "a failed read after publish names the step" "named" "$said"
cp "$WORK/bin/gh.orig" "$WORK/bin/gh"

# --- 20. the annotation normaliser, directly ------------------------------
# Sourced from the shipped file rather than copied, so this cannot pass
# against a stale duplicate. `::error::` is line-oriented AND percent-decoded
# by the runner, so both halves have to hold: one line out, and no sequence
# that the runner will turn back into a newline.
# shellcheck disable=SC1090
. <(sed -n '/^oneline() {/,/^}/p' "$SCRIPT")

check "oneline: newline and CR both squashed" "a b c" "$(oneline "$(printf 'a\nb\rc')")"
check "oneline: literal %0A cannot become a newline" \
  "error at %250A line two" "$(oneline 'error at %0A line two')"
check "oneline: a bare percent survives decoding" \
  "failed 100%25 of the time" "$(oneline 'failed 100% of the time')"
check "oneline: empty stays empty" "" "$(oneline '')"
check "oneline: quotes and backslashes are untouched" \
  "it's a \\ backslash" "$(oneline "it's a \\ backslash")"
check "oneline: trailing space is stripped" "done" "$(oneline 'done   ')"

printf '\npublish_aggregates_test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
