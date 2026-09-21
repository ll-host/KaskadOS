#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

(( $# == 2 )) || die 'использование: manage-build-process.sh resume|stop PID'
readonly ACTION="$1"
readonly ROOT_PID="$2"
[[ "${ACTION}" == resume || "${ACTION}" == stop ]] || die 'неизвестное действие'
[[ "${ROOT_PID}" =~ ^[0-9]+$ && "${ROOT_PID}" -gt 1 ]] || die 'некорректный PID'

if (( EUID != 0 )); then
  command -v pkexec >/dev/null 2>&1 || die 'не найдена команда pkexec'
  exec pkexec "${BASH_SOURCE[0]}" "${ACTION}" "${ROOT_PID}"
fi

[[ -r "/proc/${ROOT_PID}/cmdline" ]] || die 'процесс уже завершён'
root_command="$(tr '\0' ' ' < "/proc/${ROOT_PID}/cmdline")"
[[ "${root_command}" == *"${PROJECT_DIR}/scripts/build-iso.sh"* \
   || ( "${root_command}" == *"mkarchiso"* \
        && "${root_command}" == *"${PROJECT_DIR}/build/iso-profile"* ) ]] \
  || die 'указанный процесс не является сборкой ISO этого проекта'

declare -a process_tree=("${ROOT_PID}")
while true; do
  added=0
  while read -r child_pid parent_pid; do
    for known_pid in "${process_tree[@]}"; do
      if [[ "${parent_pid}" == "${known_pid}" ]]; then
        already_known=0
        for existing_pid in "${process_tree[@]}"; do
          [[ "${existing_pid}" == "${child_pid}" ]] && already_known=1 && break
        done
        if (( ! already_known )); then
          process_tree+=("${child_pid}")
          added=1
        fi
        break
      fi
    done
  done < <(ps -eo pid=,ppid=)
  (( added )) || break
done

case "${ACTION}" in
  resume)
    kill -CONT "${process_tree[@]}" 2>/dev/null || true
    printf 'Сборка продолжена.\n'
    ;;
  stop)
    kill -CONT "${process_tree[@]}" 2>/dev/null || true
    kill -INT "${process_tree[@]}" 2>/dev/null || true
    for _ in {1..30}; do
      [[ ! -e "/proc/${ROOT_PID}" ]] && break
      sleep 0.1
    done
    if [[ -e "/proc/${ROOT_PID}" ]]; then
      kill -TERM "${process_tree[@]}" 2>/dev/null || true
    fi
    printf 'Сборка завершена. Загруженный кэш сохранён.\n'
    ;;
esac
