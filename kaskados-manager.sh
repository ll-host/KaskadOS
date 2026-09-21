#!/usr/bin/env bash

set -uo pipefail

readonly SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly PROJECT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
readonly ISO_BUILD_SCRIPT="${PROJECT_DIR}/scripts/build-iso.sh"
readonly DESKTOP_BUILD_SCRIPT="${PROJECT_DIR}/scripts/build-desktop-package.sh"
readonly DGOP_BUILD_SCRIPT="${PROJECT_DIR}/scripts/build-dgop-package.sh"
readonly PUBLISH_SCRIPT="${PROJECT_DIR}/scripts/publish-repository.sh"
readonly SOURCEFORGE_PUBLISH_SCRIPT="${PROJECT_DIR}/scripts/publish-iso-sourceforge.sh"
readonly VERSION_FILE="${PROJECT_DIR}/components/macqueende/VERSION"
readonly ISO_PROFILE_FILE="${PROJECT_DIR}/profile/profiledef.sh"
readonly RELEASE_MANIFEST="${PROJECT_DIR}/components/macqueende/release/release.json"
readonly RELEASES_DIR="${PROJECT_DIR}/components/macqueende/release/releases"
readonly PACKAGE_DIR="${PROJECT_DIR}/out/packages/x86_64"
readonly OUTPUT_DIR="${PROJECT_DIR}/out"
readonly LOG_DIR="${KASKADOS_LOG_DIR:-${HOME}/kaskados-logs}"
LAST_LOG_FILE=''
LAST_RUN_STARTED_AT=0

if [[ -t 1 ]]; then
  readonly RESET=$'\033[0m'
  readonly BOLD=$'\033[1m'
  readonly GREEN=$'\033[32m'
  readonly YELLOW=$'\033[33m'
  readonly RED=$'\033[31m'
  readonly CYAN=$'\033[36m'
else
  readonly RESET=''
  readonly BOLD=''
  readonly GREEN=''
  readonly YELLOW=''
  readonly RED=''
  readonly CYAN=''
fi

die() {
  printf '%sОшибка:%s %s\n' "${RED}" "${RESET}" "$*" >&2
  exit 1
}

current_version() {
  [[ -f "${VERSION_FILE}" ]] || return 1
  tr -d '\n' < "${VERSION_FILE}"
}

current_iso_version() {
  [[ -f "${ISO_PROFILE_FILE}" ]] || return 1
  sed -n 's/^iso_version="\([^"]*\)"$/\1/p' "${ISO_PROFILE_FILE}"
}

package_version() {
  current_version | tr '-' '_'
}

newest_file() {
  local directory="$1"
  local pattern="$2"

  [[ -d "${directory}" ]] || return 1
  find "${directory}" -maxdepth 1 -type f -name "${pattern}" \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d ' ' -f 2-
}

latest_desktop_package() {
  local version
  version="$(package_version)" || return 1
  newest_file "${PACKAGE_DIR}" "kaskados-desktop-${version}-*-x86_64.pkg.tar.zst"
}

latest_dgop_package() {
  newest_file "${PACKAGE_DIR}" 'dgop-[0-9]*-x86_64.pkg.tar.zst'
}

latest_iso() {
  newest_file "${OUTPUT_DIR}" '*.iso'
}

newer_project_file() {
  local iso="$1"
  local relative_path absolute_path

  while IFS= read -r -d '' relative_path; do
    absolute_path="${PROJECT_DIR}/${relative_path}"
    if [[ -f "${absolute_path}" && "${absolute_path}" -nt "${iso}" ]]; then
      printf '%s\n' "${absolute_path}"
      return 0
    fi
  done < <(
    git -C "${PROJECT_DIR}" ls-files -z --cached --others --exclude-standard -- \
      components profile repository \
      scripts/build-iso.sh \
      scripts/build-dgop-package.sh \
      scripts/check-profile.sh \
      scripts/clean-work.sh \
      scripts/pacman-fetch.sh \
      scripts/prepare-live-profile.sh \
      Makefile 2>/dev/null
  )

  return 1
}

human_file() {
  local path="$1"

  if [[ -n "${path}" && -f "${path}" ]]; then
    printf '%s (%s)' "${path}" "$(du -h -- "${path}" | cut -f 1)"
  else
    printf 'не найден'
  fi
}

