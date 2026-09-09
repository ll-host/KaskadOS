#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly BUILD_ROOT="${PROJECT_DIR}/build/desktop-package"
readonly PAYLOAD_ROOT="${BUILD_ROOT}/payload"
readonly PACKAGE_ROOT="${BUILD_ROOT}/makepkg"
readonly PACKAGE_DEST="${KASKADOS_PACKAGE_DEST:-${PROJECT_DIR}/out/packages/x86_64}"
readonly MACQUEEN_SOURCE="${PROJECT_DIR}/components/macqueende"
readonly MACQUEEN_BUILD="${BUILD_ROOT}/macqueende"
readonly COMPOSITOR_BUILD="${MACQUEEN_BUILD}/compositor"
readonly PORTAL_BUILD="${MACQUEEN_BUILD}/portal"
readonly QUICKSHELL_BUILD="${MACQUEEN_BUILD}/quickshell-macqueen"
readonly SHELL_BUILD="${MACQUEEN_BUILD}/shell-source"
readonly REGALIA_SOURCE="${PROJECT_DIR}/components/regalia"
readonly REGALIA_BUILD="${BUILD_ROOT}/regalia"
readonly REGALIA_BIN="${REGALIA_BUILD}/bin"
readonly PACKAGE_SOURCE="${PROJECT_DIR}/repository/packages/kaskados-desktop"
readonly DGOP_BUILD_SCRIPT="${SCRIPT_DIR}/build-dgop-package.sh"
readonly SING_BOX_VERSION="1.13.15"
readonly SING_BOX_ARCHIVE="sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
readonly SING_BOX_SHA256="a3a3ff223b23c3f4731d0a17cb0ef94c97ce257c70721a5b07dc7ca079203c9f"
readonly BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
readonly MACQUEEN_BUILD_JOBS="${MACQUEEN_BUILD_JOBS:-8}"
readonly SOURCE_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse HEAD 2>/dev/null || printf 'unknown')"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

for command_name in cmake curl go make makepkg ninja sha256sum tar; do
  command -v "${command_name}" >/dev/null 2>&1 || die "не найдена команда ${command_name}"
done

if (( EUID == 0 )); then
  die 'пакет рабочей среды нужно собирать обычным пользователем'
fi

[[ "$(uname -m)" == x86_64 ]] || die 'сборка поддерживается только на x86_64'
[[ -f "${MACQUEEN_SOURCE}/VERSION" ]] || die 'не найдена версия MacqueenDE'
[[ -f "${MACQUEEN_SOURCE}/release/release.json" ]] || die 'не найден манифест выпуска MacqueenDE'
[[ -f "${REGALIA_SOURCE}/go.mod" ]] || die 'не найден исходный код Regalia'
[[ -f "${PACKAGE_SOURCE}/PKGBUILD" ]] || die 'не найден PKGBUILD kaskados-desktop'
[[ -x "${DGOP_BUILD_SCRIPT}" ]] || die 'не найден скрипт сборки dgop'

install -d -m 0755 \
  "${BUILD_ROOT}" \
  "${PACKAGE_ROOT}/work" \
  "${PACKAGE_ROOT}/sources" \
  "${PACKAGE_DEST}"

KASKADOS_PACKAGE_DEST="${PACKAGE_DEST}" "${DGOP_BUILD_SCRIPT}"

env -u LD_LIBRARY_PATH cmake \
  -S "${MACQUEEN_SOURCE}/compositor" \
  -B "${COMPOSITOR_BUILD}" \
  -G Ninja \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DCMAKE_INSTALL_PREFIX=/opt/macqueende
env -u LD_LIBRARY_PATH cmake --build "${COMPOSITOR_BUILD}" \
  --target macqueen screenshot screencast nightlight \
  --parallel "${MACQUEEN_BUILD_JOBS}"
[[ -f "${COMPOSITOR_BUILD}/bin/kwin/plugins/nightlight.so" ]] \
  || die 'сборка MacqueenDE не создала модуль ночного режима'

env -u LD_LIBRARY_PATH cmake \
  -S "${MACQUEEN_SOURCE}/portal" \
  -B "${PORTAL_BUILD}" \
  -G Ninja \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DCMAKE_INSTALL_PREFIX=/opt/macqueende
env -u LD_LIBRARY_PATH cmake --build "${PORTAL_BUILD}" --parallel "${MACQUEEN_BUILD_JOBS}"

env -u LD_LIBRARY_PATH cmake \
  -S "${MACQUEEN_SOURCE}/quickshell/macqueen-module" \
  -B "${QUICKSHELL_BUILD}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DCMAKE_INSTALL_PREFIX=/opt/macqueende
env -u LD_LIBRARY_PATH cmake --build "${QUICKSHELL_BUILD}" --parallel "${MACQUEEN_BUILD_JOBS}"

if [[ -e "${SHELL_BUILD}" ]]; then
  rm -rf -- "${SHELL_BUILD}"
