#!/usr/bin/env bash
# Publish the two oversized aggregates as assets on a release keyed to the
# data commit they were built from.
#
# Ronald ruled on 2026-09-01 that "the all.json output is not a contract, for
# files so large we should use GitHub releases." GitHub blocks any push
# introducing a blob over 100 MiB, server-side in the pre-receive hook; git
# itself stores a blob that size without complaint, so an operator who reads
# the limit as a local one will look in the wrong place. The push error
# names that same limit "100.00 MB", so grep for either. A release asset
# must be under 2 GiB.
#
# The whole point of this file is the state machine, so it is a file rather
# than an inline `run:` block, and publish_aggregates_test.sh exercises every
# branch offline against a `gh` stub. An earlier inline version looked correct
# and was not: it logged "release exists" and then clobbered it anyway.
#
# The identity is the FULL commit sha, not the date. A date in the tag means
# an unchanged HEAD produces a brand new release, carrying the same quarter
# gigabyte of assets, every single day. The date belongs in the title, where
# a human reads it and nothing keys off it.
#
# States, and why each behaves as it does:
#
#   absent            create a DRAFT targeted at this exact sha, then fill it.
#                     A draft cannot be selected as Latest, so a half-built
#                     release is never visible to the site.
#   draft             upload, verify, publish. Resuming an interrupted run.
#   published + valid do NOTHING. `gh release upload --clobber` DELETES an
#                     asset before uploading its replacement, so re-running it
#                     over a published release opens exactly the window the
#                     draft exists to close.
#   published + bad   fail loudly. Never mutate a published release in place;
#                     a human decides whether to delete and rebuild it.
#
# One ownership claim this makes, worth knowing before a second release family
# is ever added here: `releases/latest/download/...` is a REPOSITORY-global
# slot, and this workflow owns it. Anything else published in this repository
# takes the slot, and the site's stable URL then serves that release's assets
# or 404s. So the do-nothing state above does one thing after all: it checks
# who holds Latest and takes it back. It cannot be left to the publish step,
# which runs only when a release is being built, while the slot can be lost
# on any day in between. If this repository ever needs a second kind of
# release, the site needs a redirect it controls rather than `latest`.
set -euo pipefail

jsonld="${1:?path to all.jsonld}"
ttl="${2:?path to all.ttl}"

for f in "$jsonld" "$ttl"; do
  if [ ! -s "$f" ]; then
    echo "::error::$f is missing or empty; --combine did not produce it"
    exit 1
  fi
done

sha="$(git rev-parse HEAD)"
tag="api-v1-$sha"
title="Aggregated API data $(date -u +%Y-%m-%d) ($(git rev-parse --short HEAD))"

jsonld_size="$(wc -c < "$jsonld" | tr -d ' ')"
ttl_size="$(wc -c < "$ttl" | tr -d ' ')"
jsonld_digest="sha256:$(sha256sum "$jsonld" | cut -d' ' -f1)"
ttl_digest="sha256:$(sha256sum "$ttl" | cut -d' ' -f1)"

# Exactly two assets, both fully uploaded, both matching the bytes on disk by
# DIGEST and not merely by size. Size alone passes an asset of the right
# length carrying the wrong content, which is a real outcome of a clobber
# that raced or resumed against different data. GitHub exposes a sha256 per
# asset and gh surfaces it as `digest`.
assets_valid() {
  printf '%s' "$1" | jq -e \
    --arg aname all.jsonld --argjson asize "$jsonld_size" --arg adig "$jsonld_digest" \
    --arg bname all.ttl    --argjson bsize "$ttl_size"    --arg bdig "$ttl_digest" '
    (.assets | length) == 2
    and ([.assets[] | select(.state == "uploaded") | {name, size, digest}] | sort_by(.name))
        == ([{name: $aname, size: $asize, digest: $adig},
             {name: $bname, size: $bsize, digest: $bdig}] | sort_by(.name))
  ' >/dev/null 2>&1
}

