import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets

Item {
    id: root

    property bool loading: true
    property string loadError: ""
    property string processError: ""
    property var generalInfo: ({})
    property var cpuInfo: ({})
    property var memoryInfo: ({})
    property var disks: []
    property var mounts: []
    property var gpus: []

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    function formatBytes(value) {
        const bytes = Number(value || 0);
        if (!Number.isFinite(bytes) || bytes <= 0)
            return "0 Б";
        const units = ["Б", "КиБ", "МиБ", "ГиБ", "ТиБ"];
        let amount = bytes;
        let unit = 0;
        while (amount >= 1024 && unit < units.length - 1) {
            amount /= 1024;
            unit++;
        }
        const digits = unit >= 3 ? 1 : (unit === 0 ? 0 : 1);
        return amount.toFixed(digits) + " " + units[unit];
    }

    function formatFrequency(mhz) {
        const value = Number(mhz || 0);
        if (!Number.isFinite(value) || value <= 0)
            return "";
        if (value >= 1000)
            return (value / 1000).toFixed(2) + " ГГц";
        return Math.round(value) + " МГц";
    }

    function localizedInstallMethod(method) {
        switch (method || "") {
        case "binary":
            return "Готовый rolling-бинарник";
        case "source":
            return "Сборка из исходников";
        case "development":
            return "Рабочая копия разработчика";
        default:
            return method || "";
        }
    }

    function localizedReleaseChannel(channel) {
        switch (String(channel || "").toLowerCase()) {
        case "stable":
            return "Стабильный";
        case "beta":
            return "Бета";
        case "alpha":
            return "Альфа";
        case "development":
            return "Разработка";
        default:
            return channel || "";
        }
    }

    function localizedGpuType(type) {
        return type === "Integrated" ? "Встроенная" : "Дискретная";
    }

    function formatUptime(secondsValue) {
        let seconds = Math.max(0, Math.floor(Number(secondsValue || 0)));
        if (!Number.isFinite(seconds) || seconds <= 0)
            return "";
        const days = Math.floor(seconds / 86400);
        seconds %= 86400;
        const hours = Math.floor(seconds / 3600);
        seconds %= 3600;
        const minutes = Math.floor(seconds / 60);
        const parts = [];
        if (days > 0)
            parts.push(days + " д.");
        if (hours > 0)
            parts.push(hours + " ч.");
        parts.push(minutes + " мин.");
        return parts.join(" ");
    }

    function localizedCache(value) {
        return String(value || "").replace(/\s*\((\d+)\s+instances?\)/i,
                                            " · $1 экз.");
    }

    function localizedScheduler(scheduler, transport) {
        const value = String(scheduler || "").trim();
        if (value === "none") {
            if (String(transport || "").toLowerCase() === "nvme")
                return "Не используется — нормально для NVMe";
            return "Не используется";
        }
        return value;
    }

    function addRow(rows, label, value) {
        if (value === undefined || value === null || String(value).trim() === "")
            return;
        rows.push({
            "label": label,
            "value": String(value)
        });
    }

    function systemRows() {
        const rows = [];
        addRow(rows, "Операционная система", generalInfo.os);
        addRow(rows, "Имя компьютера", generalInfo.hostname);
        addRow(rows, "Ядро", generalInfo.kernel);
        addRow(rows, "Архитектура", generalInfo.architecture);
        addRow(rows, "Графический протокол", generalInfo.session);
        addRow(rows, "Окружение рабочего стола", generalInfo.compositor || "MacqueenDE");
        addRow(rows, "Канал обновлений", localizedReleaseChannel(generalInfo.release_channel));
        addRow(rows, "Дата выпуска", generalInfo.release_date);
        addRow(rows, "Способ установки", localizedInstallMethod(generalInfo.install_method));
        addRow(rows, "Пакетный менеджер", generalInfo.package_manager);
        addRow(rows, "AUR-помощник", generalInfo.package_helper);
        if (generalInfo.package_count)
            addRow(rows, "Установлено пакетов", generalInfo.package_count);
        addRow(rows, "Время работы системы", formatUptime(generalInfo.uptime_seconds));
        return rows;
    }

    function cpuRows() {
        const rows = [];
        addRow(rows, "Модель", cpuInfo.model);
        addRow(rows, "Производитель", cpuInfo.vendor);
        addRow(rows, "Архитектура", cpuInfo.architecture);
        addRow(rows, "Сокетов", cpuInfo.sockets);
        addRow(rows, "Физических ядер", cpuInfo.physical_cores);
        addRow(rows, "Логических потоков", cpuInfo.logical_cpus);
        addRow(rows, "Потоков на ядро", cpuInfo.threads_per_core);
        addRow(rows, "Текущая средняя частота", formatFrequency(cpuInfo.current_mhz));
        const minFrequency = formatFrequency(cpuInfo.min_mhz);
        const maxFrequency = formatFrequency(cpuInfo.max_mhz);
        if (minFrequency || maxFrequency)
            addRow(rows, "Диапазон частот", minFrequency + " — " + maxFrequency);
        addRow(rows, "Регулятор частоты", cpuInfo.governor);
        if (cpuInfo.temperature)
            addRow(rows, "Температура пакета", cpuInfo.temperature + " °C");
        addRow(rows, "Аппаратная виртуализация", cpuInfo.virtualization);
        addRow(rows, "Кэш L1 данных", localizedCache(cpuInfo.l1d));
        addRow(rows, "Кэш L1 инструкций", localizedCache(cpuInfo.l1i));
        addRow(rows, "Кэш L2", localizedCache(cpuInfo.l2));
        addRow(rows, "Кэш L3", localizedCache(cpuInfo.l3));
        addRow(rows, "NUMA-узлов", cpuInfo.numa_nodes);
        return rows;
    }

    function memoryRows() {
        const rows = [];
        const total = Number(memoryInfo.total || 0);
        const used = Number(memoryInfo.used || 0);
        const percent = total > 0 ? Math.round(used / total * 100) : 0;
        addRow(rows, "Всего установлено", formatBytes(total));
        addRow(rows, "Используется сейчас", formatBytes(used) + " · " + percent + "%");
        addRow(rows, "Доступно приложениям", formatBytes(memoryInfo.available));
        addRow(rows, "Полностью свободно", formatBytes(memoryInfo.free));
        addRow(rows, "Файловый кэш", formatBytes(memoryInfo.cache));
        addRow(rows, "Буферы ядра", formatBytes(memoryInfo.buffers));
        addRow(rows, "Разделяемая память", formatBytes(memoryInfo.shared));
        const swapTotal = Number(memoryInfo.swap_total || 0);
        if (swapTotal > 0)
            addRow(rows, "Swap", formatBytes(memoryInfo.swap_used) + " из " + formatBytes(swapTotal));
        else
            addRow(rows, "Swap", "Не настроен");
        return rows;
    }

    function diskRows(disk) {
        const rows = [];
        addRow(rows, "Устройство", "/dev/" + disk.device);
        addRow(rows, "Модель", disk.model || "Неизвестная модель");
        addRow(rows, "Ёмкость", formatBytes(disk.size));
        addRow(rows, "Тип накопителя", disk.media);
        addRow(rows, "Интерфейс", (disk.transport || "не определён").toUpperCase());
        addRow(rows, "Серийный номер", disk.serial);
        addRow(rows, "Версия прошивки", disk.revision);
        if (disk.logicalSector)
            addRow(rows, "Логический сектор", formatBytes(disk.logicalSector));
        if (disk.physicalSector)
            addRow(rows, "Физический сектор", formatBytes(disk.physicalSector));
        addRow(rows, "Планировщик ввода-вывода",
               localizedScheduler(disk.scheduler, disk.transport));
        addRow(rows, "Разделов", disk.partitionCount);
        addRow(rows, "Съёмный накопитель", disk.removable ? "Да" : "Нет");
        return rows;
    }

    function mountRows() {
        const rows = [];
        for (const mount of mounts) {
            const used = formatBytes(mount.used);
            const size = formatBytes(mount.size);
            const available = formatBytes(mount.available);
            const details = used + " из " + size
                + " · свободно " + available
                + " · " + mount.percent
                + " · " + mount.fstype
                + " · " + mount.source;
            addRow(rows, mount.target, details);
        }
        return rows;
    }

    function gpuRows(gpu) {
        const rows = [];
        addRow(rows, "Тип", localizedGpuType(gpu.type));
        addRow(rows, "Производитель", gpu.vendor);
        addRow(rows, "Модель", gpu.name);
        addRow(rows, "Драйвер ядра", gpu.driver);
        addRow(rows, "Версия драйвера", gpu.driverVersion);
        if (gpu.vramKind === "Shared")
            addRow(rows, "Видеопамять", "Общая системная память");
        else if (Number(gpu.vram || 0) > 0)
            addRow(rows, "Видеопамять", formatBytes(gpu.vram));
        else
            addRow(rows, "Видеопамять", "Не удалось определить");
        addRow(rows, "PCI-адрес", gpu.address);
        addRow(rows, "PCI ID", gpu.pciId);
        addRow(rows, "DRM-устройство", gpu.drmNode ? "/dev/dri/" + gpu.drmNode : "");
        addRow(rows, "Основная при загрузке", gpu.primary ? "Да" : "Нет");
        return rows;
    }

    function parseReport(text) {
        const general = {};
        const cpu = {};
        const memory = {};
        const diskList = [];
        const mountList = [];
        const gpuList = [];
        const lines = String(text || "").split("\n");

        for (const line of lines) {
            if (!line.trim())
                continue;
            const fields = line.split("\t");
            const section = fields[0] || "";
            if (section === "general" && fields.length >= 3) {
                general[fields[1]] = fields.slice(2).join("\t");
            } else if (section === "cpu" && fields.length >= 3) {
                cpu[fields[1]] = fields.slice(2).join("\t");
            } else if (section === "memory" && fields.length >= 3) {
                memory[fields[1]] = fields.slice(2).join("\t");
            } else if (section === "disk" && fields.length >= 13) {
                diskList.push({
                    "device": fields[1],
                    "model": fields[2],
                    "size": Number(fields[3] || 0),
                    "transport": fields[4],
                    "media": fields[5],
                    "serial": fields[6],
                    "revision": fields[7],
                    "logicalSector": Number(fields[8] || 0),
                    "physicalSector": Number(fields[9] || 0),
                    "scheduler": fields[10],
                    "partitionCount": fields[11],
                    "removable": fields[12] === "1"
                });
            } else if (section === "mount" && fields.length >= 8) {
                mountList.push({
                    "target": fields[1],
                    "source": fields[2],
                    "fstype": fields[3],
                    "size": Number(fields[4] || 0),
                    "used": Number(fields[5] || 0),
                    "available": Number(fields[6] || 0),
                    "percent": fields[7]
                });
            } else if (section === "gpu" && fields.length >= 12) {
                gpuList.push({
                    "address": fields[1],
                    "vendor": fields[2],
                    "name": fields[3],
                    "type": fields[4],
                    "driver": fields[5],
                    "driverVersion": fields[6],
                    "vram": Number(fields[7] || 0),
                    "vramKind": fields[8],
                    "primary": fields[9] === "1",
                    "drmNode": fields[10],
                    "pciId": fields[11]
                });
            }
        }

        generalInfo = general;
        cpuInfo = cpu;
        memoryInfo = memory;
        disks = diskList;
        mounts = mountList;
        gpus = gpuList;
        loading = false;
        loadError = "";
    }

    function refresh() {
        if (systemInfoProcess.running)
            return;
        processError = "";
        loadError = "";
        loading = true;
        systemInfoProcess.command = [Theme.shellDir + "/scripts/system-info.sh"];
        systemInfoProcess.running = true;
    }

    Component.onCompleted: refresh()

    component DetailRow: Item {
        id: detailRow

        property string label: ""
        property string value: ""

        width: parent ? parent.width : 0
        visible: value.length > 0
        height: visible ? Math.max(detailLabel.implicitHeight, detailValue.implicitHeight) : 0

        StyledText {
            id: detailLabel

            width: Math.min(190, detailRow.width * 0.36)
            text: detailRow.label
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        StyledText {
            id: detailValue

            anchors.left: detailLabel.right
            anchors.leftMargin: Theme.spacingL
            anchors.right: parent.right
            text: detailRow.value
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignLeft
        }
    }

    component InfoCard: StyledRect {
        id: infoCard

        property string title: ""
        property string subtitle: ""
        property string iconName: "info"
        property var rows: []

        width: parent ? parent.width : 0
        height: cardColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 0

        Column {
            id: cardColumn

            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingM

                DankIcon {
                    name: infoCard.iconName
                    size: Theme.iconSize + 2
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    width: parent.width - Theme.iconSize - Theme.spacingL
                    spacing: 2
                    anchors.verticalCenter: parent.verticalCenter

                    StyledText {
                        width: parent.width
                        text: infoCard.title
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        width: parent.width
                        visible: infoCard.subtitle.length > 0
                        text: infoCard.subtitle
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.outline
                opacity: 0.45
            }

            Repeater {
                model: infoCard.rows

                delegate: DetailRow {
                    required property var modelData

                    width: cardColumn.width
                    label: modelData.label || ""
                    value: modelData.value || ""
                }
            }
        }
    }

    Process {
        id: systemInfoProcess

        running: false

        stdout: StdioCollector {
            onStreamFinished: root.parseReport(text)
        }

        stderr: StdioCollector {
            onStreamFinished: root.processError = String(text || "").trim()
        }

        onExited: exitCode => {
            root.loading = false;
            if (exitCode !== 0) {
                root.loadError = root.processError
                    || "Не удалось получить информацию о системе";
            }
        }
    }

    DankFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn

            topPadding: 4
            width: Math.min(720, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingL

            StyledRect {
                width: parent.width
                height: 132
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 0

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "MacqueenDE"
                        font.pixelSize: 32
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: versionText.implicitWidth + Theme.spacingL * 2
                        height: 32
                        radius: 16
                        color: Theme.primaryHover

                        StyledText {
                            id: versionText

                            anchors.centerIn: parent
                            text: "Версия " + (root.generalInfo.version || "…")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.primary
                        }
                    }
                }

                DankActionButton {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingM
                    iconName: "refresh"
                    iconSize: 20
                    iconColor: Theme.primary
                    enabled: !root.loading
                    onClicked: root.refresh()
                }
            }

            StyledRect {
                visible: root.loading || root.loadError.length > 0
                width: parent.width
                height: visible ? statusRow.implicitHeight + Theme.spacingL * 2 : 0
                radius: Theme.cornerRadius
                color: root.loadError.length > 0 ? Theme.errorContainer : Theme.surfaceContainerHigh
                border.width: 0

                Row {
                    id: statusRow

                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    DankIcon {
                        name: root.loadError.length > 0 ? "error" : "sync"
                        size: Theme.iconSize
                        color: root.loadError.length > 0 ? Theme.error : Theme.primary
                    }

                    StyledText {
                        width: parent.width - Theme.iconSize - Theme.spacingM
                        text: root.loadError.length > 0
                            ? root.loadError
                            : "Собираем подробную информацию об оборудовании…"
                        font.pixelSize: Theme.fontSizeMedium
                        color: root.loadError.length > 0 ? Theme.error : Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }
                }
            }

            InfoCard {
                title: "Система"
                iconName: "computer"
                rows: root.systemRows()
            }

            InfoCard {
                title: "Процессор"
                subtitle: root.cpuInfo.model || ""
                iconName: "memory"
                rows: root.cpuRows()
            }

            InfoCard {
                title: "Оперативная память"
                subtitle: root.formatBytes(root.memoryInfo.total)
                iconName: "memory_alt"
                rows: root.memoryRows()
            }

            Repeater {
                model: root.disks

                delegate: InfoCard {
                    required property var modelData
                    required property int index

                    width: mainColumn.width
                    title: root.disks.length > 1
                        ? "Физический диск " + (index + 1)
                        : "Физический диск"
                    subtitle: modelData.model || modelData.device
                    iconName: "hard_drive"
                    rows: root.diskRows(modelData)
                }
            }

            InfoCard {
                title: "Разделы и хранилища"
                iconName: "storage"
                rows: root.mountRows()
            }

            Repeater {
                model: root.gpus

                delegate: InfoCard {
                    required property var modelData
                    required property int index

                    width: mainColumn.width
                    title: root.gpus.length > 1
                        ? "Видеокарта " + (index + 1) + " · " + root.localizedGpuType(modelData.type)
                        : "Видеокарта · " + root.localizedGpuType(modelData.type)
                    subtitle: modelData.name
                    iconName: modelData.type === "Integrated" ? "developer_board" : "videogame_asset"
                    rows: root.gpuRows(modelData)
                }
            }

            InfoCard {
                visible: !root.loading && root.gpus.length === 0
                title: "Графика"
                iconName: "videogame_asset"
                rows: [{
                    "label": "Статус",
                    "value": "Видеокарты не обнаружены. Для определения требуется пакет pciutils."
                }]
            }
        }
    }
}
