#!/usr/bin/env bash

set -uo pipefail

clean()
{
    printf '%s' "${1:-}" |
        tr '\t\r\n' '   ' |
        sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

emit()
{
    printf '%s\t%s\t%s\n' \
        "$(clean "${1:-}")" \
        "$(clean "${2:-}")" \
        "$(clean "${3:-}")"
}

emit_fields()
{
    local separator=
    local field
    for field in "$@"; do
        printf '%s%s' "$separator" "$(clean "$field")"
        separator=$'\t'
    done
    printf '\n'
}

cpu_value()
{
    LC_ALL=C lscpu 2>/dev/null |
        awk -F: -v key="$1" '
            $1 == key {
                sub(/^[[:space:]]+/, "", $2)
                print $2
                exit
            }
        '
}

mem_kib()
{
    awk -v key="$1:" '$1 == key { print $2; exit }' /proc/meminfo 2>/dev/null
}

root=${MACQUEENDE_ROOT:-}
version=
release_channel=
release_date=
install_method=
release_manifest=/usr/share/kaskados/release.json
if [[ ! -r "$release_manifest" && -n "$root" && -r "$root/release/release.json" ]]; then
    release_manifest="$root/release/release.json"
fi
if [[ -r "$release_manifest" ]]; then
    version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$release_manifest" | head -n1)
    release_channel=$(sed -n 's/^[[:space:]]*"channel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$release_manifest" | head -n1)
    release_date=$(sed -n 's/^[[:space:]]*"releaseDate"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$release_manifest" | head -n1)
    install_method=kaskados
fi
if [[ -r "$root/INSTALL_INFO" ]]; then
    [[ -n "$version" ]] || version=$(sed -n 's/^VERSION=//p' "$root/INSTALL_INFO" | head -n1)
    [[ -n "$install_method" ]] || install_method=$(sed -n 's/^METHOD=//p' "$root/INSTALL_INFO" | head -n1)
fi
if [[ -z "$version" && -r "$root/VERSION" ]]; then
    version=$(head -n1 "$root/VERSION")
fi
if [[ -z "$install_method" && -n "$root" ]] &&
   git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    install_method=development
fi
if [[ -z "$version" && -n "$root" ]] &&
   git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    version="dev-$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null)"
    install_method=development
fi
[[ -n "$version" ]] || version=unknown

distro=
if [[ -r /etc/os-release ]]; then
    distro=$(
        . /etc/os-release
        printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}"
    )
fi
[[ -n "$distro" ]] || distro=Linux

package_manager=Unknown
package_helper=
package_count=
if command -v pacman >/dev/null 2>&1; then
    package_manager=Pacman
    package_count=$(pacman -Qq 2>/dev/null | wc -l)
    if command -v paru >/dev/null 2>&1; then
        package_helper=Paru
    elif command -v yay >/dev/null 2>&1; then
        package_helper=Yay
    fi
elif command -v dnf >/dev/null 2>&1; then
    package_manager=DNF
elif command -v apt >/dev/null 2>&1; then
    package_manager=APT
elif command -v zypper >/dev/null 2>&1; then
    package_manager=Zypper
elif command -v apk >/dev/null 2>&1; then
    package_manager=APK
elif command -v xbps-install >/dev/null 2>&1; then
    package_manager=XBPS
elif command -v emerge >/dev/null 2>&1; then
    package_manager=Portage
elif command -v nix-env >/dev/null 2>&1; then
    package_manager=Nix
fi

session_type=${XDG_SESSION_TYPE:-unknown}
case "${session_type,,}" in
    wayland) session_type=Wayland ;;
    x11) session_type=X11 ;;
esac

emit general de_name MacqueenDE
emit general version "$version"
emit general release_channel "$release_channel"
emit general release_date "$release_date"
emit general install_method "$install_method"
emit general os "$distro"
emit general hostname "$(hostname 2>/dev/null)"
emit general kernel "$(uname -sr 2>/dev/null)"
emit general architecture "$(uname -m 2>/dev/null)"
emit general session "$session_type"
emit general compositor "${XDG_CURRENT_DESKTOP:-MacqueenDE}"
emit general package_manager "$package_manager"
emit general package_helper "$package_helper"
emit general package_count "$package_count"
emit general uptime_seconds "$(cut -d. -f1 /proc/uptime 2>/dev/null)"

logical_cpus=$(cpu_value "CPU(s)")
cores_per_socket=$(cpu_value "Core(s) per socket")
sockets=$(cpu_value "Socket(s)")
physical_cores=
if [[ "$cores_per_socket" =~ ^[0-9]+$ && "$sockets" =~ ^[0-9]+$ ]]; then
    physical_cores=$((cores_per_socket * sockets))
