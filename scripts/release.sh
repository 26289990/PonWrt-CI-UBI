#!/usr/bin/env bash
# Pin the CI commit before building; publication must only use that existing tag.
set -euo pipefail

mode="${1:?usage: release.sh prepare|publish}"
: "${GITHUB_SHA:?}" "${GITHUB_RUN_NUMBER:?}" "${GITHUB_RUN_ID:?}"
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GITHUB_RUN_NUMBER" =~ ^[0-9]+$ && "$GITHUB_RUN_ID" =~ ^[0-9]+$ ]]
TAG="ponwrt-r${GITHUB_RUN_NUMBER}-${GITHUB_RUN_ID}"
remote_ref="refs/tags/$TAG"
existing="$(git ls-remote --refs origin "$remote_ref")"

case "$mode" in
  prepare)
    : "${GITHUB_OUTPUT:?}"
    if [[ -z "$existing" ]]; then
      git push origin "$GITHUB_SHA:$remote_ref"
    fi
    ;;
  publish)
    : "${GITHUB_REPOSITORY:?}" "${RELEASE_TAG:?}"
    [[ "$RELEASE_TAG" == "$TAG" ]] || { echo 'Release tag does not match this run' >&2; exit 1; }
    ;;
  *) echo 'usage: release.sh prepare|publish' >&2; exit 1 ;;
esac

# Check again after creation and reject tags pointing at a different CI commit.
existing="$(git ls-remote --refs origin "$remote_ref")"
[[ "$existing" == "$GITHUB_SHA"$'\t'"$remote_ref" ]] || {
  echo "Release tag $TAG is missing or does not point to $GITHUB_SHA" >&2
  exit 1
}

if [[ "$mode" == prepare ]]; then
  printf 'release_tag=%s\n' "$TAG" >> "$GITHUB_OUTPUT"
else
  BUILD_DATE="$(TZ=Asia/Shanghai date +'%Y.%m.%d-%H%M')"
  gh release create "$TAG" output/* \
    --repo "$GITHUB_REPOSITORY" --verify-tag \
    --title "PonWrt all PON devices ${BUILD_DATE}" \
    --notes-file release-notes.md --latest
fi
