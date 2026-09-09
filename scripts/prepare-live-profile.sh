#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SOURCE_PROFILE="${PROJECT_DIR}/profile"
readonly BUILD_ROOT="${PROJECT_DIR}/build"
readonly COMPOSITOR_BUILD="${BUILD_ROOT}/kaskad-installer-compositor"
readonly CALAMARES_BUILD="${BUILD_ROOT}/calamares"
readonly MACQUEENDE_SOURCE="${PROJECT_DIR}/components/macqueende"
readonly MACQUEENDE_BUILD="${BUILD_ROOT}/macqueende"
readonly MACQUEEN_COMPOSITOR_BUILD="${MACQUEENDE_BUILD}/compositor"
readonly MACQUEEN_PORTAL_BUILD="${MACQUEENDE_BUILD}/portal"
readonly MACQUEEN_QUICKSHELL_BUILD="${MACQUEENDE_BUILD}/quickshell-macqueen"
readonly MACQUEEN_SHELL_BUILD="${MACQUEENDE_BUILD}/shell-source"
readonly REGALIA_SOURCE="${PROJECT_DIR}/components/regalia"
readonly REGALIA_BUILD="${BUILD_ROOT}/regalia"
readonly REGALIA_BIN="${REGALIA_BUILD}/bin"
readonly SING_BOX_VERSION="1.13.15"
readonly SING_BOX_ARCHIVE="sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
readonly SING_BOX_SHA256="a3a3ff223b23c3f4731d0a17cb0ef94c97ce257c70721a5b07dc7ca079203c9f"
readonly INSTALLER_THEMES="${PROJECT_DIR}/components/installer-themes"
readonly KEYRING_PACKAGE_SOURCE="${PROJECT_DIR}/repository/packages/kaskados-keyring"
readonly DESKTOP_PACKAGE_SOURCE="${PROJECT_DIR}/repository/packages/kaskados-desktop"
readonly DGOP_BUILD_SCRIPT="${SCRIPT_DIR}/build-dgop-package.sh"
readonly BOOTSTRAP_REPOSITORY="${BUILD_ROOT}/repository-bootstrap/x86_64"
readonly BOOTSTRAP_PACKAGE_CACHE="${BUILD_ROOT}/repository-bootstrap/cache"
readonly NVIDIA_580XX_SOURCE="${BUILD_ROOT}/repository-bootstrap/nvidia-580xx-utils"
readonly NVIDIA_580XX_32_SOURCE="${BUILD_ROOT}/repository-bootstrap/lib32-nvidia-580xx-utils"
readonly NVIDIA_580XX_COMMIT="85c38619ce2267787d0515baa443739cb9d2883c"
readonly NVIDIA_580XX_32_COMMIT="bbe7b771c897f78e518ab4453b0bc9210ef2f201"
readonly PROFILE_DIR="${PROFILE_DIR:-${BUILD_ROOT}/iso-profile}"
readonly BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
readonly MACQUEEN_BUILD_JOBS="${MACQUEEN_BUILD_JOBS:-8}"
readonly MACQUEEN_SOURCE_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse HEAD 2>/dev/null || printf 'unknown')"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

for command_name in bsdtar cmake curl go ldd make makepkg ninja pacman readelf repo-add sha256sum tar; do
  command -v "${command_name}" >/dev/null 2>&1 || die "не найдена команда ${command_name}"
done

