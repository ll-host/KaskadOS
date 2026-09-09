#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly WORK_DIR="${WORK_DIR:-${PROJECT_DIR}/work}"
readonly RESOLVED_WORK_DIR="$(realpath -m -- "${WORK_DIR}")"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

[[ "${RESOLVED_WORK_DIR}" != '/' ]] || die 'корневой каталог нельзя использовать как WORK_DIR'
[[ "${RESOLVED_WORK_DIR}" != "${PROJECT_DIR}" ]] || die 'каталог проекта нельзя использовать как WORK_DIR'

if [[ ! -e "${RESOLVED_WORK_DIR}" ]]; then
  printf 'Рабочего каталога нет: %s\n' "${RESOLVED_WORK_DIR}"
  exit 0
fi

[[ -d "${RESOLVED_WORK_DIR}" ]] || die "путь рабочего каталога не является каталогом: ${RESOLVED_WORK_DIR}"

if mounts="$(findmnt --submounts --noheadings --output TARGET "${RESOLVED_WORK_DIR}" 2>/dev/null)"; then
  printf 'Внутри рабочего каталога остались монтирования:\n%s\n' "${mounts}" >&2
  die 'сначала размонтируйте их; каталог не удалён'
fi

if (( EUID == 0 )); then
  rm -rf -- "${RESOLVED_WORK_DIR}"
else
  command -v sudo >/dev/null 2>&1 || die 'не найдена команда sudo'
  sudo -v
  sudo rm -rf -- "${RESOLVED_WORK_DIR}"
fi
printf 'Удалён рабочий каталог: %s\n' "${RESOLVED_WORK_DIR}"
