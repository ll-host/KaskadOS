#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PROFILE_DIR="${PROFILE_DIR:-${PROJECT_DIR}/build/iso-profile}"
readonly WORK_DIR="${WORK_DIR:-${PROJECT_DIR}/work}"
readonly OUT_DIR="${OUT_DIR:-${PROJECT_DIR}/out}"
readonly PRIVILEGE_HELPER="${KASKADOS_PRIVILEGE_HELPER:-sudo}"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

build_event() {
  printf '@@KASKADOS@@\tphase\t%s\t%s\n' "$1" "$2"
}

sudo_keepalive_pid=''

stop_sudo_keepalive() {
  if [[ -n "${sudo_keepalive_pid}" ]]; then
    kill "${sudo_keepalive_pid}" 2>/dev/null || true
    wait "${sudo_keepalive_pid}" 2>/dev/null || true
  fi
}

trap stop_sudo_keepalive EXIT

build_event checks running
if (( EUID != 0 )); then
  case "${PRIVILEGE_HELPER}" in
    pkexec)
      command -v pkexec >/dev/null 2>&1 || die 'не найдена команда pkexec'
      printf 'Для создания ISO появится системный запрос прав администратора.\n'
      ;;
    sudo)
      command -v sudo >/dev/null 2>&1 || die 'не найдена команда sudo'
      printf 'Для сборки ISO нужны права администратора.\n'
      sudo -k
      sudo -v
      (
        while sleep 60; do
          sudo -n -v || exit
        done
      ) &
      sudo_keepalive_pid=$!
      ;;
    *)
      die "неподдерживаемый помощник прав: ${PRIVILEGE_HELPER}"
      ;;
  esac
fi

[[ "$(uname -m)" == 'x86_64' ]] || die 'сборка этого профиля поддерживается только на x86_64'
command -v mkarchiso >/dev/null 2>&1 || die 'mkarchiso не найден; установите пакет archiso'
build_event checks done

if [[ -e "${WORK_DIR}" ]]; then
  build_event cleanup running
  "${SCRIPT_DIR}/clean-work.sh"
  build_event cleanup done
fi

build_event profile running
"${SCRIPT_DIR}/prepare-live-profile.sh"
[[ -f "${PROFILE_DIR}/profiledef.sh" ]] || die "не подготовлен профиль: ${PROFILE_DIR}"
build_event profile done

mkdir -p -- "${OUT_DIR}"

printf 'Профиль:          %s\n' "${PROFILE_DIR}"
printf 'Рабочий каталог: %s\n' "${WORK_DIR}"
printf 'Готовый ISO:     %s\n' "${OUT_DIR}"
build_event packages running

if (( EUID == 0 )); then
  mkarchiso -v -r -w "${WORK_DIR}" -o "${OUT_DIR}" "${PROFILE_DIR}"
elif [[ "${PRIVILEGE_HELPER}" == pkexec ]]; then
  pkexec /usr/bin/mkarchiso -v -r \
    -w "${WORK_DIR}" -o "${OUT_DIR}" "${PROFILE_DIR}"
else
  sudo -n mkarchiso -v -r -w "${WORK_DIR}" -o "${OUT_DIR}" "${PROFILE_DIR}"
fi
build_event complete done
