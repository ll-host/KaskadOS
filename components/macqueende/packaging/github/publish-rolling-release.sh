#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
repo=${MACQUEENDE_GITHUB_REPO:-ll-host/KaskadOS}
tag=${MACQUEENDE_ROLLING_TAG:-macqueende-rolling}
version=${1:?usage: publish-rolling-release.sh VERSION [ARCH]}
arch=${2:-x86_64}

[[ "$version" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || {
    echo "invalid release version: $version" >&2
    exit 1
}
command -v gh >/dev/null 2>&1 || {
    echo "GitHub CLI (gh) is required." >&2
    exit 1
}
gh auth status >/dev/null
gh release view "$tag" --repo "$repo" >/dev/null 2>&1 || {
    echo "The permanent '$tag' release is missing; refusing to create another release." >&2
    exit 1
}

cd "$repo_root"
[[ -z $(git status --short --untracked-files=no) ]] || {
    echo "Commit tracked changes before publishing the rolling release." >&2
    exit 1
}

archive=$("$repo_root/packaging/github/build-binary-release.sh" \
    "$version" "$arch")
checksum="$archive.sha256"
[[ -f "$archive" && -f "$checksum" ]] || {
    echo "release builder did not produce the expected archive and checksum" >&2
    exit 1
}

new_archive=$(basename "$archive")
new_checksum=$(basename "$checksum")

# Upload first so a failed transfer never leaves the rolling release empty.
gh release upload "$tag" "$archive" "$checksum" \
    --repo "$repo" \
    --clobber

mapfile -t assets < <(
    gh release view "$tag" \
        --repo "$repo" \
        --json assets \
        --jq '.assets[].name'
)
for asset in "${assets[@]}"; do
    case "$asset" in
        "$new_archive"|"$new_checksum")
            ;;
        *)
            gh release delete-asset "$tag" "$asset" \
                --repo "$repo" \
                --yes
            ;;
    esac
done

commit_sha=$(git rev-parse HEAD)
gh api \
    --method PATCH \
    "repos/$repo/git/refs/tags/$tag" \
    -f sha="$commit_sha" \
    -F force=true >/dev/null

gh release edit "$tag" \
    --repo "$repo" \
    --target "$commit_sha" \
    --title "MacqueenDE Rolling — $version" \
    --notes "Rolling binary build $version from commit $commit_sha. This single release is updated in place." \
    --prerelease >/dev/null

printf 'Updated %s/releases/tag/%s with %s\n' \
    "https://github.com/$repo" "$tag" "$new_archive"
