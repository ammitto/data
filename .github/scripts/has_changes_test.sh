#!/usr/bin/env bash
# Offline proof of has_changes.sh, and of the defect it exists to fix.
#
# Runs before the live step, for the same reason harmonize_issue_test.sh does: a
# detector that silently stopped seeing new files would gate the commit step
# off and the run would finish green having published nothing, which is
# precisely the failure this script exists to prevent.
#
# Every case is built in a throwaway repository, so this makes no network
# call and finishes in about a second.
#
# THE OLD CONDITION IS EXERCISED TOO. A test that only proves the fix works
# cannot show there was anything to fix; the paired assertions on the
# new-file cases are the whole point of the change.
#
# EVERY CALL ASSERTS THE EXIT STATUS, not only the answer. A script that
# printed the right word and then died would otherwise pass, and this
# script's worst failure mode is a git error read as "nothing to commit".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/has_changes.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3" >&2
  fi
}

# Answer and exit status together, as "<answer>/<rc>", so no assertion can
# pass on the word alone.
answer() {
  local out rc
  out="$("$SCRIPT" 2>/dev/null)" && rc=0 || rc=$?
  printf '%s/%s' "$out" "$rc"
}

# What the workflow does NEXT, so a "true" is checked against the step it
# gates rather than against itself. `git add .` then an empty index means
# `git commit` fails without --allow-empty, which is how a false yes turns a
# correct run red. Called after the answer, since it mutates the fixture.
# Both statuses are asserted, not just the diff's answer. An add that FAILED,
# an index.lock left behind or a permission fault, leaves the index empty and
# would otherwise read as a clean "nothing"; a diff that errored would read as
# "something". Each failure would pass as its own opposite, so failures get
# their own answer and match no expectation.
staged_after_add() {
  local add_rc=0 diff_rc=0
  git add . > /dev/null 2>&1 || add_rc=$?
  [ "$add_rc" -eq 0 ] || { printf 'add-failed/%s' "$add_rc"; return; }
  git diff --cached --quiet > /dev/null 2>&1 || diff_rc=$?
  case "$diff_rc" in
    0) echo nothing ;;
    1) echo something ;;
    *) printf 'diff-failed/%s' "$diff_rc" ;;
  esac
}

# The condition this change replaces, verbatim, so the assertions below are
# about the real thing and not a paraphrase.
old_condition() {
  if git diff --quiet && git diff --staged --quiet; then echo false; else echo true; fi
}

fixture() { # a repo with one tracked file and the aggregates ignored
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo/api/v1"
  cd "$WORK/repo"
  git init -q .
  git config user.email test@example.com
  git config user.name test
  printf 'api/v1/all.jsonld\napi/v1/all.ttl\n' > .gitignore
  echo original > api/v1/tracked.jsonld
  git add -A
  git commit -qm base
}

# --- nothing changed ------------------------------------------------------
fixture
check "clean tree"                          "false/0" "$(answer)"
check "clean tree: old agreed"              "false"   "$(old_condition)"

# --- a tracked file changed ----------------------------------------------
fixture
echo changed > api/v1/tracked.jsonld
check "modified tracked file"               "true/0"  "$(answer)"
check "modified tracked: old agreed"        "true"    "$(old_condition)"
check "modified tracked: stages something"  "something" "$(staged_after_add)"

# --- a staged change ------------------------------------------------------
fixture
echo changed > api/v1/tracked.jsonld
git add api/v1/tracked.jsonld
check "staged change"                       "true/0"  "$(answer)"

# --- a deletion, on its own ----------------------------------------------
fixture
rm api/v1/tracked.jsonld
check "deletion alone"                      "true/0"  "$(answer)"

# --- THE DEFECT: output that is entirely new ------------------------------
fixture
echo '{}' > api/v1/new-regime-node.jsonld
check "new file only"                       "true/0"  "$(answer)"
check "new file only: OLD SAID FALSE"       "false"   "$(old_condition)"
check "new file only: stages something"     "something" "$(staged_after_add)"