fi
install -d -m 0755 "${SHELL_BUILD}"
cp -a -- "${MACQUEEN_SOURCE}/shell/MolniyaMacqueenShell/." "${SHELL_BUILD}/"
make -C "${SHELL_BUILD}/core" \
  VERSION="$(tr -d '\n' < "${MACQUEEN_SOURCE}/VERSION")" \
  COMMIT=kaskados \
  build

if [[ -e "${REGALIA_BUILD}" ]]; then
  rm -rf -- "${REGALIA_BUILD}"
fi
install -d -m 0755 "${REGALIA_BIN}"
(
  cd -- "${REGALIA_SOURCE}"
  env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags '-s -w' -o "${REGALIA_BIN}/regalia" ./cmd/regalia
  env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags '-s -w' -o "${REGALIA_BIN}/regaliad" ./cmd/regaliad
  env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags '-s -w' -o "${REGALIA_BIN}/regalia-engine" ./cmd/regalia-engine
)

curl -fL --retry 3 --silent --show-error \
  "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${SING_BOX_ARCHIVE}" \
  -o "${REGALIA_BUILD}/${SING_BOX_ARCHIVE}"
printf '%s  %s\n' "${SING_BOX_SHA256}" "${REGALIA_BUILD}/${SING_BOX_ARCHIVE}" | sha256sum -c -
tar -xzf "${REGALIA_BUILD}/${SING_BOX_ARCHIVE}" -C "${REGALIA_BUILD}"
install -m 0755 \
  "${REGALIA_BUILD}/sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box" \
  "${REGALIA_BIN}/sing-box"

if [[ -e "${PAYLOAD_ROOT}" ]]; then
  rm -rf -- "${PAYLOAD_ROOT}"
fi
readonly MACQUEEN_STAGE="${PAYLOAD_ROOT}/opt/macqueende"
install -d -m 0755 \
  "${MACQUEEN_STAGE}/build/compositor" \
  "${MACQUEEN_STAGE}/build/portal" \
  "${MACQUEEN_STAGE}/build/quickshell-macqueen" \
  "${MACQUEEN_STAGE}/shell/MolniyaMacqueenShell/core/bin" \
  "${PAYLOAD_ROOT}/usr/bin" \
  "${PAYLOAD_ROOT}/usr/lib/systemd/user" \
  "${PAYLOAD_ROOT}/usr/share/applications" \
  "${PAYLOAD_ROOT}/usr/share/dbus-1/services" \
  "${PAYLOAD_ROOT}/usr/share/kaskados/releases" \
  "${PAYLOAD_ROOT}/usr/share/wayland-sessions" \
  "${PAYLOAD_ROOT}/usr/share/xdg-desktop-portal/portals"

cp -a -- "${COMPOSITOR_BUILD}/bin" "${MACQUEEN_STAGE}/build/compositor/"
cp -a -- "${PORTAL_BUILD}/bin" "${MACQUEEN_STAGE}/build/portal/"
cp -a -- "${QUICKSHELL_BUILD}/Macqueen" "${MACQUEEN_STAGE}/build/quickshell-macqueen/"
cp -a -- "${QUICKSHELL_BUILD}"/libquickshell-macqueen.so* \
  "${MACQUEEN_STAGE}/build/quickshell-macqueen/"
install -m 0755 "${SHELL_BUILD}/core/bin/dms" \
  "${MACQUEEN_STAGE}/shell/MolniyaMacqueenShell/core/bin/dms"
cp -a -- \
  "${MACQUEEN_SOURCE}/shell/MolniyaMacqueenShell/quickshell" \
  "${MACQUEEN_SOURCE}/shell/MolniyaMacqueenShell/dank-qml-common" \
  "${MACQUEEN_STAGE}/shell/MolniyaMacqueenShell/"
cp -a -- \
  "${MACQUEEN_SOURCE}/config" \
  "${MACQUEEN_SOURCE}/release" \
  "${MACQUEEN_SOURCE}/session" \
  "${MACQUEEN_SOURCE}/start-macqueende" \
  "${MACQUEEN_STAGE}/"
install -m 0644 "${MACQUEEN_SOURCE}/VERSION" "${MACQUEEN_STAGE}/VERSION"

ln -s /opt/macqueende/shell/MolniyaMacqueenShell/core/bin/dms "${PAYLOAD_ROOT}/usr/bin/dms"
install -m 0755 "${PROJECT_DIR}/profile/airootfs/usr/bin/start-macqueende" \
  "${PAYLOAD_ROOT}/usr/bin/start-macqueende"
install -m 0644 "${PROJECT_DIR}/profile/airootfs/usr/share/wayland-sessions/macqueende.desktop" \
  "${PAYLOAD_ROOT}/usr/share/wayland-sessions/macqueende.desktop"
install -m 0644 "${MACQUEEN_SOURCE}/session/macqueende-portals.conf" \
  "${PAYLOAD_ROOT}/usr/share/xdg-desktop-portal/macqueende-portals.conf"
