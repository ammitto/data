#!/usr/bin/env bash
# Publish the two oversized aggregates as assets on a release keyed to the
# data commit they were built from.
#
# Ronald ruled on 2026-09-01 that "the all.json output is not a contract, for
# files so large we should use GitHub releases." git refuses them at 100 MB;
# a release asset allows 2 GiB.
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
# slot. This workflow marks its release Latest explicitly, so it owns that
# slot. Another release published in this repository would take it, and a
# later unchanged harmonization would see its own release as valid, exit
# without restoring Latest, and leave the site's stable URL pointing at the
# other one. If this repository ever needs a second kind of release, the site
# needs a redirect it controls rather than `latest`.
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
set +e
tag_sha="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" --jq '.object.sha' 2>/dev/null)"
set -e
if [ -n "${tag_sha:-}" ] && [ "$tag_sha" != "$sha" ]; then
  echo "::error::tag $tag already exists and resolves to $tag_sha, not $sha."
  echo "::error::Refusing to publish a release whose tag points at a different commit."
  exit 1
fi

# Absence must be distinguishable from a token or transport fault. Treating
# every failure as absence turns an auth problem into a confusing create
# failure instead of an auth message.
set +e
view="$(gh release view "$tag" --json isDraft,assets 2>/tmp/publish_aggregates.err)"
view_rc=$?
set -e
view_err="$(cat /tmp/publish_aggregates.err 2>/dev/null || true)"

if [ "$view_rc" -ne 0 ]; then
  if printf '%s' "$view_err" | grep -qi 'release not found'; then
    echo "Creating draft release $tag targeted at $sha."
    gh release create "$tag" --draft --target "$sha" --title "$title" \
      --notes "Whole-graph exports for the data committed at $sha. Per-source files stay in the repository under api/v1/sources/; these two exceed the per-file limit git enforces and are published here instead. Stable URL: https://github.com/ammitto/data/releases/latest/download/all.jsonld"
    view="$(gh release view "$tag" --json isDraft,assets)"
  else
    echo "::error::gh release view failed for a reason other than absence: $view_err"
    exit 1
  fi
fi

is_draft="$(printf '%s' "$view" | jq -r '.isDraft')"

if [ "$is_draft" = "false" ]; then
  if assets_valid "$view"; then
    echo "Release $tag is already published and carries both assets; nothing to do."
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

gh release edit "$tag" --draft=false --latest
echo "Published $tag as Latest."