# --- a new nested directory, which is what a new source looks like --------
fixture
mkdir -p api/v1/by-list/newsource
echo '{}' > api/v1/by-list/newsource/index.jsonld
check "new nested directory"                "true/0"  "$(answer)"
check "new nested directory: OLD SAID FALSE" "false"  "$(old_condition)"
check "new nested dir: stages something"    "something" "$(staged_after_add)"

# --- THE IGNORED-FILE TRAP ------------------------------------------------
# The aggregates are rebuilt every run and are ignored, because they ship as
# release assets rather than commits. Counting them would make the commit step
# run with nothing staged, and `git commit` fails there without --allow-empty,
# so a quiet correct run would go red.
fixture
printf 'aggregate\n' > api/v1/all.jsonld
printf 'aggregate\n' > api/v1/all.ttl
check "ignored aggregates alone"            "false/0" "$(answer)"
check "ignored alone: stages nothing"       "nothing" "$(staged_after_add)"

fixture
printf 'aggregate\n' > api/v1/all.jsonld
echo '{}' > api/v1/new-regime-node.jsonld
check "ignored plus a new file"             "true/0"  "$(answer)"

# --- THE SUBMODULE TRAP ---------------------------------------------------
# sources/ holds fifteen gitlinks and a harvest dirties them as a matter of
# course. Dirt inside a submodule is not committable from here; a moved
# gitlink SHA is.
submodule_fixture() {
  rm -rf "$WORK/sub" "$WORK/repo"
  mkdir -p "$WORK/sub"; cd "$WORK/sub"
  git init -q .; git config user.email test@example.com; git config user.name test
  echo v1 > file.txt; git add -A; git commit -qm sub-base
  mkdir -p "$WORK/repo"; cd "$WORK/repo"
  git init -q .; git config user.email test@example.com; git config user.name test
  git -c protocol.file.allow=always submodule add -q "$WORK/sub" sources/sub
  echo original > tracked.jsonld
  git add -A; git commit -qm parent-base
}

# "dirty" covers BOTH shapes of work-tree change inside a submodule, so both
# are asserted. A harvest produces each: new files the source repository has
# not committed, and rewrites of ones it has.
submodule_fixture
echo junk > sources/sub/untracked-inside.txt
check "submodule untracked inside only"     "false/0" "$(answer)"
check "  and it stages nothing"             "nothing" "$(staged_after_add)"

submodule_fixture
( cd sources/sub && echo v2 > file.txt )
check "submodule tracked file modified"     "false/0" "$(answer)"
check "  and it stages nothing"             "nothing" "$(staged_after_add)"

submodule_fixture
echo junk > sources/sub/untracked-inside.txt
( cd sources/sub && echo v2 > file.txt )
check "submodule dirty both ways"           "false/0" "$(answer)"
check "  and it stages nothing"             "nothing" "$(staged_after_add)"

submodule_fixture
echo junk > sources/sub/untracked-inside.txt
echo '{}' > new-regime-node.jsonld
check "submodule dirty plus a real new file" "true/0" "$(answer)"
check "  and it stages something"           "something" "$(staged_after_add)"

# A moved gitlink is the one submodule change that IS committable from here,
# so it must count and must survive staging.
submodule_fixture
( cd "$WORK/sub" && echo v2 > file.txt && git commit -qam sub-v2 )
( cd sources/sub && git fetch -q origin && git checkout -q FETCH_HEAD )
check "submodule gitlink moved"             "true/0"  "$(answer)"
check "  and it stages something"           "something" "$(staged_after_add)"

# --- configuration that would blind it ------------------------------------
fixture
git config status.showUntrackedFiles no
echo '{}' > api/v1/new-regime-node.jsonld
check "showUntrackedFiles=no still detects" "true/0"  "$(answer)"

# --- a broken git must fail the run, not answer "nothing to commit" -------
mkdir -p "$WORK/notarepo"; cd "$WORK/notarepo"
check "outside a repo fails loudly"         "/128"    "$(answer)"

printf '\nhas_changes_test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
