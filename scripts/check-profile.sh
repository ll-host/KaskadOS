#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PROFILE_DIR="${PROJECT_DIR}/profile"

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

required_paths=(
  'profiledef.sh'
  'pacman.conf'
  'packages.x86_64'
  'airootfs'
  'efiboot'
  'syslinux'
)

for path in "${required_paths[@]}"; do
  [[ -e "${PROFILE_DIR}/${path}" ]] || die "в профиле отсутствует ${path}"
done

while IFS= read -r -d '' script; do
  bash -n -- "${script}"
done < <(find "${PROFILE_DIR}" "${SCRIPT_DIR}" -type f -name '*.sh' -print0)

mapfile -t repositories < <(pacman-conf -c "${PROFILE_DIR}/pacman.conf" -l)
[[ " ${repositories[*]} " == *' core '* ]] || die 'в pacman.conf не включён репозиторий core'
[[ " ${repositories[*]} " == *' extra '* ]] || die 'в pacman.conf не включён репозиторий extra'

duplicates="$({ sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${PROFILE_DIR}/packages.x86_64" || true; } | sort | uniq -d)"
[[ -z "${duplicates}" ]] || die $'в packages.x86_64 есть дубликаты:\n'"${duplicates}"

LC_ALL=C sort -c "${PROFILE_DIR}/packages.x86_64" || die 'packages.x86_64 должен быть отсортирован'

grep -Fxq 'breeze-cursors' "${PROFILE_DIR}/packages.x86_64" \
  || die 'в packages.x86_64 отсутствует тема курсора breeze-cursors'

required_installed_packages=(
  bluez
  bluez-utils
  brightnessctl
  cava
  edk2-shell
  fastfetch
  flameshot
  grub
  kwin
  memtest86+
  memtest86+-efi
  networkmanager
  polkit
  python-pillow
  qt6-5compat
  qt6-multimedia
  qt6-multimedia-ffmpeg
  quickshell
  sddm
  plasma-workspace
  xorg-xwayland
)
for package_name in "${required_installed_packages[@]}"; do
  grep -Fxq "${package_name}" "${PROFILE_DIR}/packages.x86_64" \
    || die "в packages.x86_64 отсутствует обязательный пакет ${package_name}"
done

readonly DESKTOP_PKGBUILD="${PROJECT_DIR}/repository/packages/kaskados-desktop/PKGBUILD"
readonly DESKTOP_INSTALL="${PROJECT_DIR}/repository/packages/kaskados-desktop/kaskados-desktop.install"
for package_name in bluez bluez-utils; do
  grep -Fxq "  '${package_name}'" "${DESKTOP_PKGBUILD}" \
    || die "пакет kaskados-desktop не зависит от ${package_name}"
done
grep -Fq 'install=kaskados-desktop.install' "${DESKTOP_PKGBUILD}" \
  || die 'пакет kaskados-desktop не подключает настройку Bluetooth'
grep -Fq 'systemctl enable bluetooth.service' "${DESKTOP_INSTALL}" \
  || die 'обновление kaskados-desktop не включает службу Bluetooth'

readonly KEYRING_INSTALL="${PROJECT_DIR}/repository/packages/kaskados-keyring/kaskados-keyring.install"
grep -Fq 'usr/bin/pacman-key -l >/dev/null 2>&1' "${KEYRING_INSTALL}" \
  || die 'пакет kaskados-keyring не проверяет готовность системного keyring'
grep -Fq 'usr/bin/pacman-key --populate kaskados' "${KEYRING_INSTALL}" \
  || die 'пакет kaskados-keyring не добавляет ключи KaskadOS'

readonly SESSION_SCRIPT="${PROFILE_DIR}/airootfs/usr/local/bin/kaskados-installer-session"
grep -Fxq "export XCURSOR_THEME='breeze_cursors'" "${SESSION_SCRIPT}" \
  || die 'в live-сеансе не выбрана тема курсора breeze_cursors'
