#!/usr/bin/env bash

set -euo pipefail

repo=${MACQUEENDE_GITHUB_REPO:-ll-host/KaskadOS}
component_path=${MACQUEENDE_REPOSITORY_PATH:-components/macqueende}
release_tag=${MACQUEENDE_RELEASE_TAG:-macqueende-rolling}
requested_mode=${MACQUEENDE_INSTALL_MODE:-}
install_mode=
managed_flameshot=0
arch=$(uname -m)

case "$arch" in
    x86_64) ;;
    *)
        echo "MacqueenDE currently supports Arch Linux x86_64 only." >&2
        exit 1
        ;;
esac
command -v pacman >/dev/null 2>&1 || {
    echo "MacqueenDE installer currently supports Arch Linux only." >&2
    exit 1
}
[[ -n "$requested_mode" || -r /dev/tty ]] || {
    echo "MacqueenDE installer requires an interactive terminal." >&2
    exit 1
}

if [[ -t 1 ]]; then
    red=$'\e[31m'
    green=$'\e[32m'
    yellow=$'\e[33m'
    blue=$'\e[34m'
    bold=$'\e[1m'
    dim=$'\e[2m'
    reset=$'\e[0m'
else
    red= green= yellow= blue= bold= dim= reset=
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/macqueende"
mkdir -p "$state_dir"
log_file="$state_dir/install-$(date +%Y%m%d-%H%M%S).log"
tmp_dir=$(mktemp -d)
checkout_dir="$tmp_dir/kaskados"
source_dir="$checkout_dir/$component_path"
cleanup()
{
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

runtime_packages=(
    curl
    sddm
    kwin
    flameshot
    pacman-contrib
    pciutils
    kconfig
    reflector
    quickshell
    cava
    brightnessctl
    ddcutil
    qt6-multimedia
    qt6-positioning
    qt6-sensors
    qt6-svg
    qt6-5compat
    qt6-connectivity
    qt6-imageformats
)
build_packages=(
    base-devel
    cmake
    ninja
    extra-cmake-modules
    git
    go
    pkgconf
    plasma-wayland-protocols
    vulkan-headers
    wayland-protocols
)

line()
{
    printf '%s\n' '────────────────────────────────────────────────────────'
}

banner()
{
    [[ -t 1 ]] && printf '\033[2J\033[H'
    printf '%s%s\n' "$bold$blue" '  __  __                         ____  _____ '
    printf '%s\n' ' |  \/  | __ _  ___ __ _ _   _|  _ \| ____|'
    printf '%s\n' ' | |\/| |/ _` |/ __/ _` | | | | | | |  _|  '
    printf '%s\n' ' | |  | | (_| | (_| (_| | |_| | |_| | |___ '
    printf '%s%s\n' ' |_|  |_|\__,_|\___\__,_|\__,_|____/|_____|' "$reset"
    printf '%sУстановщик независимого Wayland desktop environment%s\n' \
        "$dim" "$reset"
    line
}

read_choice()
{
    local prompt=$1
    local value
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r value </dev/tty
    printf '%s' "$value"
}

fail_step()
{
    local label=$1
    local rc=$2
    if [[ -t 1 ]]; then
        printf '\r\033[2K  %s✗%s %s\n' "$red" "$reset" "$label" >&2
    else
        printf '  ✗ %s\n' "$label" >&2
    fi
    printf '\n%sПоследние строки журнала:%s\n' "$yellow" "$reset" >&2
    tail -n 30 "$log_file" >&2 || true
    printf '\nПолный журнал: %s\n' "$log_file" >&2
    exit "$rc"
}

run_step()
{
    local label=$1
    shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local frame=0 rc

    if [[ ! -t 1 ]]; then
        printf '  … %s\n' "$label"
        set +e
        "$@" >>"$log_file" 2>&1
        rc=$?
        set -e
        ((rc == 0)) || fail_step "$label" "$rc"
        printf '  ✓ %s\n' "$label"
        return
    fi

    printf '  %s%s%s ' "$blue" "${frames[0]}" "$reset"
    printf '%s' "$label"
    "$@" >>"$log_file" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[2K  %s%s%s %s' \
            "$blue" "${frames[frame]}" "$reset" "$label"
        frame=$(((frame + 1) % ${#frames[@]}))
        sleep 0.12
    done
    set +e
    wait "$pid"
    rc=$?
    set -e
    ((rc == 0)) || fail_step "$label" "$rc"
    printf '\r\033[2K  %s✓%s %s\n' "$green" "$reset" "$label"
}

missing_packages()
{
    local package
    for package in "$@"; do
        pacman -Q "$package" >/dev/null 2>&1 ||
            printf '%s\n' "$package"
    done
}

join_unique_words()
{
    tr ' ' '\n' |
        sed '/^$/d' |
        LC_ALL=C sort -u |
        tr '\n' ' ' |
        sed 's/[[:space:]]*$//'
}

existing_build_packages()
{
    [[ -r /opt/macqueende/INSTALL_INFO ]] || return 0
    sed -n 's/^BUILD_PACKAGES=//p' /opt/macqueende/INSTALL_INFO |
        head -n1
}

existing_managed_flameshot()
{
    [[ -r /opt/macqueende/INSTALL_INFO ]] || return 0
    sed -n 's/^MANAGED_FLAMESHOT=//p' /opt/macqueende/INSTALL_INFO |
        head -n1
}

resolve_binary()
{
    local release_api asset_url asset_name archive_suffix
    release_api="https://api.github.com/repos/$repo/releases/tags/$release_tag?cache_bust=$(date +%s)"
    asset_url=$(curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        -H 'Cache-Control: no-cache' \
        "$release_api" |
        sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*macqueende-[^"]*-'"$arch"'\.tar\.zst\)".*/\1/p' |
        head -n1)
    [[ -n "$asset_url" ]] || {
        echo "No compatible MacqueenDE rolling release was found." >&2
        return 1
    }

    asset_name=$(basename "$asset_url")
    archive_suffix="-$arch.tar.zst"
    binary_version=${asset_name#macqueende-}
    binary_version=${binary_version%"$archive_suffix"}
    [[ "$asset_name" == macqueende-*"$archive_suffix" &&
       -n "$binary_version" ]] || {
        echo "Invalid release asset name: $asset_name" >&2
        return 1
    }
    {
        printf '%s\n' "$asset_url"
        printf '%s\n' "$binary_version"
    } >"$tmp_dir/binary-info"
}

install_runtime_packages()
{
    run_step 'Установка компонентов среды выполнения' \
        sudo pacman -S --needed --noconfirm "${runtime_packages[@]}"
}

install_binary()
{
    local archive="$tmp_dir/macqueende.tar.zst"
    local checksum="$archive.sha256"
    local previous_build

    run_step 'Получение информации о rolling-релизе' resolve_binary
    {
        IFS= read -r binary_asset_url
        IFS= read -r binary_version
    } <"$tmp_dir/binary-info"
    run_step "Загрузка MacqueenDE $binary_version" \
        curl -fL --retry 3 --silent --show-error \
        "$binary_asset_url" -o "$archive"
    run_step 'Загрузка контрольной суммы' \
        curl -fsSL --retry 3 "$binary_asset_url.sha256" -o "$checksum"
    run_step 'Проверка целостности архива' bash -c '
        archive=$1
        checksum=$2
        read -r expected _ <"$checksum"
        printf "%s  %s\\n" "$expected" "$archive" | sha256sum -c -
    ' _ "$archive" "$checksum"
    run_step 'Распаковка бинарного пакета' \
        tar --zstd -xf "$archive" -C "$tmp_dir"

    previous_build=$(existing_build_packages)
    run_step 'Атомарная установка MacqueenDE' \
        env \
        MACQUEENDE_INSTALL_METHOD=binary \
        MACQUEENDE_INSTALL_VERSION="$binary_version" \
        MACQUEENDE_BUILD_PACKAGES="$previous_build" \
        MACQUEENDE_MANAGED_FLAMESHOT="$managed_flameshot" \
        "$tmp_dir/install.sh"
    installed_version=$binary_version
}

configure_sources()
{
    local build_type=Release
    cmake -S "$source_dir/compositor" -B "$source_dir/build/compositor" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE="$build_type" \
        -DCMAKE_INSTALL_PREFIX=/opt/macqueende \
        -DBUILD_TESTING=OFF
    cmake -S "$source_dir/portal" -B "$source_dir/build/portal" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE="$build_type" \
        -DCMAKE_INSTALL_PREFIX=/opt/macqueende \
        -DBUILD_TESTING=OFF
    cmake -S "$source_dir/quickshell/macqueen-module" \
        -B "$source_dir/build/quickshell-macqueen" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE="$build_type" \
        -DCMAKE_INSTALL_PREFIX=/opt/macqueende
}

build_sources()
{
    local jobs=${MACQUEENDE_BUILD_JOBS:-$(nproc)}
    ((jobs > 8)) && jobs=8
    cmake --build "$source_dir/build/compositor" \
        --target macqueen screenshot screencast nightlight --parallel "$jobs"
    cmake --build "$source_dir/build/portal" --parallel "$jobs"
    cmake --build "$source_dir/build/quickshell-macqueen" --parallel "$jobs"
    make -C "$source_dir/shell/MolniyaMacqueenShell/core" \
        VERSION="$source_version" \
        COMMIT="${source_commit:0:12}" \
        build
}

install_source()
{
    local previous_build new_build merged_build archive
    mapfile -t new_build < <(missing_packages "${build_packages[@]}")
    previous_build=$(existing_build_packages)

    run_step 'Установка инструментов компиляции' \
        sudo pacman -S --needed --noconfirm "${build_packages[@]}"
    run_step 'Загрузка исходного кода MacqueenDE' \
        git clone --depth 1 --branch main \
        "https://github.com/$repo.git" "$checkout_dir"

    [[ -d "$source_dir" ]] || {
        echo "MacqueenDE source directory is missing: $component_path" >&2
        return 1
    }
    source_commit=$(git -C "$checkout_dir" rev-parse HEAD)
    source_version="source-$(date +%Y%m%d).${source_commit:0:12}"
    run_step 'Конфигурация компонентов CMake' configure_sources
    run_step 'Компиляция compositor, portal и shell' build_sources
    run_step 'Подготовка локального установочного payload' \
        "$source_dir/packaging/github/build-binary-release.sh" \
        "$source_version" "$arch"

    archive="$source_dir/dist/macqueende-$source_version-$arch.tar.zst"
    run_step 'Проверка локальной сборки' bash -c '
        cd "$1"
        sha256sum -c "$2"
    ' _ "$source_dir/dist" "$(basename "$archive").sha256"
    run_step 'Распаковка локальной сборки' \
        tar --zstd -xf "$archive" -C "$tmp_dir"

    merged_build=$(
        printf '%s %s\n' "$previous_build" "${new_build[*]}" |
            join_unique_words
    )
    run_step 'Атомарная установка собранного MacqueenDE' \
        env \
        MACQUEENDE_INSTALL_METHOD=source \
        MACQUEENDE_INSTALL_VERSION="$source_version" \
        MACQUEENDE_SOURCE_COMMIT="$source_commit" \
        MACQUEENDE_BUILD_PACKAGES="$merged_build" \
        MACQUEENDE_MANAGED_FLAMESHOT="$managed_flameshot" \
        "$tmp_dir/install.sh"
    installed_version=$source_version
}

enable_display_manager()
{
    if [[ ! -e /etc/systemd/system/display-manager.service ]]; then
        sudo systemctl enable sddm.service
        sudo systemctl set-default graphical.target
    fi
}

choose_mode()
{
    local choice
    if [[ -n "$requested_mode" ]]; then
        case "$requested_mode" in
            source|binary)
                install_mode=$requested_mode
                return
                ;;
            *)
                echo "Invalid MACQUEENDE_INSTALL_MODE: $requested_mode" >&2
                exit 1
                ;;
        esac
    fi

    printf '\n%sВыберите способ установки%s\n\n' "$bold" "$reset"
    printf '  %s1)%s Собрать из исходников\n' "$bold" "$reset"
    printf '     Самая свежая версия из main, потребуется время и место.\n\n'
    printf '  %s2)%s Установить готовый бинарник\n' "$bold" "$reset"
    printf '     Быстро: скачивается проверенный rolling-релиз.\n\n'
    printf '  %s0)%s Выход\n\n' "$bold" "$reset"
    while true; do
        choice=$(read_choice 'Ваш выбор: ')
        case "$choice" in
            1) install_mode=source; return ;;
            2) install_mode=binary; return ;;
            0) exit 0 ;;
            *) printf '%sВведите 1, 2 или 0.%s\n' "$red" "$reset" >/dev/tty ;;
        esac
    done
}

main()
{
    banner
    choose_mode

    printf '\nЖурнал установки: %s\n' "$log_file"
    printf 'Для системных изменений потребуется пароль sudo.\n\n'
    sudo -n true 2>/dev/null || sudo -v

    managed_flameshot=$(existing_managed_flameshot)
    [[ "$managed_flameshot" == 1 ]] || managed_flameshot=0
    if ! pacman -Q flameshot >/dev/null 2>&1; then
        managed_flameshot=1
    fi
    install_runtime_packages
    case "$install_mode" in
        source) install_source ;;
        binary) install_binary ;;
    esac
    run_step 'Настройка дисплейного менеджера' enable_display_manager

    printf '\n'
    line
    printf '%s%sMacqueenDE %s успешно установлен%s\n' \
        "$bold" "$green" "$installed_version" "$reset"
    printf 'Выйдите из текущего сеанса и выберите %sMacqueenDE%s в SDDM.\n' \
        "$bold" "$reset"
    printf 'Менеджер системы: %smacqueende-manager%s\n' "$bold" "$reset"
    printf 'Журнал: %s\n' "$log_file"
    line
}

main "$@"