pause_menu() {
  printf '\n'
  read -r -p 'Нажмите Enter, чтобы вернуться в меню...' _ || true
}

confirm() {
  local prompt="$1"
  local answer

  if [[ "${KASKADOS_ASSUME_YES:-0}" == 1 ]]; then
    printf '%s [подтверждено в интерфейсе]\n' "${prompt}"
    return 0
  fi

  read -r -p "${prompt} [д/Н]: " answer || return 1
  case "${answer}" in
    д|Д|y|Y|yes|YES|да|Да|ДА)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

print_result() {
  local result="$1"
  local success_text="$2"
  local failure_text="$3"

  printf '\n'
  if (( result == 0 )); then
    printf '%s%s%s\n' "${GREEN}" "${success_text}" "${RESET}"
  else
    printf '%s%s Код ошибки: %d.%s\n' "${RED}" "${failure_text}" "${result}" "${RESET}"
  fi
}

run_logged() {
  local title="$1"
  local log_name="$2"
  local timestamp log_file latest_link result
  shift 2

  timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"
  LAST_RUN_STARTED_AT="$(date +%s)"
  log_file="${LOG_DIR}/${log_name}-${timestamp}-$$.log"
  latest_link="${LOG_DIR}/${log_name}-latest.log"
  install -d -m 0755 "${LOG_DIR}" || return $?
  LAST_LOG_FILE="${log_file}"

  printf '\n%s%s%s\n' "${BOLD}" "${title}" "${RESET}"
  printf 'Журнал: %s\n\n' "${log_file}"

  (
    cd -- "${PROJECT_DIR}" || exit 1
    set -o pipefail
    "$@" 2>&1 | tee "${log_file}"
  )
  result=$?
  ln -sfn -- "$(basename -- "${log_file}")" "${latest_link}" \
    || printf '%sНе удалось обновить ссылку %s.%s\n' \
      "${YELLOW}" "${latest_link}" "${RESET}" >&2
  return "${result}"
}

valid_iso_from_last_run() {
  local iso="$1"
  local modified_at size

  [[ -n "${iso}" && -f "${iso}" ]] || return 1
  command -v xorriso >/dev/null 2>&1 || return 1
  modified_at="$(stat -c '%Y' -- "${iso}")" || return 1
  size="$(stat -c '%s' -- "${iso}")" || return 1
  (( modified_at >= LAST_RUN_STARTED_AT )) || return 1
  (( size >= 1024 * 1024 * 1024 )) || return 1
  xorriso -indev "${iso}" \
    -ls /arch/x86_64/airootfs.sfs \
    -ls /arch/boot/x86_64/vmlinuz-linux \
    -ls /boot/syslinux/isolinux.bin \
    >/dev/null 2>&1
}

build_iso() {
  run_logged 'Сборка ISO KaskadOS' 'iso-build' "${ISO_BUILD_SCRIPT}"
  local result=$?
  local iso

  iso="$(latest_iso || true)"
  if (( result != 0 )) && valid_iso_from_last_run "${iso}"; then
    printf '\n%sКоманда журналирования завершилась с кодом %d, но новый ISO полностью создан и проверен.%s\n' \
      "${YELLOW}" "${result}" "${RESET}"
    result=0
  fi

  print_result "${result}" \
    "Сборка ISO завершена. Файл: $(human_file "${iso}")" \
    "Сборка ISO остановилась. Журнал: ${LAST_LOG_FILE}."
  return "${result}"
}

build_desktop() {
  run_logged 'Сборка пакета обновления MacqueenDE' \
    'desktop-build' "${DESKTOP_BUILD_SCRIPT}"
  local result=$?

  print_result "${result}" \
    "Пакеты DE готовы: $(human_file "$(latest_desktop_package || true)"); dgop: $(human_file "$(latest_dgop_package || true)")" \
    "Сборка пакета DE остановилась. Журнал: ${LAST_LOG_FILE}."
  return "${result}"
}

signing_key() {
  if [[ -n "${KASKADOS_SIGNING_KEY:-}" ]]; then
    printf '%s\n' "${KASKADOS_SIGNING_KEY}"
    return 0
  fi

  command -v gpg >/dev/null 2>&1 || return 1
  gpg --batch --with-colons --list-secret-keys 'KaskadOS Package Signing' 2>/dev/null \
    | awk -F: '$1 == "sec" { print $5; exit }'
}

