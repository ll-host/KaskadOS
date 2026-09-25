#!/usr/bin/env bash

set -euo pipefail

readonly SSH_PROMPT="${1:-}"

command -v zenity >/dev/null 2>&1 || {
  printf 'Для входа в SourceForge не найдено графическое окно ввода пароля (zenity).\n' >&2
  exit 1
}

if [[ "${SSH_PROMPT,,}" == *passphrase* ]]; then
  readonly MESSAGE='Введите парольную фразу SSH-ключа SourceForge:'
else
  readonly MESSAGE='Введите пароль учётной записи SourceForge:'
fi

exec zenity \
  --password \
  --title='Авторизация SourceForge' \
  --text="${MESSAGE}" \
  --width=420