grep -Eq "^export XCURSOR_SIZE='[1-9][0-9]*'$" "${SESSION_SCRIPT}" \
  || die 'в live-сеансе не задан корректный размер курсора'
grep -Fxq 'LANG=ru_RU.UTF-8' "${PROFILE_DIR}/airootfs/etc/locale.conf" \
  || die 'русский язык не выбран в live-системе по умолчанию'
grep -Fxq "export LANG='ru_RU.UTF-8'" "${SESSION_SCRIPT}" \
  || die 'русский язык не выбран для live-установщика по умолчанию'

readonly WELCOME_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/welcome/welcome.conf"
if grep -Eq '^[[:space:]]*-[[:space:]]*("false"|slow-false|slow-true|snark)[[:space:]]*$' "${WELCOME_CONFIG}"; then
  die 'в welcome.conf включены тестовые проверки Calamares'
fi
grep -Eq '^showSupportUrl:[[:space:]]+false$' "${WELCOME_CONFIG}" \
  || die 'в welcome.conf отображается ссылка поддержки'
grep -Eq '^showKnownIssuesUrl:[[:space:]]+false$' "${WELCOME_CONFIG}" \
  || die 'в welcome.conf отображается ссылка известных проблем'
if grep -Eq '^[[:space:]]*geoip:' "${WELCOME_CONFIG}"; then
  die 'в welcome.conf включено сетевое определение местоположения'
fi

readonly LOCALE_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/locale/locale.conf"
if grep -Eq '^[[:space:]]*geoip:' "${LOCALE_CONFIG}"; then
  die 'в locale.conf включено сетевое определение часового пояса'
fi
grep -Eq '^[[:space:]]*ru:[[:space:]]+"Europe/Moscow"$' "${LOCALE_CONFIG}" \
  || die 'для русской локали не задан часовой пояс Europe/Moscow'
grep -Eq '^localeTimezones:$' "${LOCALE_CONFIG}" \
  || die 'в locale.conf отсутствуют офлайн-правила выбора часового пояса'

readonly CALAMARES_WINDOW="${PROJECT_DIR}/components/calamares/src/calamares/CalamaresWindow.cpp"
if grep -Eq 'setObjectName\([[:space:]]*"(aboutButton|debugButton)"' "${CALAMARES_WINDOW}"; then
  die 'в боковой панели Calamares создаются кнопки About или Debug'
fi

readonly CALAMARES_RUNNER="${PROFILE_DIR}/airootfs/usr/local/bin/kaskados-run-calamares"
readonly CALAMARES_FINALIZER="${PROFILE_DIR}/airootfs/usr/local/libexec/kaskados-finalize-installation"
readonly CALAMARES_TARGET_RECORDER="${PROFILE_DIR}/airootfs/usr/local/libexec/kaskados-record-install-target"
readonly CALAMARES_USER_PREFERENCES="${PROFILE_DIR}/airootfs/usr/local/libexec/kaskados-apply-user-preferences"
if grep -Eq 'exec .*calamares.*[[:space:]]-D[0-9]+' "${CALAMARES_RUNNER}"; then
  die 'Calamares запускается с диагностическим уровнем журналирования'
fi
bash -n "${CALAMARES_FINALIZER}" "${CALAMARES_TARGET_RECORDER}" "${CALAMARES_USER_PREFERENCES}"
[[ -x "${CALAMARES_USER_PREFERENCES}" ]] \
  || die 'скрипт переноса пользовательских настроек не является исполняемым'
grep -Fq '"${finalizer}" || true' "${CALAMARES_RUNNER}" \
  || die 'после выхода Calamares не сохраняется окончательный журнал'
grep -Fq 'Logger::setupLogfile();' "${PROJECT_DIR}/components/calamares/src/calamares/CalamaresApplication.cpp" \
  || die 'Calamares не создаёт временный журнал хода установки'

readonly CALAMARES_SETTINGS="${PROJECT_DIR}/components/calamares/settings.conf"
grep -Fq 'id:          pacmankeyring' "${CALAMARES_SETTINGS}" \
  || die 'в Calamares не зарегистрирована подготовка ключей pacman'