publish_desktop() {
  local package dgop_package key result
  package="$(latest_desktop_package || true)"
  dgop_package="$(latest_dgop_package || true)"

  if [[ -z "${package}" || ! -f "${package}" ]]; then
    printf '%sНе найден пакет текущей версии %s.%s\n' \
      "${RED}" "$(current_version)" "${RESET}" >&2
    printf 'Сначала выберите пункт «Собрать пакет обновления DE».\n'
    return 2
  fi

  if [[ -z "${dgop_package}" || ! -f "${dgop_package}" ]]; then
    printf '%sНе найден собранный пакет dgop.%s\n' \
      "${RED}" "${RESET}" >&2
    printf 'Сначала выберите пункт «Собрать пакет обновления DE».\n'
    return 2
  fi

  key="$(signing_key || true)"
  if [[ -z "${key}" ]]; then
    printf '%sНе найден секретный ключ «KaskadOS Package Signing».%s\n' \
      "${RED}" "${RESET}" >&2
    return 2
  fi

  printf '\nБудут опубликованы пакеты:\n'
  printf '  %s\n' "$(human_file "${dgop_package}")"
  printf '  %s\n' "$(human_file "${package}")"
  printf 'Адрес репозитория:\n  https://repo.kaskados.xyz/x86_64/\n\n'
  confirm 'Опубликовать обновление для пользователей?' || {
    printf 'Публикация отменена.\n'
    return 130
  }

  run_logged 'Публикация обновления MacqueenDE' 'repository-publish' \
    env KASKADOS_SIGNING_KEY="${key}" "${PUBLISH_SCRIPT}" \
      "${dgop_package}" "${package}"
  result=$?

  print_result "${result}" \
    'Обновление DE опубликовано.' \
    "Публикация остановилась. Журнал: ${LAST_LOG_FILE}."
  return "${result}"
}

build_and_publish_desktop() {
  printf '\nПосле успешной сборки пакет будет предложено опубликовать.\n'
  confirm 'Продолжить?' || {
    printf 'Операция отменена.\n'
    return 130
  }

  build_desktop || return $?
  publish_desktop
}

publish_iso_sourceforge() {
  local iso newer_file result
  iso="$(latest_iso || true)"

  if [[ -z "${iso}" || ! -f "${iso}" ]]; then
    printf '%sГотовый ISO не найден.%s\n' "${RED}" "${RESET}" >&2
    printf 'Сначала выберите пункт «Собрать ISO».\n'
    return 2
  fi

  newer_file="$(newer_project_file "${iso}" || true)"
  if [[ -n "${newer_file}" ]]; then
    printf '%sISO собран раньше, чем были изменены файлы системы.%s\n' \
      "${RED}" "${RESET}" >&2
    printf 'Первый более новый файл: %s\n' "${newer_file}"
    printf 'Сначала выберите пункт «Собрать ISO».\n'
    return 2
  fi

  printf '\nБудет опубликован ISO:\n  %s\n' "$(human_file "${iso}")"
  printf 'Версия выпуска: %s\n' "$(current_version)"
  printf 'Проект SourceForge:\n  https://sourceforge.net/projects/kaskados-main/files/\n\n'
  confirm 'Создать SHA256 и загрузить файлы в SourceForge?' || {
    printf 'Публикация отменена.\n'
    return 130
  }

  run_logged 'Публикация ISO в SourceForge' 'sourceforge-publish' \
    "${SOURCEFORGE_PUBLISH_SCRIPT}" "${iso}"
  result=$?

  print_result "${result}" \
    'ISO и SHA256 опубликованы в SourceForge.' \
    "Публикация остановилась. Журнал: ${LAST_LOG_FILE}."
  return "${result}"
}