fi

average_mhz=$(
    awk -F: '
        /cpu MHz/ {
            sum += $2
            count++
        }
        END {
            if (count)
                printf "%.0f", sum / count
        }
    ' /proc/cpuinfo 2>/dev/null
)

cpu_temperature=
for input in /sys/class/hwmon/hwmon*/temp*_input; do
    [[ -r "$input" ]] || continue
    label_file=${input%_input}_label
    label=
    [[ -r "$label_file" ]] && label=$(cat "$label_file")
    case "${label,,}" in
        *package*|tctl|tdie)
            raw_temperature=$(cat "$input")
            cpu_temperature=$((raw_temperature / 1000))
            break
            ;;
    esac
done

emit cpu model "$(cpu_value "Model name")"
emit cpu vendor "$(cpu_value "Vendor ID")"
emit cpu architecture "$(cpu_value "Architecture")"
emit cpu sockets "$sockets"
emit cpu physical_cores "$physical_cores"
emit cpu logical_cpus "$logical_cpus"
emit cpu threads_per_core "$(cpu_value "Thread(s) per core")"
emit cpu current_mhz "$average_mhz"
emit cpu min_mhz "$(cpu_value "CPU min MHz")"
emit cpu max_mhz "$(cpu_value "CPU max MHz")"
emit cpu virtualization "$(cpu_value "Virtualization")"
emit cpu l1d "$(cpu_value "L1d cache")"
emit cpu l1i "$(cpu_value "L1i cache")"
emit cpu l2 "$(cpu_value "L2 cache")"
emit cpu l3 "$(cpu_value "L3 cache")"
emit cpu numa_nodes "$(cpu_value "NUMA node(s)")"
emit cpu governor "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
emit cpu temperature "$cpu_temperature"

mem_total=$(mem_kib MemTotal)
mem_free=$(mem_kib MemFree)
mem_available=$(mem_kib MemAvailable)
mem_buffers=$(mem_kib Buffers)
mem_cached=$(mem_kib Cached)
mem_reclaimable=$(mem_kib SReclaimable)
mem_shared=$(mem_kib Shmem)
swap_total=$(mem_kib SwapTotal)
swap_free=$(mem_kib SwapFree)

mem_total=${mem_total:-0}
mem_free=${mem_free:-0}
mem_available=${mem_available:-0}
mem_buffers=${mem_buffers:-0}
mem_cached=${mem_cached:-0}
mem_reclaimable=${mem_reclaimable:-0}
mem_shared=${mem_shared:-0}
swap_total=${swap_total:-0}
swap_free=${swap_free:-0}

emit memory total "$((mem_total * 1024))"
emit memory used "$(((mem_total - mem_available) * 1024))"
emit memory available "$((mem_available * 1024))"
emit memory free "$((mem_free * 1024))"
emit memory cache "$(((mem_cached + mem_reclaimable) * 1024))"
emit memory buffers "$((mem_buffers * 1024))"
emit memory shared "$((mem_shared * 1024))"
emit memory swap_total "$((swap_total * 1024))"
emit memory swap_used "$(((swap_total - swap_free) * 1024))"

while IFS= read -r line; do
    unset NAME TYPE SIZE ROTA TRAN MODEL SERIAL REV
    eval "$line"
    [[ ${TYPE:-} == disk ]] || continue
    media=SSD
    [[ ${ROTA:-0} == 1 ]] && media=HDD

    block_queue="/sys/class/block/${NAME:-}/queue"
    logical_sector=$(cat "$block_queue/logical_block_size" 2>/dev/null)
    physical_sector=$(cat "$block_queue/physical_block_size" 2>/dev/null)
    scheduler=$(
        sed -n 's/.*\[\([^]]*\)\].*/\1/p' \
            "$block_queue/scheduler" 2>/dev/null
    )
    partition_count=$(
        LC_ALL=C lsblk -ln -o TYPE "/dev/${NAME:-}" 2>/dev/null |
            awk '$1 == "part" { count++ } END { print count + 0 }'
    )
    removable=$(cat "/sys/class/block/${NAME:-}/removable" 2>/dev/null)

    emit_fields disk "${NAME:-}" "${MODEL:-}" "${SIZE:-0}" \
        "${TRAN:-}" "$media" "${SERIAL:-}" "${REV:-}" \
        "$logical_sector" "$physical_sector" "$scheduler" \
        "$partition_count" "$removable"
done < <(
    LC_ALL=C lsblk -dnbo NAME,TYPE,SIZE,ROTA,TRAN,MODEL,SERIAL,REV -P \
        2>/dev/null
)