install -m 0644 "${MACQUEEN_SOURCE}/session/macqueen.portal" \
  "${PAYLOAD_ROOT}/usr/share/xdg-desktop-portal/portals/macqueen.portal"
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
  "${MACQUEEN_SOURCE}/session/org.freedesktop.impl.portal.desktop.macqueen.desktop.in" \
  > "${PAYLOAD_ROOT}/usr/share/applications/org.freedesktop.impl.portal.desktop.macqueen.desktop"
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
  "${MACQUEEN_SOURCE}/session/org.freedesktop.impl.portal.desktop.macqueen.service.in" \
  > "${PAYLOAD_ROOT}/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.macqueen.service"
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
  "${MACQUEEN_SOURCE}/session/xdg-desktop-portal-macqueen.service.in" \
  > "${PAYLOAD_ROOT}/usr/lib/systemd/user/xdg-desktop-portal-macqueen.service"

install -m 0644 "${MACQUEEN_SOURCE}/release/release.json" \
  "${PAYLOAD_ROOT}/usr/share/kaskados/release.json"
find "${MACQUEEN_SOURCE}/release/releases" -maxdepth 1 -type f -name '*.json' \
  -exec install -m 0644 -t "${PAYLOAD_ROOT}/usr/share/kaskados/releases" -- {} +
printf '%s\n' \
  'METHOD=kaskados' \
  "VERSION=$(tr -d '\n' < "${MACQUEEN_SOURCE}/VERSION")" \
  'SOURCE_REPOSITORY=https://github.com/ll-host/KaskadOS' \
  'SOURCE_PATH=components/macqueende' \
  "SOURCE_COMMIT=${SOURCE_COMMIT}" \
  'BUILD_PACKAGES=' \
  'MANAGED_FLAMESHOT=0' \
  > "${MACQUEEN_STAGE}/INSTALL_INFO"

install -Dm0755 "${PROJECT_DIR}/components/system-update/kaskados-system-update" \
  "${PAYLOAD_ROOT}/usr/lib/kaskados/kaskados-system-update"
install -Dm0644 "${PROJECT_DIR}/components/system-update/org.kaskados.system-update.policy" \
  "${PAYLOAD_ROOT}/usr/share/polkit-1/actions/org.kaskados.system-update.policy"
install -Dm0644 "${PROJECT_DIR}/components/file-manager/io.kaskados.Files.desktop" \
  "${PAYLOAD_ROOT}/usr/share/applications/io.kaskados.Files.desktop"
install -Dm0644 "${PROJECT_DIR}/components/file-manager/mimeapps.list" \
  "${PAYLOAD_ROOT}/etc/xdg/mimeapps.list"

install -Dm0755 "${REGALIA_BIN}/regalia" "${PAYLOAD_ROOT}/usr/bin/regalia"
install -Dm0755 "${REGALIA_BIN}/regaliad" "${PAYLOAD_ROOT}/usr/bin/regaliad"
install -Dm0755 "${REGALIA_BIN}/regalia-engine" \
  "${PAYLOAD_ROOT}/usr/lib/regalia/regalia-engine"
install -Dm0755 "${REGALIA_BIN}/sing-box" "${PAYLOAD_ROOT}/usr/lib/regalia/sing-box"
install -Dm0644 "${REGALIA_SOURCE}/packaging/systemd/regalia-engine@.service" \
  "${PAYLOAD_ROOT}/usr/lib/systemd/system/regalia-engine@.service"
install -Dm0644 "${REGALIA_SOURCE}/packaging/systemd/user/regaliad.service" \
  "${PAYLOAD_ROOT}/usr/lib/systemd/user/regaliad.service"
install -Dm0644 "${REGALIA_SOURCE}/packaging/polkit/50-regalia-engine.rules" \
  "${PAYLOAD_ROOT}/usr/share/polkit-1/rules.d/50-regalia-engine.rules"
install -d -m 0755 "${PAYLOAD_ROOT}/etc/systemd/user/default.target.wants"
ln -s /usr/lib/systemd/user/regaliad.service \
  "${PAYLOAD_ROOT}/etc/systemd/user/default.target.wants/regaliad.service"

desktop_pkgver="$(tr '-' '_' < "${MACQUEEN_SOURCE}/VERSION" | tr -d '\n')"
desktop_pkgrel="${KASKADOS_DESKTOP_PKGREL:-1}"
(
  cd -- "${PACKAGE_SOURCE}"
  env \
    KASKADOS_DESKTOP_PAYLOAD="${PAYLOAD_ROOT}" \
    KASKADOS_DESKTOP_PKGVER="${desktop_pkgver}" \
    KASKADOS_DESKTOP_PKGREL="${desktop_pkgrel}" \
    BUILDDIR="${PACKAGE_ROOT}/work" \
    PKGDEST="${PACKAGE_DEST}" \
    SRCDEST="${PACKAGE_ROOT}/sources" \
    makepkg --cleanbuild --force --nodeps
)

mapfile -t packages < <(
  find "${PACKAGE_DEST}" -maxdepth 1 -type f \
    -name "kaskados-desktop-${desktop_pkgver}-${desktop_pkgrel}-x86_64.pkg.tar.zst" -print
)
(( ${#packages[@]} == 1 )) || die 'не удалось однозначно определить пакет kaskados-desktop'
printf 'Пакет рабочей среды готов: %s\n' "${packages[0]}"