grep -Fq 'config:      pacmankeyring.conf' "${CALAMARES_SETTINGS}" \
  || die 'Calamares не использует безопасную конфигурацию pacmankeyring'
grep -Fq 'shellprocess@pacmankeyring' "${CALAMARES_SETTINGS}" \
  || die 'в последовательности Calamares не запускается подготовка ключей pacman'
grep -Fq 'id:          gpu' "${CALAMARES_SETTINGS}" \
  || die 'в Calamares не зарегистрирована настройка графического драйвера'
grep -Fq 'config:      gpu.conf' "${CALAMARES_SETTINGS}" \
  || die 'Calamares не использует конфигурацию определения NVIDIA'
grep -Fq 'shellprocess@gpu' "${CALAMARES_SETTINGS}" \
  || die 'в последовательности Calamares не запускается настройка графического драйвера'
grep -Fq 'packagechooser@grubtheme' "${CALAMARES_SETTINGS}" \
  || die 'в Calamares не подключён выбор темы GRUB'
grep -Fq 'packagechooser@sddmtheme' "${CALAMARES_SETTINGS}" \
  || die 'в Calamares не подключён выбор темы SDDM'
grep -Fq 'kaskadthemes@themes-prepare' "${CALAMARES_SETTINGS}" \
  || die 'в Calamares не подключена установка выбранных тем'
grep -Fq 'kaskadthemes@themes-finalize' "${CALAMARES_SETTINGS}" \
  || die 'в Calamares не подключено завершение настройки GRUB'
grep -Fq '  - preservefiles' "${CALAMARES_SETTINGS}" \
  || die 'Calamares не сохраняет журнал установки'
grep -Fq 'shellprocess@installationlog' "${CALAMARES_SETTINGS}" \
  || die 'Calamares не запоминает раздел для финального журнала'
grep -Fq '/usr/local/libexec/kaskados-record-install-target ${ROOT} ${USER}' \
  "${PROJECT_DIR}/components/calamares/src/modules/shellprocess/installationlog.conf" \
  || die 'Calamares не передаёт раздел установщику журналов'
grep -Fq '/usr/bin/bash /usr/local/libexec/kaskados-apply-user-preferences ${ROOT} ${USER}' \
  "${PROJECT_DIR}/components/calamares/src/modules/shellprocess/userpreferences.conf" \
  || die 'Calamares запускает перенос пользовательских настроек не через Bash'
readonly PRESERVEFILES_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/preservefiles/preservefiles.conf"
grep -Fq 'dest: /var/log/Calamares.log' "${PRESERVEFILES_CONFIG}" \
  || die 'журнал Calamares не записывается в установленную систему'
grep -Fq 'dest: /home/${USER}/installation.log' "${PRESERVEFILES_CONFIG}" \
  || die 'копия журнала Calamares не сохраняется в домашнем каталоге'
grep -Fq 'kaskados-finalize-installation --reboot' \
  "${PROJECT_DIR}/components/calamares/src/modules/finished/finished.conf" \
  || die 'перезагрузка не завершает сохранение журнала Calamares'
if grep -Eq '^[[:space:]]*-[[:space:]]*(packages|netinstall)(@[^[:space:]]+)?[[:space:]]*$' "${CALAMARES_SETTINGS}"; then
  die 'в последовательности установки присутствует сетевой модуль пакетов'
fi

readonly UNPACKFS_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/unpackfs/unpackfs.conf"
grep -Fq 'source: "/run/archiso/airootfs"' "${UNPACKFS_CONFIG}" \
  || die 'unpackfs не копирует автономную live-систему в установленную систему'
if grep -Eq '^[[:space:]]*-[[:space:]]*source:[[:space:]]+\.\./CHANGES' "${UNPACKFS_CONFIG}"; then
  die 'в unpackfs остался тестовый источник Calamares'
fi
grep -Fq '_install_kernel(root)' "${PROJECT_DIR}/components/calamares/src/modules/kaskadthemes/main.py" \
  || die 'установщик не переносит ядро из live-образа в /boot'
