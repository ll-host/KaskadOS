#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_DIR="${KASKADOS_REPOSITORY_DIR:-${PROJECT_DIR}/out/repository/x86_64}"
readonly REPOSITORY_DB="${REPOSITORY_DIR}/kaskados.db.tar.gz"
readonly REPOSITORY_TARGET="${KASKADOS_REPOSITORY_TARGET:-kaskados-repo@2.26.103.171:/srv/kaskados-repo/x86_64/}"
readonly SSH_KEY="${KASKADOS_REPOSITORY_SSH_KEY:-${HOME}/.ssh/kaskados-repository}"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

(( $# > 0 )) || die 'передайте хотя бы один пакет *.pkg.tar.zst'
[[ -n "${KASKADOS_SIGNING_KEY:-}" ]] \
  || die 'задайте KASKADOS_SIGNING_KEY с идентификатором ключа подписи'

for command_name in gpg repo-add rsync ssh; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || die "не найдена команда ${command_name}"
done

[[ -f "${SSH_KEY}" ]] || die "не найден SSH-ключ ${SSH_KEY}"
mkdir -p -- "${REPOSITORY_DIR}"

declare -a packages=()
for source_package in "$@"; do
  [[ -f "${source_package}" ]] || die "не найден пакет ${source_package}"
  [[ "${source_package}" == *.pkg.tar.zst ]] \
    || die "неподдерживаемый формат пакета: ${source_package}"

  package_name="$(basename -- "${source_package}")"
  destination_package="${REPOSITORY_DIR}/${package_name}"
  install -m 0644 -- "${source_package}" "${destination_package}"

  gpg --batch --yes --local-user "${KASKADOS_SIGNING_KEY}" \
    --detach-sign --output "${destination_package}.sig" "${destination_package}"
  packages+=("${destination_package}")
done

repo-add \
  --remove \
  --prevent-downgrade \
  --include-sigs \
  --sign \
  --key "${KASKADOS_SIGNING_KEY}" \
  --wait-for-lock \
  "${REPOSITORY_DB}" \
  "${packages[@]}"

rsync \
  --archive \
  --delete-delay \
  --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
  --rsh="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes" \
  "${REPOSITORY_DIR}/" \
  "${REPOSITORY_TARGET}"

printf 'Репозиторий опубликован: https://repo.kaskados.xyz/x86_64/\n'
