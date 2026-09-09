#!/usr/bin/env python3

# SPDX-License-Identifier: GPL-3.0-or-later

from pathlib import Path
import re
import shutil

import libcalamares


THEME_POOL = Path("/usr/share/kaskados-installer/theme-pool")

GRUB_THEMES = {
    "minegrub-combined": "minegrub-combined",
    "crt-amber": "crt-amber",
    "fallout": "fallout",
    "lobotomy": "lobotomy",
    "bsol": "bsol",
    "billys-agent": "billys-agent",
    "aero": "aero",
    "milk": "milk",
}

SDDM_THEMES = {
    "pixel-coffee": "pixel-coffee",
    "pixel-munchlax": "pixel-munchlax",
    "pixel-hollowknight": "pixel-hollowknight",
    "enfield": "enfield",
    "winter": "winter",
    "material-you": "material-you",
    "windows_7": "windows_7",
    "terraria": "terraria",
}

MKINITCPIO_PRESET = """# mkinitcpio preset file for the 'linux' package
ALL_config=\"/etc/mkinitcpio.conf\"
ALL_kver=\"/boot/vmlinuz-linux\"

PRESETS=('default' 'fallback')

default_image=\"/boot/initramfs-linux.img\"
fallback_image=\"/boot/initramfs-linux-fallback.img\"
fallback_options=\"-S autodetect\"
"""


def pretty_name():
    return "Настройка тем KaskadOS"


def _target_path(root, absolute_path):
    return root / absolute_path.lstrip("/")


def _selected(global_storage_key, allowed):
    value = libcalamares.globalstorage.value(global_storage_key)
    value = "" if value is None else str(value).strip()
    if value not in allowed:
        raise RuntimeError(
            "Недопустимое значение {}: {!r}".format(global_storage_key, value)
        )
    return value


def _copy_tree(source, destination):
    if not source.is_dir():
        raise RuntimeError("Не найдены файлы темы: {}".format(source))
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)