if grep -Fq '"/opt/macqueende/' "${UNPACKFS_CONFIG}"; then
  die 'unpackfs исключает MacqueenDE из установленной системы'
fi

readonly MACQUEENDE_DIR="${PROJECT_DIR}/components/macqueende"
for source_path in \
  VERSION \
  compositor/CMakeLists.txt \
  portal/CMakeLists.txt \
  quickshell/macqueen-module/CMakeLists.txt \
  shell/MolniyaMacqueenShell/core/Makefile \
  shell/MolniyaMacqueenShell/quickshell/shell.qml \
  session/macqueende.desktop \
  session/macqueen.portal \
  session/org.freedesktop.impl.portal.desktop.macqueen.desktop.in \
  session/org.freedesktop.impl.portal.desktop.macqueen.service.in \
  session/run-molniya \
  session/xdg-desktop-portal-macqueen.service.in \
  start-macqueende; do
  [[ -e "${MACQUEENDE_DIR}/${source_path}" ]] \
    || die "в MacqueenDE отсутствует ${source_path}"
done

readonly MACQUEEN_SESSION="${PROFILE_DIR}/airootfs/usr/share/wayland-sessions/macqueende.desktop"
grep -Fxq 'Exec=/usr/bin/start-macqueende' "${MACQUEEN_SESSION}" \
  || die 'сеанс SDDM не запускает MacqueenDE'
grep -Fxq 'TryExec=/usr/bin/start-macqueende' "${MACQUEEN_SESSION}" \
  || die 'в сеансе SDDM не задана проверка запуска MacqueenDE'
readonly DISPLAYMANAGER_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/displaymanager/displaymanager.conf"
grep -Fq 'executable: "/usr/bin/start-macqueende"' "${DISPLAYMANAGER_CONFIG}" \
  || die 'Calamares не выбирает запуск MacqueenDE по умолчанию'
grep -Fq 'desktopFile: "macqueende"' "${DISPLAYMANAGER_CONFIG}" \
  || die 'Calamares не выбирает сеанс MacqueenDE по умолчанию'

readonly PREPARE_PROFILE="${SCRIPT_DIR}/prepare-live-profile.sh"
grep -Fq -- '--target macqueen screenshot screencast nightlight' "${PREPARE_PROFILE}" \
  || die 'prepare-live-profile.sh не собирает обязательные цели Macqueen'
grep -Fq 'readonly MACQUEEN_STAGE="${PROFILE_DIR}/airootfs/opt/macqueende"' "${PREPARE_PROFILE}" \
  || die 'prepare-live-profile.sh не добавляет MacqueenDE в ISO'
readonly MOLNIYA_SHELL="${MACQUEENDE_DIR}/shell/MolniyaMacqueenShell/quickshell/shell.qml"
grep -Fq 'active: shellCoreLoader.status === Loader.Ready' "${MOLNIYA_SHELL}" \
  || die 'тяжёлая часть Molniya запускается до основной панели'
grep -Fq 'source: "DMSShell.qml"' "${MOLNIYA_SHELL}" \
  || die 'тяжёлая часть Molniya не вынесена в асинхронный Loader'
grep -Fq 'org.freedesktop.impl.portal.desktop.macqueen' \
  "${MACQUEENDE_DIR}/session/run-molniya" \
  || die 'сеанс MacqueenDE не проверяет собственный portal'
if grep -Fq '"$portal" --replace' "${MACQUEENDE_DIR}/session/run-molniya"; then
  die 'сеанс MacqueenDE вручную подменяет KDE portal'
fi
grep -Fq 'org.freedesktop.DBus.Properties.Get' \
  "${MACQUEENDE_DIR}/session/run-molniya" \
  || die 'сеанс MacqueenDE не проверяет готовность Macqueen portal напрямую'
