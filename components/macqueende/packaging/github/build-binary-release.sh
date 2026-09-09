#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
version=${1:?usage: build-binary-release.sh VERSION}
arch=${2:-x86_64}
stage="$repo_root/dist/macqueende-$version-$arch"
archive="$repo_root/dist/macqueende-$version-$arch.tar.zst"
payload="$stage/opt/macqueende"

case "$arch" in
    x86_64) ;;
    *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac

required=(
    build/compositor/bin/macqueen
    build/compositor/bin/libkwin.so.6.7.3
    build/compositor/bin/kwin/plugins/screenshot.so
    build/compositor/bin/kwin/plugins/screencast.so
    build/compositor/bin/kwin/plugins/nightlight.so
    build/portal/bin/xdg-desktop-portal-macqueen
    build/quickshell-macqueen/libquickshell-macqueen.so
    build/quickshell-macqueen/Macqueen/Ipc/qmldir
    shell/MolniyaMacqueenShell/core/bin/dms
)
for path in "${required[@]}"; do
    [[ -e "$repo_root/$path" ]] || {
        echo "missing release input: $path" >&2
        exit 1
    }
done

mkdir -p "$repo_root/dist"
if [[ -e "$stage" ]]; then
    echo "refusing to overwrite existing stage: $stage" >&2
    exit 1
fi
mkdir -p "$payload/build/compositor" \
         "$payload/build/portal" \
         "$payload/build/quickshell-macqueen" \
         "$payload/installer" \
         "$payload/shell/MolniyaMacqueenShell/core/bin" \
         "$payload/shell/MolniyaMacqueenShell"

cp -a "$repo_root/build/compositor/bin" "$payload/build/compositor/"
cp -a "$repo_root/build/portal/bin" "$payload/build/portal/"
cp -a "$repo_root/build/quickshell-macqueen/Macqueen" "$payload/build/quickshell-macqueen/"
cp -a "$repo_root/build/quickshell-macqueen/libquickshell-macqueen.so" \
      "$payload/build/quickshell-macqueen/"
cp -a "$repo_root/shell/MolniyaMacqueenShell/core/bin/dms" \
      "$payload/shell/MolniyaMacqueenShell/core/bin/"
cp -a "$repo_root/shell/MolniyaMacqueenShell/quickshell" \
      "$payload/shell/MolniyaMacqueenShell/"
cp -a "$repo_root/shell/MolniyaMacqueenShell/dank-qml-common" \
      "$payload/shell/MolniyaMacqueenShell/"
cp -a "$repo_root/config" "$repo_root/session" "$repo_root/start-macqueende" \
      "$payload/"
install -Dm755 "$repo_root/installer/macqueende-manager" \
    "$payload/installer/macqueende-manager"
install -Dm755 "$repo_root/installer/uninstall-release.sh" \
    "$payload/installer/uninstall-release.sh"

# Remove build-only helpers and shrink debug builds without changing runtime files.
find "$payload/build" -type f -perm -u+x -exec strip --strip-unneeded {} + 2>/dev/null || true
find "$payload/build" -type f -name '*.so*' -exec strip --strip-unneeded {} + 2>/dev/null || true
strip --strip-unneeded "$payload/shell/MolniyaMacqueenShell/core/bin/dms" 2>/dev/null || true

module_plugin="$payload/build/quickshell-macqueen/Macqueen/Ipc/libquickshell-macqueenplugin.so"
if missing=$(
    LD_LIBRARY_PATH="$payload/build/quickshell-macqueen" \
        ldd "$module_plugin" |
        awk '/not found/ {print}'
); [[ -n "$missing" ]]; then
    printf 'release contains an unloadable Macqueen QML plugin:\n%s\n' \
        "$missing" >&2
    exit 1
fi

install -Dm755 "$repo_root/installer/install-release-payload.sh" \
    "$stage/install.sh"
install -Dm755 "$repo_root/installer/uninstall-release.sh" \
    "$stage/uninstall.sh"
printf '%s\n' "$version" >"$payload/VERSION"

tar --zstd -C "$stage" -cf "$archive" .
sha256sum "$archive" >"$archive.sha256"
printf '%s\n' "$archive"
