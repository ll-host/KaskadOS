#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly VERSION_FILE="${PROJECT_DIR}/components/macqueende/VERSION"
readonly SOURCEFORGE_USER="${KASKADOS_SOURCEFORGE_USER:-lyrka-meow}"
readonly SOURCEFORGE_PROJECT="${KASKADOS_SOURCEFORGE_PROJECT:-kaskados-main}"
readonly SOURCEFORGE_HOST="frs.sourceforge.net"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "использование: $0 /путь/к/образу.iso"

readonly ISO_PATH="$(readlink -f -- "$1")"
[[ -f "${ISO_PATH}" ]] || die "ISO не найден: ${ISO_PATH}"
[[ "${ISO_PATH}" == *.iso ]] || die "выбранный файл не является ISO: ${ISO_PATH}"
[[ -f "${VERSION_FILE}" ]] || die "не найден файл версии: ${VERSION_FILE}"

for command_name in rsync sha256sum ssh; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || die "не найдена команда ${command_name}"
done

readonly VERSION="$(tr -d '\n' < "${VERSION_FILE}")"
readonly ISO_DIRECTORY="$(dirname -- "${ISO_PATH}")"
readonly ISO_FILENAME="$(basename -- "${ISO_PATH}")"
readonly CHECKSUM_FILENAME="${ISO_FILENAME}.sha256"
readonly CHECKSUM_PATH="${ISO_DIRECTORY}/${CHECKSUM_FILENAME}"

[[ "${VERSION}" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "версия содержит недопустимые символы: ${VERSION}"
[[ "${ISO_FILENAME}" =~ ^[A-Za-z0-9._+-]+$ ]] \
  || die "имя ISO содержит недопустимые символы: ${ISO_FILENAME}"

printf 'Создаю контрольную сумму SHA256...\n'
(
  cd -- "${ISO_DIRECTORY}"
  sha256sum -- "${ISO_FILENAME}" > "${CHECKSUM_FILENAME}"
)

readonly REMOTE_DIRECTORY="${SOURCEFORGE_USER}@${SOURCEFORGE_HOST}:/home/frs/project/${SOURCEFORGE_PROJECT}/${VERSION}/"

printf 'Загружаю ISO и SHA256 в SourceForge...\n'
printf 'Назначение: %s\n\n' "${REMOTE_DIRECTORY}"
rsync --archive --verbose --partial --progress \
  -e ssh \
  -- "${ISO_PATH}" "${CHECKSUM_PATH}" "${REMOTE_DIRECTORY}"

readonly PUBLIC_BASE="https://sourceforge.net/projects/${SOURCEFORGE_PROJECT}/files/${VERSION}"

printf '\nПубликация завершена.\n'
printf 'ISO:    %s/%s/download\n' "${PUBLIC_BASE}" "${ISO_FILENAME}"
printf 'SHA256: %s/%s/download\n' "${PUBLIC_BASE}" "${CHECKSUM_FILENAME}"