if grep -Fq 'grep -q org.freedesktop.impl.portal.ScreenCast' \
  "${MACQUEENDE_DIR}/session/run-molniya"; then
  die 'проверка Macqueen portal всё ещё зависит от нестабильного конвейера qdbus'
fi
grep -Fxq 'org.freedesktop.impl.portal.ScreenCast=macqueen' \
  "${MACQUEENDE_DIR}/session/macqueende-portals.conf" \
  || die 'ScreenCast не направлен в Macqueen portal'
grep -Fxq 'DBusName=org.freedesktop.impl.portal.desktop.macqueen' \
  "${MACQUEENDE_DIR}/session/macqueen.portal" \
  || die 'Macqueen portal не имеет собственного D-Bus имени'
grep -Fxq 'Environment=QT_NO_XDG_DESKTOP_PORTAL=1' \
  "${MACQUEENDE_DIR}/session/xdg-desktop-portal-macqueen.service.in" \
  || die 'Macqueen portal не изолирован от frontend portal'
if grep -Fxq "  'xdg-desktop-portal-kde'" "${DESKTOP_PKGBUILD}"; then
  die 'kaskados-desktop всё ещё зависит от KDE portal'
fi
for package_name in nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils nvidia-prime; do
  grep -Fq "'${package_name}'" "${PREPARE_PROFILE}" \
    || die "prepare-live-profile.sh не добавляет в автономный ISO пакет ${package_name}"
done
grep -Fq 'https://aur.archlinux.org/nvidia-580xx-utils.git' "${PREPARE_PROFILE}" \
  || die 'prepare-live-profile.sh не получает закрытый драйвер NVIDIA из AUR'
grep -Fq 'https://aur.archlinux.org/lib32-nvidia-580xx-utils.git' "${PREPARE_PROFILE}" \
  || die 'prepare-live-profile.sh не получает 32-битные библиотеки NVIDIA из AUR'

readonly GPU_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/shellprocess/gpu.conf"
readonly GPU_CONFIGURATOR="${PROFILE_DIR}/airootfs/usr/local/libexec/kaskados-configure-gpu"
grep -Fq '/usr/local/libexec/kaskados-configure-gpu ${ROOT}' "${GPU_CONFIG}" \
  || die 'Calamares не передаёт корень установленной системы настройщику NVIDIA'
grep -Fq "0x10de" "${GPU_CONFIGURATOR}" \
  || die 'настройщик графики не определяет устройства NVIDIA'
grep -Fq 'test -x /usr/bin/prime-run' "${GPU_CONFIGURATOR}" \
  || die 'настройщик NVIDIA не проверяет наличие prime-run'
grep -Fq '"/usr/local/libexec/kaskados-configure-gpu"' \
  "${PROJECT_DIR}/components/calamares/src/modules/unpackfs/unpackfs.conf" \
  || die 'служебный настройщик NVIDIA попадёт в установленную систему'
for installer_helper in \
  kaskados-finalize-installation \
  kaskados-record-install-target; do
  grep -Fq "\"/usr/local/libexec/${installer_helper}\"" \
    "${PROJECT_DIR}/components/calamares/src/modules/unpackfs/unpackfs.conf" \
    || die "служебный файл ${installer_helper} попадёт в установленную систему"
done

readonly REGALIA_DIR="${PROJECT_DIR}/components/regalia"
for source_path in \
  go.mod \
  cmd/regalia/main.go \
  cmd/regaliad/main.go \
  cmd/regalia-engine/main.go \
  packaging/systemd/regalia-engine@.service \
  packaging/systemd/user/regaliad.service \
  packaging/polkit/50-regalia-engine.rules; do
  [[ -e "${REGALIA_DIR}/${source_path}" ]] \
    || die "в Regalia отсутствует ${source_path}"
done
grep -Fq 'go build -trimpath' "${PREPARE_PROFILE}" \
  || die 'prepare-live-profile.sh не собирает Regalia'
grep -Fq 'SING_BOX_SHA256=' "${PREPARE_PROFILE}" \
  || die 'для sing-box не задана контрольная сумма'