bump_version() {
  local version iso_version prefix sequence next_version release_date temp_dir

  version="$(current_version || true)"
  iso_version="$(current_iso_version || true)"
  if [[ ! "${version}" =~ ^(.+-alpha\.)([0-9]+)$ ]]; then
    printf '%sНе удалось определить номер alpha-версии: %s%s\n' \
      "${RED}" "${version:-не задана}" "${RESET}" >&2
    return 2
  fi
  if [[ "${iso_version}" != "${version}" ]]; then
    printf '%sВерсии DE и ISO уже расходятся: DE %s, ISO %s.%s\n' \
      "${RED}" "${version}" "${iso_version:-не задана}" "${RESET}" >&2
    return 2
  fi
  if ! grep -Fq '"version": "'"${version}"'"' "${RELEASE_MANIFEST}" \
      || ! grep -Fq '"releaseNotes": "releases/'"${version}"'.json"' "${RELEASE_MANIFEST}"; then
    printf '%sМанифест выпуска не соответствует текущей версии %s.%s\n' \
      "${RED}" "${version}" "${RESET}" >&2
    return 2
  fi

  prefix="${BASH_REMATCH[1]}"
  sequence="${BASH_REMATCH[2]}"
  next_version="${prefix}$((10#${sequence} + 1))"
  release_date="$(date +%F)"

  if [[ -e "${RELEASES_DIR}/${next_version}.json" ]]; then
    printf '%sФайл выпуска %s уже существует.%s\n' \
      "${RED}" "${RELEASES_DIR}/${next_version}.json" "${RESET}" >&2
    return 2
  fi

  temp_dir="$(mktemp -d)" || return 1
  cp -a -- "${VERSION_FILE}" "${temp_dir}/VERSION.old" \
    && cp -a -- "${ISO_PROFILE_FILE}" "${temp_dir}/profiledef.sh.old" \
    && cp -a -- "${RELEASE_MANIFEST}" "${temp_dir}/release.json.old" || {
      rm -rf -- "${temp_dir}"
      return 1
    }
  sed "s/^iso_version=\"${version}\"$/iso_version=\"${next_version}\"/" \
    "${ISO_PROFILE_FILE}" > "${temp_dir}/profiledef.sh" || {
      rm -rf -- "${temp_dir}"
      return 1
    }
  sed \
    -e 's|"version": "'"${version}"'"|"version": "'"${next_version}"'"|' \
    -e 's|"releaseDate": "[^"]*"|"releaseDate": "'"${release_date}"'"|' \
    -e 's|"releaseNotes": "releases/'"${version}"'\.json"|"releaseNotes": "releases/'"${next_version}"'.json"|' \
    "${RELEASE_MANIFEST}" > "${temp_dir}/release.json" || {
      rm -rf -- "${temp_dir}"
      return 1
    }
  printf '%s\n' "${next_version}" > "${temp_dir}/VERSION"
  printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "version": "'"${next_version}"'",' \
    '  "title": "Обновление KaskadOS",' \
    '  "summary": "Обновление рабочей среды и системных компонентов KaskadOS.",' \
    '  "features": [],' \
    '  "notes": [' \
    '    "Подробности изменений доступны в истории проекта.",' \
    '    "Для применения обновления требуется выйти из сеанса и войти снова."' \
    '  ]' \
    '}' > "${temp_dir}/release-notes.json"

  if [[ "$(sed -n 's/^iso_version="\([^"]*\)"$/\1/p' "${temp_dir}/profiledef.sh")" != "${next_version}" ]] \
      || ! grep -Fq '"version": "'"${next_version}"'"' "${temp_dir}/release.json" \
      || ! grep -Fq '"releaseNotes": "releases/'"${next_version}"'.json"' "${temp_dir}/release.json"; then
    rm -rf -- "${temp_dir}"
    printf '%sНе удалось подготовить согласованные файлы версии.%s\n' \
      "${RED}" "${RESET}" >&2
    return 1
  fi

  install -m 0644 "${temp_dir}/VERSION" "${VERSION_FILE}" \
    && install -m 0644 "${temp_dir}/profiledef.sh" "${ISO_PROFILE_FILE}" \
    && install -m 0644 "${temp_dir}/release.json" "${RELEASE_MANIFEST}" \
    && install -m 0644 "${temp_dir}/release-notes.json" "${RELEASES_DIR}/${next_version}.json"
  local result=$?
  if (( result != 0 )); then
    install -m 0644 "${temp_dir}/VERSION.old" "${VERSION_FILE}"
    install -m 0644 "${temp_dir}/profiledef.sh.old" "${ISO_PROFILE_FILE}"
    install -m 0644 "${temp_dir}/release.json.old" "${RELEASE_MANIFEST}"
    rm -f -- "${RELEASES_DIR}/${next_version}.json"
    rm -rf -- "${temp_dir}"
    printf '%sНе удалось записать новую версию полностью.%s\n' "${RED}" "${RESET}" >&2
    return "${result}"
  fi
  rm -rf -- "${temp_dir}"

  printf '\n%sВерсия DE и ISO повышена: %s → %s%s\n' \
    "${GREEN}" "${version}" "${next_version}" "${RESET}"
}

commit_and_push_all() {
  local branch remote_url commit_message

  command -v git >/dev/null 2>&1 || {
    printf '%sНе найдена команда git.%s\n' "${RED}" "${RESET}" >&2
    return 2
  }
  git -C "${PROJECT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf '%sКаталог проекта не является Git-репозиторием.%s\n' "${RED}" "${RESET}" >&2
    return 2
  }
  branch="$(git -C "${PROJECT_DIR}" branch --show-current)"
  if [[ -z "${branch}" ]]; then
    printf '%sНельзя отправить изменения из detached HEAD.%s\n' "${RED}" "${RESET}" >&2
    return 2
  fi
  remote_url="$(git -C "${PROJECT_DIR}" remote get-url origin 2>/dev/null || true)"
  if [[ -z "${remote_url}" ]]; then
    printf '%sНе найден Git-remote origin.%s\n' "${RED}" "${RESET}" >&2
    return 2
  fi
  case "${remote_url}" in
    https://github.com/*|git@github.com:*|ssh://git@github.com/*)
      ;;
    *)
      printf '%sRemote origin не ведёт на GitHub: %s%s\n' \
        "${RED}" "${remote_url}" "${RESET}" >&2
      return 2
      ;;
  esac
  if [[ -z "$(git -C "${PROJECT_DIR}" status --porcelain=v1)" ]]; then
    printf '\n%sНет изменений для коммита.%s\n' "${YELLOW}" "${RESET}"
    return 0
  fi

  printf '\nБудут добавлены все изменения проекта:\n\n'
  git -C "${PROJECT_DIR}" status --short
  printf '\nВетка:  %s\n' "${branch}"
  printf 'Remote: %s\n\n' "${remote_url}"
  if [[ -n "${KASKADOS_COMMIT_MESSAGE:-}" ]]; then
    commit_message="${KASKADOS_COMMIT_MESSAGE}"
    printf 'Название коммита: %s\n' "${commit_message}"
  else
    read -r -p 'Введите название коммита: ' commit_message || return 130
  fi
  if [[ -z "${commit_message//[[:space:]]/}" ]]; then
    printf 'Коммит отменён: название не может быть пустым.\n'
    return 130
  fi

  git -C "${PROJECT_DIR}" add --all -- . || return $?
  git -C "${PROJECT_DIR}" commit -m "${commit_message}" || return $?
  git -C "${PROJECT_DIR}" push origin "${branch}" || return $?

  printf '\n%sВсе изменения закоммичены и отправлены в origin/%s.%s\n' \
    "${GREEN}" "${branch}" "${RESET}"
}

show_status() {
  local version iso_version package dgop_package iso branch commit changes

  version="$(current_version || printf 'неизвестна')"
  iso_version="$(current_iso_version || printf 'неизвестна')"
  package="$(latest_desktop_package || true)"
  dgop_package="$(latest_dgop_package || true)"
  iso="$(latest_iso || true)"
  branch="$(git -C "${PROJECT_DIR}" branch --show-current 2>/dev/null || true)"
  commit="$(git -C "${PROJECT_DIR}" log -1 --pretty='%h %s' 2>/dev/null || true)"
  changes="$(git -C "${PROJECT_DIR}" status --porcelain=v1 2>/dev/null | wc -l)"

  printf '\n%sСостояние KaskadOS%s\n\n' "${BOLD}" "${RESET}"
  printf 'Версия DE:       %s\n' "${version}"
  printf 'Версия ISO:      %s\n' "${iso_version}"
  printf 'Ветка Git:       %s\n' "${branch:-неизвестна}"
  printf 'Последний коммит: %s\n' "${commit:-неизвестен}"
  printf 'Локальных правок: %s\n' "${changes}"
  printf 'Пакет DE:        %s\n' "$(human_file "${package}")"
  printf 'Пакет dgop:      %s\n' "$(human_file "${dgop_package}")"
  printf 'Последний ISO:   %s\n' "$(human_file "${iso}")"
  printf 'Репозиторий:     https://repo.kaskados.xyz/x86_64/\n'
  printf 'ISO SourceForge: https://sourceforge.net/projects/kaskados-main/files/\n'
  printf 'Журналы операций: %s\n' "${LOG_DIR}"
  printf 'Журнал установки: /var/log/Calamares.log\n'
}

human_bytes() {
  local bytes="$1"

  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "${bytes}"
  else
    printf '%s B' "${bytes}"
  fi
}

display_path() {
  case "$1" in
    "${HOME}")
      printf '~'
      ;;
    "${HOME}"/*)
      printf '~/%s' "${1#"${HOME}"/}"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

log_operation() {
  case "$1" in
    iso-build-*|kaskados-build.log|kaskados-main-build.log|kaskados-rebuild.log)
      printf 'Сборка ISO'
      ;;
    desktop-build-*|kaskados-desktop-*-build.log|kaskados-desktop-build.log)
      printf 'Сборка DE'
      ;;
    repository-publish-*|kaskados-publish.log)
      printf 'Публикация DE'
      ;;
    sourceforge-publish-*|kaskados-sourceforge.log)
      printf 'SourceForge'
      ;;
    *)
      printf 'Другая операция'
      ;;
  esac
}

show_logs() {
  local count total_size timestamp display_date bytes file_name

  printf '\n%sЖурналы KaskadOS%s\n\n' "${BOLD}" "${RESET}"
  printf 'Папка: %s\n' "${LOG_DIR}"

  if [[ ! -d "${LOG_DIR}" ]] \
      || [[ -z "$(find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' -print -quit 2>/dev/null)" ]]; then
    printf 'Сохранено: 0 файлов\n\n'
    printf '%sЖурналов операций пока нет.%s\n' "${YELLOW}" "${RESET}"
    return 0
  fi

  count="$(find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' | wc -l)"
  total_size="$(find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' -printf '%s\n' \
    | awk '{ total += $1 } END { print total + 0 }')"
  printf 'Сохранено: %s файлов, %s\n\n' "${count}" "$(human_bytes "${total_size}")"
  printf '  %-16s  %-10s  %-16s  %s\n' 'Дата и время' 'Размер' 'Операция' 'Файл'
  printf '  %-16s  %-10s  %-16s  %s\n' '----------------' '----------' '----------------' '----'
  while IFS=$'\t' read -r timestamp display_date bytes file_name; do
    printf '  %-16s  %10s  %-16s  %s\n' \
      "${display_date}" "$(human_bytes "${bytes}")" "$(log_operation "${file_name}")" "${file_name}"
  done < <(
    find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' \
      -printf '%T@\t%Td.%Tm.%TY %TH:%TM\t%s\t%f\n' \
      | sort -t $'\t' -k1,1nr
  )

  printf '\nЖурналы в установленной системе:\n'
  printf '  /var/log/Calamares.log\n'
  printf '  ~/installation.log\n'
  printf '  /var/log/Calamares-install.json\n'
}

clear_logs() {
  local resolved_log_dir count total_size

  resolved_log_dir="$(readlink -m -- "${LOG_DIR}")" || return $?
  case "${resolved_log_dir}" in
    /|"${HOME}"|"${PROJECT_DIR}")
      printf '%sНебезопасный каталог журналов: %s%s\n' \
        "${RED}" "${resolved_log_dir}" "${RESET}" >&2
      return 2
      ;;
  esac

  if [[ ! -d "${resolved_log_dir}" ]] \
      || [[ -z "$(find "${resolved_log_dir}" -maxdepth 1 -name '*.log' -print -quit 2>/dev/null)" ]]; then
    printf '\n%sЖурналов для удаления нет.%s\n' "${YELLOW}" "${RESET}"
    return 0
  fi

  count="$(find "${resolved_log_dir}" -maxdepth 1 -type f -name '*.log' | wc -l)"
  total_size="$(find "${resolved_log_dir}" -maxdepth 1 -type f -name '*.log' -printf '%s\n' \
    | awk '{ total += $1 } END { print total + 0 }')"
  printf '\nБудут удалены %s журналов (%s) из:\n  %s\n\n' \
    "${count}" "$(human_bytes "${total_size}")" "${resolved_log_dir}"
  confirm 'Удалить все журналы?' || {
    printf 'Очистка отменена.\n'
    return 130
  }

  find "${resolved_log_dir}" -maxdepth 1 \
    \( -type f -o -type l \) -name '*.log' -delete || return $?
  printf '%sЖурналы удалены.%s\n' "${GREEN}" "${RESET}"
}

draw_menu() {
  local version
  version="$(current_version || printf 'неизвестна')"

  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear
  fi

  printf '%s%sKaskadOS — управление сборками%s\n' "${BOLD}" "${CYAN}" "${RESET}"
  printf 'Проект: %s\n' "${PROJECT_DIR}"
  printf 'Версия MacqueenDE: %s\n' "${version}"
  printf 'Журналы: %s\n\n' "$(display_path "${LOG_DIR}")"
  printf '  %s1%s  Собрать ISO\n' "${GREEN}" "${RESET}"
  printf '  %s2%s  Собрать пакет обновления DE\n' "${GREEN}" "${RESET}"
  printf '  %s3%s  Опубликовать собранный пакет DE\n' "${YELLOW}" "${RESET}"
  printf '  %s4%s  Собрать и опубликовать DE\n' "${YELLOW}" "${RESET}"
  printf '  %s5%s  Показать состояние и готовые файлы\n' "${CYAN}" "${RESET}"
  printf '  %s6%s  Опубликовать последний ISO в SourceForge\n' "${YELLOW}" "${RESET}"
  printf '  %s7%s  Повысить версию DE и ISO\n' "${CYAN}" "${RESET}"
  printf '  %s8%s  Закоммитить всё и отправить в GitHub\n' "${YELLOW}" "${RESET}"
  printf '  %s9%s  Показать журналы\n' "${CYAN}" "${RESET}"
  printf '  %s10%s Очистить журналы\n' "${YELLOW}" "${RESET}"
  printf '  %s0%s  Выход\n\n' "${RED}" "${RESET}"
}

for required_file in \
  "${ISO_BUILD_SCRIPT}" \
  "${DESKTOP_BUILD_SCRIPT}" \
  "${DGOP_BUILD_SCRIPT}" \
  "${PUBLISH_SCRIPT}" \
  "${SOURCEFORGE_PUBLISH_SCRIPT}" \
  "${VERSION_FILE}" \
  "${ISO_PROFILE_FILE}" \
  "${RELEASE_MANIFEST}"; do
  [[ -f "${required_file}" ]] || die "не найден файл ${required_file}"
done

[[ -d "${RELEASES_DIR}" ]] || die "не найден каталог ${RELEASES_DIR}"

run_action() {
  case "$1" in
    build-iso) build_iso ;;
    build-desktop) build_desktop ;;
    publish-desktop) publish_desktop ;;
    build-publish-desktop) build_and_publish_desktop ;;
    status) show_status ;;
    publish-iso) publish_iso_sourceforge ;;
    bump-version) bump_version ;;
    commit-push) commit_and_push_all ;;
    logs) show_logs ;;
    clear-logs) clear_logs ;;
    *) die "неизвестное действие: $1" ;;
  esac
}

run_tui() {
  local choice
  while true; do
  draw_menu
  read -r -p 'Выберите действие: ' choice || {
    printf '\n'
    exit 0
  }

  case "${choice}" in
    1)
      build_iso || true
      pause_menu
      ;;
    2)
      build_desktop || true
      pause_menu
      ;;
    3)
      publish_desktop || true
      pause_menu
      ;;
    4)
      build_and_publish_desktop || true
      pause_menu
      ;;
    5)
      show_status
      pause_menu
      ;;
    6)
      publish_iso_sourceforge || true
      pause_menu
      ;;
    7)
      bump_version || true
      pause_menu
      ;;
    8)
      commit_and_push_all || true
      pause_menu
      ;;
    9)
      show_logs
      pause_menu
      ;;
    10)
      clear_logs || true
      pause_menu
      ;;
    0)
      exit 0
      ;;
    *)
      printf '\n%sНет такого пункта.%s\n' "${RED}" "${RESET}"
      pause_menu
      ;;
  esac
  done
}

if (( $# > 0 )); then
  case "$1" in
    --action)
      (( $# == 2 )) || die 'использование: --action НАЗВАНИЕ'
      run_action "$2"
      exit $?
      ;;
    --tui)
      run_tui
      exit 0
      ;;
    --help|-h)
      printf 'Использование: %s [--tui | --action НАЗВАНИЕ]\n' "$0"
      exit 0
      ;;
    *)
      die "неизвестный параметр: $1"
      ;;
  esac
fi

if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && "${KASKADOS_MANAGER_TUI:-0}" != 1 ]]; then
  exec "${PROJECT_DIR}/scripts/run-manager-gui.sh"
fi

run_tui
