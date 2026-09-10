#!/usr/bin/env bash
# Decide whether the harmonize output holds anything worth committing.
#
# The commit step is gated on this answer, so it has to be wrong in neither
# direction, and each direction fails differently.
#
# SAYING NO WHEN THERE IS SOMETHING. The condition this replaced was
# `git diff --quiet && git diff --staged --quiet`, which reports on TRACKED
# files only. A harvest whose whole output is new — a regime node appearing
# for the first time, a new by-list slice, a source that had never published
# — answered "nothing to commit", the commit step was skipped, and the run
# finished green having added nothing.
#
# SAYING YES WHEN THERE IS NOTHING. `git commit` without --allow-empty fails
# when nothing is staged, so a false yes does not write an empty commit: it
# turns a quiet, correct run RED. Two cases arise in this repository, and the
# self-test checks each answer against what `git add .` actually stages,
# rather than against the detector's own opinion:
#
#   Ignored paths, which is not hypothetical here. api/v1/all.jsonld and
#   api/v1/all.ttl are rebuilt on every run and are ignored, because they
#   are published as release assets instead of committed: a push carrying
#   a blob over 100 MiB is refused. porcelain excludes ignored paths
#   already, unless --ignored is passed, and the self-test pins that it
#   stays that way rather than trusting it.
#
#   Submodules. sources/ holds fifteen gitlinks, one per data repository, and
#   a harvest leaves untracked and modified files INSIDE them as a matter of
#   course. Plain `git status` calls a submodule modified for that, while
#   `git add .` can stage nothing, because the gitlink SHA has not moved.
#   --ignore-submodules=dirty drops exactly that case and still reports a
#   submodule whose SHA HAS moved, which is committable and must count.
#
# --untracked-files=normal is explicit because status.showUntrackedFiles=no
# would otherwise suppress the very files this script exists to notice.
set -euo pipefail

# Assigned in its own statement, not tested inline. `if [ -n "$(git ...)" ]`
# swallows a nonzero git and answers "no changes", which is this script's
# worst failure wearing the mask of its normal one. An assignment propagates
# the status under `set -e`, so a broken git fails the run instead.
status="$(git status --porcelain --untracked-files=normal --ignore-submodules=dirty)"

if [ -n "$status" ]; then
  echo true
else
  echo false
fi