# A tag can exist without a release, and `gh release create --target` is
# IGNORED when the tag already exists: GitHub attaches the release to whatever
# commit the tag already points at. So a stale `api-v1-<sha>` tag resolving
# elsewhere would produce a release whose name claims this commit and whose
# contents are this commit's bytes, hanging off a different one. Check first.
# Both scratch files are created together and cleaned by ONE trap. A second
# `trap ... EXIT` does not add a handler, it replaces the first, so declaring
# them one at a time silently leaks whichever was registered earlier.
tag_err="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$tag_err" "$err_file"' EXIT

# The tag, resolved to a commit sha, or empty when it does not exist.
# Peels an annotated tag: its ref points at a tag OBJECT, whose sha never
# equals a commit sha, so comparing directly would refuse every annotated tag
# and the refusal would read as "someone moved it".
#
# A lookup that fails for any reason OTHER than a confirmed 404 stops the run
# here rather than returning empty. Reading a 401, a 403 or a 5xx as absence
# fails the guard open exactly when it is most needed.
resolve_tag() {
  set +e
  tag_ref="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" \
               --jq '.object.type + " " + .object.sha' 2>"$tag_err")"
  tag_rc=$?
  set -e

  if [ "$tag_rc" -ne 0 ]; then
    if ! grep -qi 'not found\|HTTP 404' "$tag_err"; then
      # To STDERR. This function's stdout is a value, read through command
      # substitution, so a diagnostic written there is captured into the
      # caller's variable and never reaches the log. The run failed with no
      # explanation at all, which is the one thing a fail-loud guard must
      # not do.
      echo "::error::could not resolve tag $tag: $(cat "$tag_err")" >&2
      exit 1
    fi
    return 0
  fi

  tag_type="${tag_ref%% *}"
  tag_obj="${tag_ref##* }"
  if [ "$tag_type" = "tag" ]; then
    tag_obj="$(gh api "repos/$GITHUB_REPOSITORY/git/tags/$tag_obj" --jq '.object.sha')"
  fi
  printf '%s' "$tag_obj"
}

# Two questions, not one, because absence means opposite things on either
# side of the release being created.
#
# BEFORE: absent is the ordinary first run, and present-and-matching is a
# resumed one. Only present-and-different is a refusal.
assert_tag_absent_or_ours() {
  found="$(resolve_tag)"
  [ -z "$found" ] && return 0
  if [ "$found" != "$sha" ]; then
    echo "::error::tag $tag already exists and resolves to $found, not $sha."
    echo "::error::Refusing to publish a release whose tag points at a different commit."
    exit 1
  fi
}

# AFTER: the release exists, so its tag must too. An earlier version used one
# function for both and returned 0 on absence in every position, so a tag
# deleted under a draft published the release anyway and exited 0. A missing
# tag here is not a first run, it is someone deleting it mid-flight.
assert_tag_is_ours() {
  found="$(resolve_tag)"
  if [ -z "$found" ]; then
    echo "::error::tag $tag has gone missing while its release was being built."
    exit 1
  fi
  if [ "$found" != "$sha" ]; then
    echo "::error::tag $tag now resolves to $found, not $sha."
    echo "::error::Refusing to publish a release whose tag points at a different commit."
    exit 1
  fi
}

# `releases/latest/download/...` is repository-global and this release owns
# it. Checked after every write that claims it, because claiming a slot and
# then not holding it is the same outcome as never claiming it.
assert_latest_is_ours() {
  set +e
  holder="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" \
              --jq '.tag_name' 2>"$err_file")"
  holder_rc=$?
  set -e
  if [ "$holder_rc" -ne 0 ]; then
    if ! grep -qi 'not found\|HTTP 404' "$err_file"; then
      echo "::error::could not read the Latest release: $(cat "$err_file")"
      exit 1
    fi
    holder=''
  fi
  if [ "$holder" != "$tag" ]; then
    echo "::error::Latest is ${holder:-no release}, not $tag, right after claiming it."
    exit 1
  fi
}

assert_tag_absent_or_ours

# Absence must be distinguishable from a token or transport fault. Treating
# every failure as absence turns an auth problem into a confusing create
# failure instead of an auth message.
set +e
view="$(gh release view "$tag" --json isDraft,assets 2>"$err_file")"
view_rc=$?
set -e
view_err="$(cat "$err_file" 2>/dev/null || true)"

