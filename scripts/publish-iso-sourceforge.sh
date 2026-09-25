#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly VERSION_FILE="${PROJECT_DIR}/components/macqueende/VERSION"
readonly SOURCEFORGE_USER="${KASKADOS_SOURCEFORGE_USER:-lyrka-meow}"
readonly SOURCEFORGE_PROJECT="${KASKADOS_SOURCEFORGE_PROJECT:-kaskados-main}"
readonly SOURCEFORGE_HOST="frs.sourceforge.net"
readonly SOURCEFORGE_ED25519_FINGERPRINT="SHA256:209BDmH3jsRyO9UeGPPgLWPSegKmYCBIya0nR/AWWCY"
readonly SSH_STATE_DIRECTORY="${XDG_STATE_HOME:-${HOME}/.local/state}/kaskados/ssh"
readonly SOURCEFORGE_KNOWN_HOSTS="${SSH_STATE_DIRECTORY}/sourceforge-known-hosts"
readonly SSH_ASKPASS_HELPER="${SCRIPT_DIR}/sourceforge-ssh-askpass.sh"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "использование: $0 /путь/к/образу.iso"

readonly ISO_PATH="$(readlink -f -- "$1")"
[[ -f "${ISO_PATH}" ]] || die "ISO не найден: ${ISO_PATH}"
[[ "${ISO_PATH}" == *.iso ]] || die "выбранный файл не является ISO: ${ISO_PATH}"
[[ -f "${VERSION_FILE}" ]] || die "не найден файл версии: ${VERSION_FILE}"
[[ -x "${SSH_ASKPASS_HELPER}" ]] \
  || die "не найден помощник авторизации SourceForge: ${SSH_ASKPASS_HELPER}"

for command_name in awk install mktemp rm rsync sha256sum ssh ssh-keygen ssh-keyscan; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || die "не найдена команда ${command_name}"
done

prepare_sourceforge_host_key() {
  local scanned_keys
  local actual_fingerprint

  install -d -m 700 -- "${SSH_STATE_DIRECTORY}"
  scanned_keys="$(mktemp --tmpdir="${SSH_STATE_DIRECTORY}" sourceforge-known-hosts.XXXXXX)"

  printf 'Проверяю подлинность сервера SourceForge...\n'
  if ! ssh-keyscan -T 15 -t ed25519 -- "${SOURCEFORGE_HOST}" \
    > "${scanned_keys}" 2>/dev/null; then
    rm -f -- "${scanned_keys}"
    die "не удалось получить ключ сервера ${SOURCEFORGE_HOST}"
  fi

  actual_fingerprint="$(ssh-keygen -E sha256 -lf "${scanned_keys}" 2>/dev/null \
    | awk 'NR == 1 { print $2 }')"

  if [[ -z "${actual_fingerprint}" ]]; then
    rm -f -- "${scanned_keys}"
    die "сервер ${SOURCEFORGE_HOST} не предоставил корректный SSH-ключ"
  fi
  if [[ "${actual_fingerprint}" != "${SOURCEFORGE_ED25519_FINGERPRINT}" ]]; then
    rm -f -- "${scanned_keys}"
    die "отпечаток SSH-ключа SourceForge не совпал с официальным (получен ${actual_fingerprint})"
  fi

  install -m 600 -- "${scanned_keys}" "${SOURCEFORGE_KNOWN_HOSTS}"
  rm -f -- "${scanned_keys}"
}

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

prepare_sourceforge_host_key

if [[ ! -t 0 ]]; then
  export SSH_ASKPASS="${SSH_ASKPASS_HELPER}"
  export SSH_ASKPASS_REQUIRE=force
fi

printf -v RSYNC_SSH_COMMAND \
  'ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%q' \
  "${SOURCEFORGE_KNOWN_HOSTS}"
readonly RSYNC_SSH_COMMAND

printf 'Загружаю ISO и SHA256 в SourceForge...\n'
printf 'Назначение: %s\n\n' "${REMOTE_DIRECTORY}"
rsync --archive --verbose --partial --progress \
  -e "${RSYNC_SSH_COMMAND}" \
  -- "${ISO_PATH}" "${CHECKSUM_PATH}" "${REMOTE_DIRECTORY}"

readonly PUBLIC_BASE="https://sourceforge.net/projects/${SOURCEFORGE_PROJECT}/files/${VERSION}"

printf '\nПубликация завершена.\n'
printf 'ISO:    %s/%s/download\n' "${PUBLIC_BASE}" "${ISO_FILENAME}"
printf 'SHA256: %s/%s/download\n' "${PUBLIC_BASE}" "${CHECKSUM_FILENAME}"
