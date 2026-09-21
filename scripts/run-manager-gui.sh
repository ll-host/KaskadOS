#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SOURCE_DIR="${PROJECT_DIR}/tools/kaskados-manager"
readonly BUILD_DIR="${PROJECT_DIR}/build/kaskados-manager"
readonly EXECUTABLE="${BUILD_DIR}/kaskados-manager"

command -v cmake >/dev/null 2>&1 || {
  printf 'Ошибка: не найдена команда cmake\n' >&2
  exit 1
}
command -v ninja >/dev/null 2>&1 || {
  printf 'Ошибка: не найдена команда ninja\n' >&2
  exit 1
}

needs_build=0
if [[ ! -x "${EXECUTABLE}" ]]; then
  needs_build=1
elif find "${SOURCE_DIR}" -type f -newer "${EXECUTABLE}" -print -quit | grep -q .; then
  needs_build=1
fi

if (( needs_build )); then
  cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "${BUILD_DIR}" --parallel
fi

exec "${EXECUTABLE}" --project "${PROJECT_DIR}"