if [ "$view_rc" -ne 0 ]; then
  if printf '%s' "$view_err" | grep -qi 'release not found'; then
    echo "Creating draft release $tag targeted at $sha."
    gh release create "$tag" --draft --target "$sha" --title "$title" \
      --notes "Whole-graph exports for the data committed at $sha. Per-source files stay in the repository under api/v1/sources/; these two exceed GitHub's 100 MiB per-file push limit and are published here instead. Stable URLs: https://github.com/$GITHUB_REPOSITORY/releases/latest/download/all.jsonld and https://github.com/$GITHUB_REPOSITORY/releases/latest/download/all.ttl"
    view="$(gh release view "$tag" --json isDraft,assets)"
  else
    echo "::error::gh release view failed for a reason other than absence: $view_err"
    exit 1
  fi
fi

# The release exists from here on, whether it was found or just created, so
# its tag must exist too. The lax check at the top is the only one that had
# run on the published-and-valid path, and it accepts absence: a published
# release with the right assets, holding Latest, whose tag someone deleted,
# reached the "nothing to do" exit and returned 0.
assert_tag_is_ours

is_draft="$(printf '%s' "$view" | jq -r '.isDraft')"

if [ "$is_draft" = "false" ]; then
  if assets_valid "$view"; then
    # `gh release view --json` has no isLatest field, so the
    # repository-global pointer is read from the API endpoint that defines
    # it. One call, no pagination: `gh release list` would need enough
    # --limit to be sure the Latest release is on the page.
    set +e
    latest_tag="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" \
                    --jq '.tag_name' 2>"$err_file")"
    latest_rc=$?
    set -e
    if [ "$latest_rc" -ne 0 ]; then
      # 404 here is a real state: a repository whose every release is a draft
      # or a prerelease has no Latest at all. Anything else is a fault.
      if ! grep -qi 'not found\|HTTP 404' "$err_file"; then
        echo "::error::could not read the Latest release: $(cat "$err_file")"
        exit 1
      fi
      latest_tag=''
    fi

    if [ "$latest_tag" = "$tag" ]; then
      echo "Release $tag is published, carries both assets and holds Latest."
      exit 0
    fi

    echo "::warning::Latest points at ${latest_tag:-no release}, not $tag."
    gh release edit "$tag" --latest
    assert_latest_is_ours
    echo "Reclaimed Latest for $tag."
    exit 0
  fi
  echo "::error::published release $tag does not carry both expected assets."
  echo "::error::Refusing to clobber a published release. Delete it and re-run if it should be rebuilt."
  exit 1
fi

gh release upload "$tag" "$jsonld" "$ttl" --clobber

view="$(gh release view "$tag" --json isDraft,assets)"
if ! assets_valid "$view"; then
  echo "::error::draft $tag does not carry both expected assets after upload."
  printf '%s\n' "$view" >&2
  exit 1
fi

# The tag again, immediately before the release becomes visible. Everything
# between the first check and here is remote work on a draft, and a draft's
# tag can be moved by anything else with write access in that window. Cheap,
# and it turns a silent mismatch into a failed run.
assert_tag_is_ours

gh release edit "$tag" --draft=false --latest

# Read it back. The checks above are time-of-check, and nothing here can make
# the window atomic: anything with contents:write can move the tag or replace
# a draft asset between the last check and this edit. What a readback buys is
# that the mismatch is LOUD. A release whose assets do not match the commit
# its tag resolves to is the one outcome this whole script exists to prevent,
# and a failed workflow run is how a human finds out.
#
# Closing the window rather than narrowing it needs repository settings -- a
# ruleset protecting `api-v1-*` against updates and deletions, and immutable
# releases -- which are the maintainer's to set and are not done here.
view="$(gh release view "$tag" --json isDraft,assets)"
if [ "$(printf '%s' "$view" | jq -r '.isDraft')" != "false" ]; then
  echo "::error::$tag is still a draft after publishing it."
  exit 1
fi
if ! assets_valid "$view"; then
  echo "::error::$tag published, but its assets no longer match this commit."
  printf '%s\n' "$view" >&2
  exit 1
fi
assert_tag_is_ours
assert_latest_is_ours

echo "Published $tag as Latest."
