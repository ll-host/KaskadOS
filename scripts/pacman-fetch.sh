#!/usr/bin/env bash
set -u

output=${1:?usage: pacman-fetch.sh OUTPUT URL}
url=${2:?usage: pacman-fetch.sh OUTPUT URL}
file_name=${url##*/}
is_package=0
[[ "${file_name}" == *.pkg.tar.* && "${file_name}" != *.sig ]] && is_package=1

emit_package_event() {
  (( is_package )) || return 0
  printf '@@KASKADOS@@\tpackage\t%s\t%s\t%s\n' \
    "${file_name}" "$1" "${2:-0}"
}

for attempt in {1..12}; do
  emit_package_event downloading "${attempt}"
  curl \
    --http1.1 \
    --location \
    --continue-at - \
    --fail \
    --silent \
    --show-error \
    --connect-timeout 30 \
    --output "${output}" \
    "${url}" && {
      emit_package_event downloaded "${attempt}"
      exit 0
    }
  status=$?

  # Missing optional signatures and an out-of-sync mirror must be handed back
  # to pacman immediately; retry only actual connection/TLS interruptions.
  case ${status} in
    22|37)
      emit_package_event failed "${attempt}"
      exit "${status}"
      ;;
  esac

  if (( attempt == 12 )); then
    emit_package_event failed "${attempt}"
    exit "${status}"
  fi
  emit_package_event retrying "${attempt}"
  printf 'Сетевая ошибка загрузки, повтор %d/12 через 5 секунд...\n' "$((attempt + 1))" >&2
  sleep 5
done