grep -Fq 'default.target.wants/regaliad.service' "${PREPARE_PROFILE}" \
  || die 'пользовательская служба Regalia не включается автоматически'

readonly REGALIA_SERVICE_QML="${MACQUEENDE_DIR}/shell/MolniyaMacqueenShell/quickshell/Services/RegaliaService.qml"
readonly REGALIA_SETTINGS_QML="${MACQUEENDE_DIR}/shell/MolniyaMacqueenShell/quickshell/Modules/Settings/NetworkVpnTab.qml"
if grep -Eq 'installerUrl|uninstallerUrl|installComponent|uninstallComponent' \
  "${REGALIA_SERVICE_QML}" "${REGALIA_SETTINGS_QML}"; then
  die 'MacqueenDE всё ещё устанавливает Regalia как внешний компонент'
fi

readonly BOOTLOADER_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/bootloader/bootloader.conf"
grep -Eq '^efiBootLoader:[[:space:]]+"grub"$' "${BOOTLOADER_CONFIG}" \
  || die 'GRUB не выбран обязательным загрузчиком'

readonly SERVICES_CONFIG="${PROJECT_DIR}/components/calamares/src/modules/services-systemd/services-systemd.conf"
grep -Fq 'name: "bluetooth.service"' "${SERVICES_CONFIG}" \
  || die 'Calamares не включает системную службу Bluetooth'
grep -Fq 'name: "sddm.service"' "${SERVICES_CONFIG}" \
  || die 'SDDM не включается в установленной системе'
grep -Fq 'action: "set-default"' "${SERVICES_CONFIG}" \
  || die 'графический режим не выбран режимом загрузки по умолчанию'

readonly THEMES_DIR="${PROJECT_DIR}/components/installer-themes"
grub_themes=(minegrub-combined crt-amber fallout lobotomy bsol billys-agent aero milk)
sddm_themes=(pixel-coffee pixel-munchlax pixel-hollowknight enfield winter material-you windows_7 terraria)
for theme_name in "${grub_themes[@]}"; do
  [[ -d "${THEMES_DIR}/grub/${theme_name}" ]] || die "не найдена тема GRUB ${theme_name}"
  [[ -f "${THEMES_DIR}/previews/grub/${theme_name}.png" ]] || die "не найдено превью GRUB ${theme_name}"
done
[[ -f "${THEMES_DIR}/grub/minegrub-combined/minegrub-update.service" ]] \
  || die 'для Minegrub не найден сервис смены текста'
for theme_name in "${sddm_themes[@]}"; do
  [[ -f "${THEMES_DIR}/sddm/${theme_name}/Main.qml" ]] || die "не найдена тема SDDM ${theme_name}"
  [[ -f "${THEMES_DIR}/previews/sddm/${theme_name}.gif" ]] || die "не найдено GIF-превью SDDM ${theme_name}"
done

readonly KEYBOARD_DIR="${PROJECT_DIR}/components/calamares/src/modules/keyboard"
grep -Eq '^guessLayout:[[:space:]]+true$' "${KEYBOARD_DIR}/keyboard.conf" \
  || die 'автоматический выбор раскладки по языку отключён'
grep -Fq 'isRussianLocale( lang )' "${KEYBOARD_DIR}/Config.cpp" \
  || die 'для русского языка не задано отдельное правило выбора раскладки'
grep -Fq 'lang = QStringLiteral( "us" );' "${KEYBOARD_DIR}/Config.cpp" \
  || die 'для русского языка не задана раскладка us по умолчанию'
if grep -Eq 'groupSelector|Switch Keyboard:' "${KEYBOARD_DIR}/KeyboardPage.ui"; then
  die 'в интерфейсе Calamares осталась настройка переключения раскладок'
fi
grep -Fq 'gs->insert( "keyboardAdditionalLayout", m_additionalLayoutInfo.additionalLayout );' \
  "${KEYBOARD_DIR}/Config.cpp" \
  || die 'выбранная дополнительная раскладка не сохраняется для установленной системы'
