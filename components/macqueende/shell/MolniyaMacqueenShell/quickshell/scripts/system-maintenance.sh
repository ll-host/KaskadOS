#!/usr/bin/env bash

set -euo pipefail

PATH=/usr/bin:/bin
export PATH

operation=${1:-}
maintenance_tmp=

cleanup()
{
    if [[ -n "$maintenance_tmp" && -d "$maintenance_tmp" ]]; then
        rm -rf -- "$maintenance_tmp"
    fi
}

trap cleanup EXIT

fail()
{
    printf '%s\n' "$*" >&2
    exit 1
}

report_progress()
{
    local percent=$1 message=$2
    printf 'progress\t%s\t%s\n' "$percent" "$message"
}

require_root()
{
    [[ $(id -u) -eq 0 ]] || fail 'Для этой операции нужны права администратора.'
}

cache_directories()
{
    if command -v pacman-conf >/dev/null 2>&1; then
        pacman-conf CacheDir 2>/dev/null | sed '/^[[:space:]]*$/d'
    else
        printf '%s\n' /var/cache/pacman/pkg/
    fi
}

cache_size_bytes()
{
    local directory size total=0
    while IFS= read -r directory; do
        [[ -d "$directory" ]] || continue
        size=$(du -sb -- "$directory" 2>/dev/null | awk '{print $1}')
        total=$((total + ${size:-0}))
    done < <(cache_directories)
    printf '%s\n' "$total"
}

file_mtime()
{
    local path=$1
    if [[ -e "$path" ]]; then
        stat -c '%Y' -- "$path"
    else
        printf '0\n'
    fi
}

print_status()
{
    printf 'cache_bytes\t%s\n' "$(cache_size_bytes)"
    printf 'reflector_available\t%s\n' "$(command -v reflector >/dev/null 2>&1 && printf 1 || printf 0)"
    printf 'paccache_available\t%s\n' "$(command -v paccache >/dev/null 2>&1 && printf 1 || printf 0)"
    printf 'arch_mirror_mtime\t%s\n' "$(file_mtime /etc/pacman.d/mirrorlist)"
}

tail_error()
{
    local path=$1
    [[ -s "$path" ]] || return 0
    tail -n 8 -- "$path" >&2
}

update_mirrors()
{
    local backup_dir stamp

    require_root
    report_progress 5 'Проверка необходимых инструментов'
    command -v reflector >/dev/null 2>&1 ||
        fail 'Не найден reflector. Установите пакет reflector.'

    exec 9>/run/macqueende-system-maintenance.lock
    flock -n 9 || fail 'Другая операция обслуживания уже выполняется.'

    maintenance_tmp=$(mktemp -d)

    report_progress 15 'Получение и проверка зеркал Arch Linux'
    if ! reflector \
        --latest 20 \
        --protocol https \
        --sort rate \
        --number 10 \
        --save "$maintenance_tmp/arch-mirrorlist" \
        2>"$maintenance_tmp/reflector-error"; then
        tail_error "$maintenance_tmp/reflector-error"
        fail 'Не удалось получить список зеркал Arch Linux.'
    fi
    grep -Eq '^[[:space:]]*Server[[:space:]]*=[[:space:]]*https://' \
        "$maintenance_tmp/arch-mirrorlist" ||
        fail 'Reflector вернул пустой или некорректный список зеркал.'
    report_progress 70 'Список зеркал Arch Linux проверен'

    report_progress 80 'Создание резервной копии текущего списка'
    backup_dir=/var/lib/macqueende/backups/mirrors
    stamp=$(date '+%Y%m%d-%H%M%S')
    install -d -m 700 -- "$backup_dir"

    if [[ -e /etc/pacman.d/mirrorlist ]]; then
        cp -a -- /etc/pacman.d/mirrorlist \
            "$backup_dir/mirrorlist-$stamp"
    fi

    report_progress 92 'Запись проверенного списка зеркал'
    install -m 644 -o root -g root -- \
        "$maintenance_tmp/arch-mirrorlist" /etc/pacman.d/mirrorlist

    report_progress 100 'Зеркала обновлены'
    printf 'result\tmirrors_updated\n'
    printf 'backup_directory\t%s\n' "$backup_dir"
    printf 'arch_mirror_mtime\t%s\n' "$(file_mtime /etc/pacman.d/mirrorlist)"
}

clean_cache()
{
    local before after freed

    require_root
    report_progress 5 'Проверка необходимых инструментов'
    command -v paccache >/dev/null 2>&1 ||
        fail 'Не найден paccache. Установите пакет pacman-contrib.'

    exec 9>/run/macqueende-system-maintenance.lock
    flock -n 9 || fail 'Другая операция обслуживания уже выполняется.'

    report_progress 15 'Подсчёт размера кэша'
    before=$(cache_size_bytes)
    report_progress 35 'Удаление старых версий установленных пакетов'
    paccache --remove --keep 2 --nocolor
    report_progress 70 'Удаление кэша неустановленных пакетов'
    paccache --remove --uninstalled --keep 0 --nocolor
    report_progress 90 'Подсчёт освобождённого места'
    after=$(cache_size_bytes)
    freed=$((before > after ? before - after : 0))

    report_progress 100 'Кэш очищен'
    printf 'result\tcache_cleaned\n'
    printf 'cache_before\t%s\n' "$before"
    printf 'cache_after\t%s\n' "$after"
    printf 'cache_freed\t%s\n' "$freed"
}

case "$operation" in
    status)
        print_status
        ;;
    update-mirrors)
        update_mirrors
        ;;
    clean-cache)
        clean_cache
        ;;
    *)
        fail 'Неизвестная операция обслуживания.'
        ;;
esac