def _copy_file(source, destination, mode=None):
    if not source.is_file():
        raise RuntimeError("Не найден файл темы: {}".format(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    if mode is not None:
        destination.chmod(mode)


def _set_shell_values(path, values):
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    keys = set(values)
    assignment = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=")
    kept = []
    for line in lines:
        match = assignment.match(line)
        if not match or match.group(1) not in keys:
            kept.append(line)

    if kept and kept[-1]:
        kept.append("")
    for key, value in values.items():
        kept.append('{}="{}"'.format(key, value.replace('"', '\\"')))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(kept) + "\n", encoding="utf-8")


def _install_grub_theme(root, theme_id):
    source = THEME_POOL / "grub" / GRUB_THEMES[theme_id]
    themes_dir = _target_path(root, "/boot/grub/themes")

    if theme_id == "minegrub-combined":
        _copy_tree(source / "minegrub", themes_dir / "minegrub")
        _copy_tree(
            source / "minegrub-world-selection",
            themes_dir / "minegrub-world-selection",
        )
        _copy_file(source / "mainmenu.cfg", _target_path(root, "/boot/grub/mainmenu.cfg"))
        _copy_file(
            source / "05_twomenus",
            _target_path(root, "/etc/grub.d/05_twomenus"),
            0o755,
        )
        _copy_file(
            source / "minegrub-update.service",
            _target_path(root, "/etc/systemd/system/minegrub-update.service"),
        )
        service_link = _target_path(
            root,
            "/etc/systemd/system/multi-user.target.wants/minegrub-update.service",
        )
        service_link.parent.mkdir(parents=True, exist_ok=True)
        if service_link.exists() or service_link.is_symlink():
            service_link.unlink()
        service_link.symlink_to("../minegrub-update.service")
        theme_path = "/boot/grub/themes/minegrub-world-selection/theme.txt"
    else:
        _copy_tree(source, themes_dir / theme_id)
        theme_path = "/boot/grub/themes/{}/theme.txt".format(theme_id)

    _set_shell_values(
        _target_path(root, "/etc/default/grub"),
        {
            "GRUB_TIMEOUT_STYLE": "menu",
            "GRUB_THEME": theme_path,
        },
    )


def _install_sddm_theme(root, theme_id):
    source = THEME_POOL / "sddm" / SDDM_THEMES[theme_id]
    destination = _target_path(root, "/usr/share/sddm/themes") / theme_id
    _copy_tree(source, destination)

    config = _target_path(root, "/etc/sddm.conf.d/kaskados-theme.conf")
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text("[Theme]\nCurrent={}\n".format(theme_id), encoding="utf-8")


def _install_attribution(root, grub_theme):
    source = THEME_POOL / "SOURCES.md"
    destination = _target_path(root, "/usr/share/doc/kaskados-installer-themes/SOURCES.md")
    _copy_file(source, destination)

    sddm_license = THEME_POOL / "sddm" / "LICENSE"
    _copy_file(
        sddm_license,
        _target_path(root, "/usr/share/licenses/kaskados-sddm-themes/LICENSE"),
    )

    if grub_theme == "minegrub-combined":
        minegrub_licenses = THEME_POOL / "grub" / "minegrub-combined"
        for license_file in sorted(minegrub_licenses.glob("LICENSE.*")):
            _copy_file(
                license_file,
                _target_path(
                    root,
                    "/usr/share/licenses/kaskados-grub-themes/minegrub-combined/{}".format(
                        license_file.name
                    ),
                ),
            )


def _install_kernel(root):
    module_kernels = sorted(_target_path(root, "/usr/lib/modules").glob("*/vmlinuz"))
    if len(module_kernels) != 1:
        raise RuntimeError(
            "Ожидался один файл ядра в /usr/lib/modules, найдено: {}".format(
                len(module_kernels)
            )
        )
    _copy_file(module_kernels[0], _target_path(root, "/boot/vmlinuz-linux"), 0o644)


def _prepare():
    root_value = libcalamares.globalstorage.value("rootMountPoint")
    if not root_value:
        raise RuntimeError("Calamares не передал корневой раздел установленной системы")
    root = Path(root_value)
    if not root.is_dir():
        raise RuntimeError("Корневой раздел установленной системы недоступен: {}".format(root))

    grub_theme = _selected("packagechooser_grubtheme", GRUB_THEMES)
    sddm_theme = _selected("packagechooser_sddmtheme", SDDM_THEMES)

    _install_grub_theme(root, grub_theme)
    _install_sddm_theme(root, sddm_theme)
    _install_attribution(root, grub_theme)
    _install_kernel(root)

    preset = _target_path(root, "/etc/mkinitcpio.d/linux.preset")
    preset.parent.mkdir(parents=True, exist_ok=True)
    preset.write_text(MKINITCPIO_PRESET, encoding="utf-8")

    libcalamares.globalstorage.insert("kaskadosGrubTheme", grub_theme)
    libcalamares.globalstorage.insert("kaskadosSddmTheme", sddm_theme)


def _finalize():
    grub_theme = libcalamares.globalstorage.value("kaskadosGrubTheme")
    if grub_theme != "minegrub-combined":
        return

    result = libcalamares.utils.target_env_call(
        [
            "grub-editenv",
            "/boot/grub/grubenv",
            "set",
            "config_file=mainmenu.cfg",
        ]
    )
    if result != 0:
        raise RuntimeError(
            "Не удалось включить связанное меню Minegrub, grub-editenv завершился с кодом {}".format(
                result
            )
        )


def run():
    try:
        stage = libcalamares.job.configuration.get("stage", "prepare")
        if stage == "prepare":
            _prepare()
        elif stage == "finalize":
            _finalize()
        else:
            raise RuntimeError("Неизвестный этап настройки тем: {}".format(stage))
    except Exception as error:
        libcalamares.utils.error(str(error))
        return ("Не удалось настроить оформление системы", str(error))

    return None