grep -Fq 'gs->insert( "keyboardGroupSwitcher", m_additionalLayoutInfo.groupSwitcher );' \
  "${KEYBOARD_DIR}/Config.cpp" \
  || die 'способ переключения раскладок не сохраняется для установленной системы'
grep -Fq 'm_additionalLayoutInfo.additionalLayout, m_layout' \
  "${KEYBOARD_DIR}/SetKeyboardLayoutJob.cpp" \
  || die 'дополнительная раскладка не записывается в конфигурацию установленной системы'

# shellcheck disable=SC1090
declare -A file_permissions=()
source "${PROFILE_DIR}/profiledef.sh"
[[ -n "${iso_name:-}" ]] || die 'в profiledef.sh не задан iso_name'
[[ -n "${iso_version:-}" ]] || die 'в profiledef.sh не задан iso_version'
(( ${#bootmodes[@]} > 0 )) || die 'в profiledef.sh не заданы bootmodes'
[[ " ${bootmodes[*]} " == *' bios.syslinux '* ]] \
  || die 'Legacy BIOS-загрузка ISO должна использовать Syslinux'
[[ " ${bootmodes[*]} " == *' uefi.systemd-boot '* ]] \
  || die 'UEFI-загрузка ISO должна использовать systemd-boot'
[[ " ${bootmodes[*]} " != *' uefi.grub '* ]] \
  || die 'GRUB не должен использоваться для UEFI-загрузки live-ISO'

readonly SYSTEMD_BOOT_ENTRY_DIR="${PROFILE_DIR}/efiboot/loader/entries"
readonly SYSTEMD_BOOT_ENTRY="${SYSTEMD_BOOT_ENTRY_DIR}/01-archiso-linux.conf"
readonly SYSTEMD_BOOT_CONFIG="${PROFILE_DIR}/efiboot/loader/loader.conf"
[[ -f "${SYSTEMD_BOOT_CONFIG}" ]] \
  || die 'в ISO отсутствует конфигурация systemd-boot'
[[ -f "${SYSTEMD_BOOT_ENTRY}" ]] \
  || die 'в ISO отсутствует пункт запуска KaskadOS для systemd-boot'
(( $(find "${SYSTEMD_BOOT_ENTRY_DIR}" -maxdepth 1 -type f -name '*.conf' | wc -l) == 1 )) \
  || die 'в меню systemd-boot должен оставаться ровно один пункт'
grep -Eq '^title[[:space:]]+Start KaskadOS installation$' "${SYSTEMD_BOOT_ENTRY}" \
  || die 'в меню systemd-boot отсутствует совместимый с UEFI запуск KaskadOS'
grep -Eq '^auto-entries[[:space:]]+no$' "${SYSTEMD_BOOT_CONFIG}" \
  || die 'systemd-boot показывает автоматически найденные пункты'
grep -Eq '^auto-firmware[[:space:]]+no$' "${SYSTEMD_BOOT_CONFIG}" \
  || die 'systemd-boot показывает переход в настройки UEFI'
grep -Eq '^initrd[[:space:]]+/%INSTALL_DIR%/boot/%ARCH%/initramfs-linux\.img$' \
  "${SYSTEMD_BOOT_ENTRY}" \
  || die 'systemd-boot не загружает initramfs live-системы'

required_executables=(
  '/opt/kaskados-installer/bin/kaskad-installer'
  '/usr/bin/calamares'
  '/usr/local/bin/kaskados-installer-session'
  '/usr/local/bin/kaskados-run-calamares'
  '/usr/local/libexec/kaskados-configure-gpu'
  '/usr/local/libexec/kaskados-finalize-installation'
  '/usr/local/libexec/kaskados-record-install-target'
)
for executable_path in "${required_executables[@]}"; do
  [[ "${file_permissions[${executable_path}]:-}" == '0:0:755' ]] \
    || die "для ${executable_path} в profiledef.sh должны быть заданы права 0:0:755"
done

printf 'Профиль корректен: %s (%s)\n' "${iso_name}" "${iso_version}"
