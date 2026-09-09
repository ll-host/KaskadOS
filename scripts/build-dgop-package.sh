#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PACKAGE_SOURCE="${PROJECT_DIR}/repository/packages/dgop"
readonly BUILD_ROOT="${KASKADOS_DGOP_BUILD_ROOT:-${PROJECT_DIR}/build/dgop-package}"
readonly PACKAGE_DEST="${KASKADOS_PACKAGE_DEST:-${PROJECT_DIR}/out/packages/x86_64}"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

command -v makepkg >/dev/null 2>&1 || die 'не найдена команда makepkg'
(( EUID != 0 )) || die 'пакет dgop нужно собирать обычным пользователем'
[[ "$(uname -m)" == x86_64 ]] || die 'сборка поддерживается только на x86_64'
[[ -f "${PACKAGE_SOURCE}/PKGBUILD" ]] || die 'не найден PKGBUILD dgop'

install -d -m 0755 \
  "${BUILD_ROOT}/work" \
  "${BUILD_ROOT}/sources" \
  "${PACKAGE_DEST}"

(
  cd -- "${PACKAGE_SOURCE}"
  env \
    BUILDDIR="${BUILD_ROOT}/work" \
    PKGDEST="${PACKAGE_DEST}" \
    SRCDEST="${BUILD_ROOT}/sources" \
    makepkg --cleanbuild --force --nodeps
)

mapfile -t packages < <(
  find "${PACKAGE_DEST}" -maxdepth 1 -type f \
    -name 'dgop-[0-9]*-x86_64.pkg.tar.zst' -printf '%T@ %p\n' \
    | sort -nr \
    | head -n 1 \
    | cut -d ' ' -f 2-
)
(( ${#packages[@]} == 1 )) || die 'не удалось определить собранный пакет dgop'
printf 'Пакет dgop готов: %s\n' "${packages[0]}"