required_build_packages=(
  base-devel
  curl
  extra-cmake-modules
  git
  go
  kpmcore
  kwin
  libpwquality
  plasma-wayland-protocols
  qt6-declarative
  vulkan-headers
  wayland-protocols
  plasma-workspace
  yaml-cpp
)
mapfile -t missing_build_packages < <(pacman -T "${required_build_packages[@]}" 2>/dev/null || true)
if (( ${#missing_build_packages[@]} > 0 )); then
  printf 'Не установлены пакеты для сборки:\n' >&2
  printf '  %s\n' "${missing_build_packages[@]}" >&2
  printf 'Установите их командой:\n  sudo pacman -S --needed' >&2
  printf ' %q' "${missing_build_packages[@]}" >&2
  printf '\n' >&2
  exit 2
fi

[[ "$(uname -m)" == 'x86_64' ]] || die 'сборка поддерживается только на x86_64'
[[ "$(realpath -m -- "${PROFILE_DIR}")" == "${BUILD_ROOT}"/* ]] || die 'подготовленный профиль должен находиться внутри build/'
[[ -d "${INSTALLER_THEMES}/grub" ]] || die 'не найдены темы GRUB для установщика'
[[ -d "${INSTALLER_THEMES}/sddm" ]] || die 'не найдены темы SDDM для установщика'
[[ -d "${INSTALLER_THEMES}/previews" ]] || die 'не найдены превью тем для установщика'
[[ -f "${MACQUEENDE_SOURCE}/VERSION" ]] || die 'не найден исходный код MacqueenDE'
[[ -f "${MACQUEENDE_SOURCE}/release/release.json" ]] || die 'не найден манифест выпуска MacqueenDE'
[[ -f "${PROJECT_DIR}/components/system-update/kaskados-system-update" ]] \
  || die 'не найден системный помощник обновлений'
[[ -f "${PROJECT_DIR}/components/system-update/org.kaskados.system-update.policy" ]] \
  || die 'не найдена политика системного помощника обновлений'
[[ -f "${PROJECT_DIR}/components/file-manager/io.kaskados.Files.desktop" ]] \
  || die 'не найден ярлык файлового менеджера KaskadOS'
[[ -f "${PROJECT_DIR}/components/file-manager/mimeapps.list" ]] \
  || die 'не найдены MIME-настройки файлового менеджера KaskadOS'
[[ -f "${MACQUEENDE_SOURCE}/session/macqueende.desktop" ]] || die 'не найдена сессия MacqueenDE'
[[ -f "${REGALIA_SOURCE}/go.mod" ]] || die 'не найден исходный код Regalia'
[[ -f "${REGALIA_SOURCE}/packaging/systemd/user/regaliad.service" ]] \
  || die 'не найдена пользовательская служба Regalia'
[[ -f "${KEYRING_PACKAGE_SOURCE}/PKGBUILD" ]] \
  || die 'не найден пакет kaskados-keyring'
[[ -f "${DESKTOP_PACKAGE_SOURCE}/PKGBUILD" ]] \
  || die 'не найден пакет kaskados-desktop'
[[ -x "${DGOP_BUILD_SCRIPT}" ]] || die 'не найден скрипт сборки dgop'

"${SCRIPT_DIR}/check-profile.sh"

if (( EUID == 0 )); then
  die 'подготовку live-профиля запускайте обычным пользователем; sudo вызовет только mkarchiso'
fi

if [[ -e "${BUILD_ROOT}/repository-bootstrap" ]]; then
  rm -rf -- "${BUILD_ROOT}/repository-bootstrap"
fi
install -d -m 0755 \
  "${BOOTSTRAP_REPOSITORY}" \
  "${BOOTSTRAP_PACKAGE_CACHE}" \
  "${BUILD_ROOT}/repository-bootstrap/work" \
  "${BUILD_ROOT}/repository-bootstrap/sources"
(
  cd -- "${KEYRING_PACKAGE_SOURCE}"
  env \
    BUILDDIR="${BUILD_ROOT}/repository-bootstrap/work" \
    PKGDEST="${BOOTSTRAP_REPOSITORY}" \
    SRCDEST="${BUILD_ROOT}/repository-bootstrap/sources" \
    makepkg --cleanbuild --force --nodeps
)
mapfile -t keyring_packages < <(
  find "${BOOTSTRAP_REPOSITORY}" -maxdepth 1 -type f \
    -name 'kaskados-keyring-*.pkg.tar.zst' -print
)
(( ${#keyring_packages[@]} == 1 )) \
  || die 'не удалось однозначно определить собранный пакет kaskados-keyring'

KASKADOS_PACKAGE_DEST="${BOOTSTRAP_REPOSITORY}" \
KASKADOS_DGOP_BUILD_ROOT="${BUILD_ROOT}/repository-bootstrap/dgop" \
  "${DGOP_BUILD_SCRIPT}"
mapfile -t dgop_packages < <(
  find "${BOOTSTRAP_REPOSITORY}" -maxdepth 1 -type f \
    -name 'dgop-[0-9]*-x86_64.pkg.tar.zst' -print
)
(( ${#dgop_packages[@]} == 1 )) \
  || die 'не удалось однозначно определить собранный пакет dgop'
repo-add "${BOOTSTRAP_REPOSITORY}/kaskados-bootstrap.db.tar.gz" \
  "${keyring_packages[0]}" \
  "${dgop_packages[0]}"

fetch_aur_snapshot() {
  local repository_url=$1
  local commit=$2
  local destination=$3

  git init -q "${destination}"
  git -C "${destination}" remote add origin "${repository_url}"
  git -C "${destination}" fetch -q --depth 1 origin "${commit}"
  git -C "${destination}" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "${destination}" rev-parse HEAD)" == "${commit}" ]] \
    || die "не удалось зафиксировать AUR-снимок ${repository_url}"
}

fetch_aur_snapshot \
  'https://aur.archlinux.org/nvidia-580xx-utils.git' \
  "${NVIDIA_580XX_COMMIT}" \
  "${NVIDIA_580XX_SOURCE}"
fetch_aur_snapshot \
  'https://aur.archlinux.org/lib32-nvidia-580xx-utils.git' \
  "${NVIDIA_580XX_32_COMMIT}" \
  "${NVIDIA_580XX_32_SOURCE}"

for nvidia_source in "${NVIDIA_580XX_SOURCE}" "${NVIDIA_580XX_32_SOURCE}"; do
  (
    cd -- "${nvidia_source}"
    env \
      BUILDDIR="${BUILD_ROOT}/repository-bootstrap/work" \
      PKGDEST="${BOOTSTRAP_REPOSITORY}" \
      SRCDEST="${BUILD_ROOT}/repository-bootstrap/sources" \
      makepkg --cleanbuild --force --nodeps
  )
done

nvidia_packages=()
for package_pattern in \
  'nvidia-580xx-dkms-[0-9]*-x86_64.pkg.tar.zst' \
  'nvidia-580xx-utils-[0-9]*-x86_64.pkg.tar.zst' \
  'lib32-nvidia-580xx-utils-[0-9]*-x86_64.pkg.tar.zst'; do
  mapfile -t matching_packages < <(
    find "${BOOTSTRAP_REPOSITORY}" -maxdepth 1 -type f -name "${package_pattern}" -print
  )
  (( ${#matching_packages[@]} == 1 )) \
    || die "не удалось однозначно определить пакет ${package_pattern}"
  nvidia_packages+=("${matching_packages[0]}")
done
repo-add "${BOOTSTRAP_REPOSITORY}/kaskados-bootstrap.db.tar.gz" \
  "${nvidia_packages[@]}"

env -u LD_LIBRARY_PATH cmake -S "${PROJECT_DIR}/components/kaskad-installer-compositor" -B "${COMPOSITOR_BUILD}" -G Ninja \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DKASKAD_INSTALLER_MINIMAL=ON \
  -DKWIN_BUILD_ACTIVITIES=OFF \
  -DKWIN_BUILD_DECORATIONS=OFF \
  -DKWIN_BUILD_EIS=OFF \
  -DKWIN_BUILD_GAMECONTROLLER=OFF \
  -DKWIN_BUILD_GLOBALSHORTCUTS=OFF \
  -DKWIN_BUILD_KCMS=OFF \
  -DKWIN_BUILD_NOTIFICATIONS=OFF \
  -DKWIN_BUILD_QACCESSIBILITYCLIENT=OFF \
  -DKWIN_BUILD_RUNNERS=OFF \
  -DKWIN_BUILD_SCREENLOCKER=OFF \
  -DKWIN_BUILD_TABBOX=OFF \
  -DKWIN_BUILD_X11=OFF
env -u LD_LIBRARY_PATH cmake --build "${COMPOSITOR_BUILD}" --target kaskad-installer --parallel "${BUILD_JOBS}"

env -u LD_LIBRARY_PATH cmake -S "${MACQUEENDE_SOURCE}/compositor" -B "${MACQUEEN_COMPOSITOR_BUILD}" -G Ninja \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DCMAKE_INSTALL_PREFIX=/opt/macqueende
env -u LD_LIBRARY_PATH cmake --build "${MACQUEEN_COMPOSITOR_BUILD}" \
  --target macqueen screenshot screencast nightlight \
  --parallel "${MACQUEEN_BUILD_JOBS}"
[[ -f "${MACQUEEN_COMPOSITOR_BUILD}/bin/kwin/plugins/nightlight.so" ]] \
  || die 'сборка MacqueenDE не создала модуль ночного режима'

env -u LD_LIBRARY_PATH cmake -S "${MACQUEENDE_SOURCE}/portal" -B "${MACQUEEN_PORTAL_BUILD}" -G Ninja \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DCMAKE_INSTALL_PREFIX=/opt/macqueende
env -u LD_LIBRARY_PATH cmake --build "${MACQUEEN_PORTAL_BUILD}" --parallel "${MACQUEEN_BUILD_JOBS}"

env -u LD_LIBRARY_PATH cmake -S "${MACQUEENDE_SOURCE}/quickshell/macqueen-module" -B "${MACQUEEN_QUICKSHELL_BUILD}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DCMAKE_INSTALL_PREFIX=/opt/macqueende
env -u LD_LIBRARY_PATH cmake --build "${MACQUEEN_QUICKSHELL_BUILD}" --parallel "${MACQUEEN_BUILD_JOBS}"

if [[ -e "${MACQUEEN_SHELL_BUILD}" ]]; then
  rm -rf -- "${MACQUEEN_SHELL_BUILD}"
fi
mkdir -p -- "${MACQUEEN_SHELL_BUILD}"
cp -a -- "${MACQUEENDE_SOURCE}/shell/MolniyaMacqueenShell/." "${MACQUEEN_SHELL_BUILD}/"
make -C "${MACQUEEN_SHELL_BUILD}/core" \
  VERSION="$(tr -d '\n' < "${MACQUEENDE_SOURCE}/VERSION")" \
  COMMIT=kaskados \
  build

if [[ -e "${REGALIA_BUILD}" ]]; then
  rm -rf -- "${REGALIA_BUILD}"
fi
mkdir -p -- "${REGALIA_BIN}"
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
printf '%s  %s\n' "${SING_BOX_SHA256}" "${REGALIA_BUILD}/${SING_BOX_ARCHIVE}" \
  | sha256sum -c -
tar -xzf "${REGALIA_BUILD}/${SING_BOX_ARCHIVE}" -C "${REGALIA_BUILD}"
install -m 0755 \
  "${REGALIA_BUILD}/sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box" \
  "${REGALIA_BIN}/sing-box"

env -u LD_LIBRARY_PATH cmake -S "${PROJECT_DIR}/components/calamares" -B "${CALAMARES_BUILD}" -G Ninja \
  -DBUILD_SCHEMA_TESTING=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DINSTALL_CONFIG=ON \
  -DWITH_QT6=ON
env -u LD_LIBRARY_PATH cmake --build "${CALAMARES_BUILD}" --parallel "${BUILD_JOBS}"

if [[ -e "${PROFILE_DIR}" ]]; then
  rm -rf -- "${PROFILE_DIR}"
fi
mkdir -p -- "${PROFILE_DIR}"
cp -a -- "${SOURCE_PROFILE}/." "${PROFILE_DIR}/"

# Для сборки ISO не используем случайный порядок зеркал хост-системы: одно
# зависшее зеркало иначе останавливает всю установку пакетов в airootfs.
# Эти серверы относятся только к временному профилю сборки. В установленную
# систему по-прежнему попадает исходный pacman.conf с обычным mirrorlist.
sed -i \
  '/^Include = \/etc\/pacman.d\/mirrorlist$/c\Server = https://de.arch.mirror.kescher.at/$repo/os/$arch\
Server = https://ftp.halifax.rwth-aachen.de/archlinux/$repo/os/$arch\
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch' \
  "${PROFILE_DIR}/pacman.conf"
grep -Fqx 'Server = https://de.arch.mirror.kescher.at/$repo/os/$arch' \
  "${PROFILE_DIR}/pacman.conf" \
  || die 'не удалось настроить основное зеркало Arch для сборки ISO'
if grep -Fqx 'Include = /etc/pacman.d/mirrorlist' "${PROFILE_DIR}/pacman.conf"; then
  die 'в профиле сборки осталась зависимость от списка зеркал хост-системы'
fi
sed -i \
  -e 's/^ParallelDownloads = .*/ParallelDownloads = 3/' \
  -e '/^ParallelDownloads = 3$/a DisableDownloadTimeout' \
  "${PROFILE_DIR}/pacman.conf"
grep -Fqx 'DisableDownloadTimeout' "${PROFILE_DIR}/pacman.conf" \
  || die 'не удалось отключить тайм-аут медленной загрузки для сборки ISO'

# Временные пакеты bootstrap-репозитория пересобираются под теми же версиями.
# Отдельный свежий кэш не позволяет pacman взять одноимённый пакет от прошлой сборки.
sed -i \
  "s|^#CacheDir.*|CacheDir = ${BOOTSTRAP_PACKAGE_CACHE}/|" \
  "${PROFILE_DIR}/pacman.conf"
grep -Fqx "CacheDir = ${BOOTSTRAP_PACKAGE_CACHE}/" "${PROFILE_DIR}/pacman.conf" \
  || die 'не удалось настроить отдельный кэш пакетов для сборки ISO'

install -Dm0644 "${SOURCE_PROFILE}/pacman.conf" \
  "${PROFILE_DIR}/airootfs/etc/pacman.conf"
sed -i \
  "/^\[core\]$/i [kaskados]\nSigLevel = Required DatabaseRequired\nServer = https://repo.kaskados.xyz/\$arch\n" \
  "${PROFILE_DIR}/airootfs/etc/pacman.conf"
sed -i \
  "/^\[core\]$/i [kaskados-bootstrap]\nSigLevel = Optional TrustAll\nServer = file://${BOOTSTRAP_REPOSITORY}\n" \
  "${PROFILE_DIR}/pacman.conf"
printf '%s\n' 'kaskados-keyring' >> "${PROFILE_DIR}/packages.x86_64"
printf '%s\n' 'dgop' >> "${PROFILE_DIR}/packages.x86_64"
printf '%s\n' \
  'nvidia-580xx-dkms' \
  'nvidia-580xx-utils' \
  'lib32-nvidia-580xx-utils' \
  'nvidia-prime' \
  >> "${PROFILE_DIR}/packages.x86_64"

install -d -m 0755 \
  "${PROFILE_DIR}/airootfs/usr/share/kaskados-installer/theme-pool" \
  "${PROFILE_DIR}/airootfs/usr/share/kaskados-installer/theme-previews"
cp -a -- \
  "${INSTALLER_THEMES}/grub" \
  "${INSTALLER_THEMES}/sddm" \
  "${INSTALLER_THEMES}/SOURCES.md" \
  "${PROFILE_DIR}/airootfs/usr/share/kaskados-installer/theme-pool/"
cp -a -- \
  "${INSTALLER_THEMES}/previews/." \
  "${PROFILE_DIR}/airootfs/usr/share/kaskados-installer/theme-previews/"

DESTDIR="${PROFILE_DIR}/airootfs" env -u LD_LIBRARY_PATH cmake --install "${CALAMARES_BUILD}" --strip

install -d -m 0755 "${PROFILE_DIR}/airootfs/opt/kaskados-installer/bin"
install -m 0755 \
  "${COMPOSITOR_BUILD}/bin/kaskad-installer" \
  "${PROFILE_DIR}/airootfs/opt/kaskados-installer/bin/kaskad-installer"
cp -a -- \
  "${COMPOSITOR_BUILD}"/bin/libkwin.so* \
  "${PROFILE_DIR}/airootfs/opt/kaskados-installer/bin/"

readonly MACQUEEN_STAGE="${PROFILE_DIR}/airootfs/opt/macqueende"
install -d -m 0755 \
  "${MACQUEEN_STAGE}/build/compositor" \
  "${MACQUEEN_STAGE}/build/portal" \
  "${MACQUEEN_STAGE}/build/quickshell-macqueen" \
  "${MACQUEEN_STAGE}/shell/MolniyaMacqueenShell/core/bin" \
  "${PROFILE_DIR}/airootfs/usr/bin" \
  "${PROFILE_DIR}/airootfs/usr/lib/systemd/user" \
  "${PROFILE_DIR}/airootfs/usr/share/applications" \
  "${PROFILE_DIR}/airootfs/usr/share/dbus-1/services" \
  "${PROFILE_DIR}/airootfs/usr/share/xdg-desktop-portal/portals"
cp -a -- "${MACQUEEN_COMPOSITOR_BUILD}/bin" "${MACQUEEN_STAGE}/build/compositor/"
cp -a -- "${MACQUEEN_PORTAL_BUILD}/bin" "${MACQUEEN_STAGE}/build/portal/"
cp -a -- "${MACQUEEN_QUICKSHELL_BUILD}/Macqueen" "${MACQUEEN_STAGE}/build/quickshell-macqueen/"
cp -a -- "${MACQUEEN_QUICKSHELL_BUILD}"/libquickshell-macqueen.so* \
  "${MACQUEEN_STAGE}/build/quickshell-macqueen/"
install -m 0755 "${MACQUEEN_SHELL_BUILD}/core/bin/dms" \
  "${MACQUEEN_STAGE}/shell/MolniyaMacqueenShell/core/bin/dms"
ln -sfn /opt/macqueende/shell/MolniyaMacqueenShell/core/bin/dms \
  "${PROFILE_DIR}/airootfs/usr/bin/dms"
cp -a -- \
  "${MACQUEENDE_SOURCE}/shell/MolniyaMacqueenShell/quickshell" \
  "${MACQUEENDE_SOURCE}/shell/MolniyaMacqueenShell/dank-qml-common" \
  "${MACQUEEN_STAGE}/shell/MolniyaMacqueenShell/"
cp -a -- \
  "${MACQUEENDE_SOURCE}/config" \
  "${MACQUEENDE_SOURCE}/release" \
  "${MACQUEENDE_SOURCE}/session" \
  "${MACQUEENDE_SOURCE}/start-macqueende" \
  "${MACQUEEN_STAGE}/"
install -m 0644 "${MACQUEENDE_SOURCE}/session/macqueende-portals.conf" \
  "${PROFILE_DIR}/airootfs/usr/share/xdg-desktop-portal/macqueende-portals.conf"
install -m 0644 "${MACQUEENDE_SOURCE}/session/macqueen.portal" \
  "${PROFILE_DIR}/airootfs/usr/share/xdg-desktop-portal/portals/macqueen.portal"
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
  "${MACQUEENDE_SOURCE}/session/org.freedesktop.impl.portal.desktop.macqueen.desktop.in" \
  > "${PROFILE_DIR}/airootfs/usr/share/applications/org.freedesktop.impl.portal.desktop.macqueen.desktop"
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
  "${MACQUEENDE_SOURCE}/session/org.freedesktop.impl.portal.desktop.macqueen.service.in" \
  > "${PROFILE_DIR}/airootfs/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.macqueen.service"
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
  "${MACQUEENDE_SOURCE}/session/xdg-desktop-portal-macqueen.service.in" \
  > "${PROFILE_DIR}/airootfs/usr/lib/systemd/user/xdg-desktop-portal-macqueen.service"
install -m 0644 "${MACQUEENDE_SOURCE}/VERSION" "${MACQUEEN_STAGE}/VERSION"
install -d -m 0755 "${PROFILE_DIR}/airootfs/usr/share/kaskados/releases"
install -m 0644 "${MACQUEENDE_SOURCE}/release/release.json" \
  "${PROFILE_DIR}/airootfs/usr/share/kaskados/release.json"
find "${MACQUEENDE_SOURCE}/release/releases" -maxdepth 1 -type f -name '*.json' \
  -exec install -m 0644 -t "${PROFILE_DIR}/airootfs/usr/share/kaskados/releases" -- {} +
install -Dm0755 "${PROJECT_DIR}/components/system-update/kaskados-system-update" \
  "${PROFILE_DIR}/airootfs/usr/lib/kaskados/kaskados-system-update"
install -Dm0644 "${PROJECT_DIR}/components/system-update/org.kaskados.system-update.policy" \
  "${PROFILE_DIR}/airootfs/usr/share/polkit-1/actions/org.kaskados.system-update.policy"
install -Dm0644 "${PROJECT_DIR}/components/file-manager/io.kaskados.Files.desktop" \
  "${PROFILE_DIR}/airootfs/usr/share/applications/io.kaskados.Files.desktop"
install -Dm0644 "${PROJECT_DIR}/components/file-manager/mimeapps.list" \
  "${PROFILE_DIR}/airootfs/etc/xdg/mimeapps.list"
printf '%s\n' \
  'METHOD=kaskados' \
  "VERSION=$(tr -d '\n' < "${MACQUEENDE_SOURCE}/VERSION")" \
  'SOURCE_REPOSITORY=https://github.com/ll-host/KaskadOS' \
  'SOURCE_PATH=components/macqueende' \
  "SOURCE_COMMIT=${MACQUEEN_SOURCE_COMMIT}" \
  'BUILD_PACKAGES=' \
  'MANAGED_FLAMESHOT=0' \
  > "${MACQUEEN_STAGE}/INSTALL_INFO"

install -Dm0755 "${REGALIA_BIN}/regalia" \
  "${PROFILE_DIR}/airootfs/usr/bin/regalia"
install -Dm0755 "${REGALIA_BIN}/regaliad" \
  "${PROFILE_DIR}/airootfs/usr/bin/regaliad"
install -Dm0755 "${REGALIA_BIN}/regalia-engine" \
  "${PROFILE_DIR}/airootfs/usr/lib/regalia/regalia-engine"
install -Dm0755 "${REGALIA_BIN}/sing-box" \
  "${PROFILE_DIR}/airootfs/usr/lib/regalia/sing-box"
install -Dm0644 "${REGALIA_SOURCE}/packaging/systemd/regalia-engine@.service" \
  "${PROFILE_DIR}/airootfs/usr/lib/systemd/system/regalia-engine@.service"
install -Dm0644 "${REGALIA_SOURCE}/packaging/systemd/user/regaliad.service" \
  "${PROFILE_DIR}/airootfs/usr/lib/systemd/user/regaliad.service"
install -Dm0644 "${REGALIA_SOURCE}/packaging/polkit/50-regalia-engine.rules" \
  "${PROFILE_DIR}/airootfs/usr/share/polkit-1/rules.d/50-regalia-engine.rules"
install -d -m 0755 "${PROFILE_DIR}/airootfs/etc/systemd/user/default.target.wants"
ln -sfn /usr/lib/systemd/user/regaliad.service \
  "${PROFILE_DIR}/airootfs/etc/systemd/user/default.target.wants/regaliad.service"

declare -A runtime_packages=()
declare -A system_libraries=()
readonly STAGED_ROOT="${PROFILE_DIR}/airootfs"
readonly STAGED_LIBRARY_PATH="${STAGED_ROOT}/usr/lib:${STAGED_ROOT}/opt/kaskados-installer/bin:${MACQUEEN_STAGE}/build/compositor/bin:${MACQUEEN_STAGE}/build/portal/bin:${MACQUEEN_STAGE}/build/quickshell-macqueen"
for package_name in \
  brightnessctl \
  cava \
  curl \
  ddcutil \
  flameshot \
  kwin \
  mesa \
  pacman-contrib \
  pciutils \
  polkit \
  qt6-5compat \
  qt6-connectivity \
  qt6-imageformats \
  qt6-multimedia \
  qt6-positioning \
  qt6-sensors \
  qt6-svg \
  qt6-wayland \
  quickshell \
  ttf-dejavu \
  xdg-desktop-portal-gtk \
  plasma-workspace \
  xkeyboard-config \
  xorg-xwayland; do
  runtime_packages["${package_name}"]=1
done

while IFS= read -r -d '' artifact; do
  if ! readelf -h "${artifact}" >/dev/null 2>&1; then
    continue
  fi

  ldd_output="$(env LD_LIBRARY_PATH="${STAGED_LIBRARY_PATH}" ldd "${artifact}" 2>/dev/null || true)"
  if grep -Fq 'not found' <<< "${ldd_output}"; then
    printf 'Неразрешённые библиотеки в %s:\n%s\n' "${artifact}" "${ldd_output}" >&2
    exit 1
  fi

  while IFS= read -r library; do
    [[ -e "${library}" ]] || continue
    [[ "${library}" != "${STAGED_ROOT}/"* ]] || continue
    system_libraries["${library}"]=1
  done < <(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) { sub(/\(.*/, "", $i); print $i } }' <<< "${ldd_output}")
done < <(find \
  "${PROFILE_DIR}/airootfs/usr/bin" \
  "${PROFILE_DIR}/airootfs/usr/lib" \
  "${PROFILE_DIR}/airootfs/opt/kaskados-installer/bin" \
  "${PROFILE_DIR}/airootfs/opt/macqueende" \
  -type f -print0)

if (( ${#system_libraries[@]} > 0 )); then
  package_owner_output="$(pacman -Qqo -- "${!system_libraries[@]}")" \
    || die 'не удалось определить пакеты системных библиотек'
  while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] && runtime_packages["${package_name}"]=1
  done <<< "${package_owner_output}"
fi

pacman --config "${PROFILE_DIR}/pacman.conf" -Si "${!runtime_packages[@]}" >/dev/null \
  || die 'один или несколько пакетов времени выполнения отсутствуют в репозиториях ISO'

for package_name in "${!runtime_packages[@]}"; do
  printf '%s\n' "${package_name}" >> "${PROFILE_DIR}/packages.x86_64"
done

desktop_pkgver="$(tr '-' '_' < "${MACQUEENDE_SOURCE}/VERSION" | tr -d '\n')"
(
  cd -- "${DESKTOP_PACKAGE_SOURCE}"
  env \
    KASKADOS_DESKTOP_PAYLOAD="${PROFILE_DIR}/airootfs" \
    KASKADOS_DESKTOP_PKGVER="${desktop_pkgver}" \
    BUILDDIR="${BUILD_ROOT}/repository-bootstrap/work" \
    PKGDEST="${BOOTSTRAP_REPOSITORY}" \
    SRCDEST="${BUILD_ROOT}/repository-bootstrap/sources" \
    makepkg --cleanbuild --force --nodeps
)
mapfile -t desktop_packages < <(
  find "${BOOTSTRAP_REPOSITORY}" -maxdepth 1 -type f \
    -name "kaskados-desktop-${desktop_pkgver}-*.pkg.tar.zst" -print
)
(( ${#desktop_packages[@]} == 1 )) \
  || die 'не удалось однозначно определить собранный пакет kaskados-desktop'

for executable_path in \
  opt/macqueende/build/compositor/bin/macqueen \
  opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen \
  opt/macqueende/session/prepare-user-config \
  opt/macqueende/session/run-molniya \
  opt/macqueende/shell/MolniyaMacqueenShell/core/bin/dms \
  opt/macqueende/shell/MolniyaMacqueenShell/quickshell/scripts/system-info.sh \
  opt/macqueende/shell/MolniyaMacqueenShell/quickshell/scripts/system-maintenance.sh \
  opt/macqueende/start-macqueende \
  usr/bin/regalia \
  usr/bin/regaliad \
  usr/bin/start-macqueende \
  usr/lib/regalia/regalia-engine \
  usr/lib/regalia/sing-box; do
  archive_mode="$(bsdtar -tvf "${desktop_packages[0]}" "${executable_path}" | awk 'NR == 1 { print $1 }')"
  [[ "${archive_mode}" == '-rwxr-xr-x' ]] \
    || die "в пакете kaskados-desktop неверные права ${archive_mode:-отсутствуют} для ${executable_path}"
done

repo-add "${BOOTSTRAP_REPOSITORY}/kaskados-bootstrap.db.tar.gz" \
  "${desktop_packages[0]}"

# MacqueenDE и встроенные компоненты сначала собираются в airootfs,
# который используется как payload для пакета. После сборки убираем точно
# эти файлы из профиля: в готовую систему их должен устанавливать и обновлять pacman.
while IFS= read -r package_path; do
  [[ -n "${package_path}" ]] || continue
  case "${package_path}" in
    /*|..|../*|*/../*)
      die "небезопасный путь в пакете kaskados-desktop: ${package_path}"
      ;;
  esac

  staged_path="${PROFILE_DIR}/airootfs/${package_path#./}"
  if [[ -L "${staged_path}" || -f "${staged_path}" ]]; then
    rm -f -- "${staged_path}"
  fi
done < <(bsdtar -tf "${desktop_packages[0]}")

printf '%s\n' 'kaskados-desktop' >> "${PROFILE_DIR}/packages.x86_64"

LC_ALL=C sort -u -o "${PROFILE_DIR}/packages.x86_64" "${PROFILE_DIR}/packages.x86_64"

printf 'Подготовлен live-профиль: %s\n' "${PROFILE_DIR}"
printf 'Композитор: %s\n' "${PROFILE_DIR}/airootfs/opt/kaskados-installer/bin/kaskad-installer"
printf 'Calamares:  %s\n' "${PROFILE_DIR}/airootfs/usr/bin/calamares"
printf 'Пакет DE:   %s\n' "${desktop_packages[0]}"