while IFS= read -r line; do
    unset TARGET SOURCE FSTYPE SIZE USED AVAIL USE_PCT
    eval "$line"
    case "${FSTYPE:-}" in
        ""|tmpfs|devtmpfs|devpts|proc|sysfs|bpf|cgroup*|securityfs|pstore|debugfs|tracefs|configfs|fusectl|fuse.portal|fuse.gvfsd-fuse|mqueue|hugetlbfs|autofs|binfmt_misc|efivarfs|ramfs)
            continue
            ;;
    esac
    [[ ${SIZE:-0} =~ ^[0-9]+$ && ${SIZE:-0} -gt 0 ]] || continue
    emit_fields mount "${TARGET:-}" "${SOURCE:-}" "${FSTYPE:-}" \
        "${SIZE:-0}" "${USED:-0}" "${AVAIL:-0}" "${USE_PCT:-}"
done < <(LC_ALL=C findmnt -n -b -P -y \
    -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE% 2>/dev/null)

gpu_count=0
if command -v lspci >/dev/null 2>&1; then
    while IFS=$'\t' read -r address vendor gpu_name; do
        [[ -n "$address" ]] || continue
        gpu_count=$((gpu_count + 1))
        sys_device="/sys/bus/pci/devices/$address"
        driver=
        if [[ -L "$sys_device/driver" ]]; then
            driver=$(basename "$(readlink -f "$sys_device/driver")")
        fi

        boot_vga=0
        [[ -r "$sys_device/boot_vga" ]] &&
            boot_vga=$(cat "$sys_device/boot_vga")

        gpu_type=Discrete
        case "${vendor,,} ${gpu_name,,}" in
            *intel*)
                case "${gpu_name,,}" in
                    *arc\ a*|*arc\ b*|*dg1*|*dg2*) gpu_type=Discrete ;;
                    *) gpu_type=Integrated ;;
                esac
                ;;
            *amd*|*advanced\ micro\ devices*)
                bus=${address#*:}
                bus=${bus%%:*}
                if [[ "$bus" == 00 ]] ||
                   [[ "${gpu_name,,}" =~ (vega|radeon[[:space:]]graphics|rembrandt|phoenix|cezanne|renoir|picasso|raven|mendocino|strix) ]]; then
                    gpu_type=Integrated
                fi
                ;;
            *nvidia*) gpu_type=Discrete ;;
        esac

        drm_node=
        vram_bytes=0
        for card in /sys/class/drm/card[0-9]*; do
            [[ $(basename "$card") =~ ^card[0-9]+$ ]] || continue
            [[ "$(readlink -f "$card/device")" == "$(readlink -f "$sys_device")" ]] ||
                continue
            drm_node=$(basename "$card")
            if [[ -r "$card/device/mem_info_vram_total" ]]; then
                vram_bytes=$(cat "$card/device/mem_info_vram_total")
            fi
            break
        done

        driver_version=
        if [[ "${vendor,,}" == *nvidia* ]] &&
           command -v nvidia-smi >/dev/null 2>&1; then
            nvidia_data=$(
                nvidia-smi --id="$address" \
                    --query-gpu=memory.total,driver_version \
                    --format=csv,noheader,nounits 2>/dev/null |
                    head -n1
            )
            nvidia_mib=$(printf '%s' "$nvidia_data" | cut -d, -f1 | tr -d ' ')
            driver_version=$(printf '%s' "$nvidia_data" | cut -d, -f2- | sed 's/^ *//')
            if [[ "$nvidia_mib" =~ ^[0-9]+$ ]]; then
                vram_bytes=$((nvidia_mib * 1024 * 1024))
            fi
        elif [[ -r "$sys_device/driver/module/version" ]]; then
            driver_version=$(cat "$sys_device/driver/module/version")
        fi

        pci_vendor=$(cat "$sys_device/vendor" 2>/dev/null)
        pci_device=$(cat "$sys_device/device" 2>/dev/null)
        pci_id="${pci_vendor#0x}:${pci_device#0x}"
        vram_kind=Dedicated
        [[ "$gpu_type" == Integrated ]] && vram_kind=Shared

        emit_fields gpu "$address" "$vendor" "$gpu_name" "$gpu_type" \
            "$driver" "$driver_version" "$vram_bytes" "$vram_kind" \
            "$boot_vga" "$drm_node" "$pci_id"
    done < <(
        LC_ALL=C lspci -Dmm -nn 2>/dev/null |
            awk -F'"' '
                tolower($2) ~ /(vga compatible controller|3d controller|display controller)/ {
                    address = $1
                    sub(/[[:space:]]+$/, "", address)
                    printf "%s\t%s\t%s\n", address, $4, $6
                }
            '
    )
fi
emit general gpu_count "$gpu_count"
