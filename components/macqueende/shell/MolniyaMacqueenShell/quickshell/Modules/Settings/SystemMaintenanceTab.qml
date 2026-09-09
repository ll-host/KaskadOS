import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    readonly property string helperPath: Quickshell.env("MACQUEENDE_ROOT") + "/shell/MolniyaMacqueenShell/quickshell/scripts/system-maintenance.sh"

    property var systemStatus: ({})
    property bool statusLoading: false
    property bool operationRunning: false
    property string activeOperation: ""
    property string operationOutput: ""
    property string operationError: ""
    property real operationProgress: 0
    property string operationStage: ""
    property string resultMessage: ""
    property bool resultIsError: false

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    function parseFields(text) {
        const result = {};
        const lines = String(text || "").trim().split("\n");
        for (const line of lines) {
            if (!line)
                continue;
            const separator = line.indexOf("\t");
            if (separator < 0)
                continue;
            result[line.slice(0, separator)] = line.slice(separator + 1);
        }
        return result;
    }

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

    function formatTimestamp(value) {
        const seconds = Number(value || 0);
        if (!Number.isFinite(seconds) || seconds <= 0)
            return "неизвестно";
        return Qt.formatDateTime(new Date(seconds * 1000), "dd.MM.yyyy, HH:mm");
    }

    function mirrorStatusText() {
        const archDate = formatTimestamp(systemStatus.arch_mirror_mtime);
        return "Текущий список Arch Linux: " + archDate;
    }

    function refreshStatus() {
        if (statusProcess.running || operationRunning)
            return;
        statusLoading = true;
        statusProcess.running = true;
    }

    function startOperation(operation) {
        if (operationRunning)
            return;
        activeOperation = operation;
        operationOutput = "";
        operationError = "";
        operationProgress = 0;
        operationStage = "Ожидание подтверждения прав администратора";
        resultMessage = "";
        resultIsError = false;
        operationRunning = true;
        operationProcess.command = ["pkexec", helperPath, operation];
        operationProcess.running = true;
    }

    function handleOperationOutput(line) {
        const text = String(line || "").trim();
        if (!text)
            return;

        const parts = text.split("\t");
        if (parts[0] === "progress" && parts.length >= 3) {
            const percent = Number(parts[1]);
            if (Number.isFinite(percent))
                operationProgress = Math.max(0, Math.min(100, percent));
            operationStage = parts.slice(2).join(" ");
            return;
        }

        operationOutput += text + "\n";
    }

    function finishOperation(exitCode) {
        const finishedOperation = activeOperation;
        operationRunning = false;
        activeOperation = "";

        if (exitCode === 126 || exitCode === 127) {
            operationProgress = 0;
            operationStage = "";
            resultMessage = "Операция отменена.";
            resultIsError = false;
            return;
        }
        if (exitCode !== 0) {
            operationProgress = 0;
            operationStage = "";
            resultMessage = operationError.trim() || "Операция завершилась с ошибкой.";
            resultIsError = true;
            return;
        }

        operationProgress = 100;
        operationStage = "";
        const fields = parseFields(operationOutput);
        if (finishedOperation === "update-mirrors") {
            resultMessage = "Список зеркал Arch Linux обновлён. Резервная копия сохранена в "
                + (fields.backup_directory || "/var/lib/macqueende/backups/mirrors") + ".";
        } else if (finishedOperation === "clean-cache") {
            resultMessage = "Кэш очищен. Освобождено " + formatBytes(fields.cache_freed) + ".";
        }
        resultIsError = false;
        Qt.callLater(refreshStatus);
    }

    function confirmMirrorUpdate() {
        mirrorConfirm.showWithOptions({
            "title": "Обновить зеркала?",
            "message": "Reflector проверит и заменит список зеркал Arch Linux. Текущий файл сохранится в резервную копию. Пакеты и базы pacman обновляться не будут.",
            "confirmText": "Обновить",
            "cancelText": "Отмена",
            "onConfirm": () => root.startOperation("update-mirrors")
        });
    }

    function confirmCacheCleanup() {
        cacheConfirm.showWithOptions({
            "title": "Очистить кэш pacman?",
            "message": "Сейчас кэш занимает " + formatBytes(systemStatus.cache_bytes)
                + ". Будут удалены пакеты уже удалённых программ и старые версии пакетов. Для установленных пакетов сохранятся две последние версии.",
            "confirmText": "Очистить",
            "cancelText": "Отмена",
            "onConfirm": () => root.startOperation("clean-cache")
        });
    }

    Component.onCompleted: refreshStatus()

    ConfirmModal {
        id: mirrorConfirm
    }

    ConfirmModal {
        id: cacheConfirm
    }

    Process {
        id: statusProcess

        command: [root.helperPath, "status"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: root.systemStatus = root.parseFields(text)
        }

        onExited: exitCode => {
            root.statusLoading = false;
            if (exitCode !== 0) {
                root.resultMessage = "Не удалось получить сведения об обслуживании системы.";
                root.resultIsError = true;
            }
        }
    }

    Process {
        id: operationProcess

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root.handleOperationOutput(line)
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                const text = String(line || "").trim();
                if (text)
                    root.operationError += text + "\n";
            }
        }

        onExited: exitCode => Qt.callLater(() => root.finishOperation(exitCode))
    }

    component MaintenanceProgress: Column {
        id: progressView

        required property string operation

        width: parent ? parent.width : 0
        visible: root.operationRunning && root.activeOperation === operation
        spacing: Theme.spacingS

        Row {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                width: parent.width - percentLabel.width - parent.spacing
                text: root.operationStage || "Подготовка…"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            StyledText {
                id: percentLabel

                text: Math.round(root.operationProgress) + "%"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold
                color: Theme.primary
            }
        }

        M3WaveProgress {
            width: parent.width
            height: 18
            value: root.operationProgress / 100
            actualValue: value
            isPlaying: progressView.visible
            amp: 1.4
            lineWidth: 2
            wavelength: 18
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
            width: Math.min(620, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            StyledText {
                width: parent.width
                visible: !PolkitService.polkitAvailable
                text: "Служба авторизации Polkit недоступна. Операции обслуживания требуют прав администратора."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.error
                wrapMode: Text.WordWrap
            }

            SettingsCard {
                width: parent.width
                iconName: "dns"
                title: "Зеркала пакетов"
                settingKey: "systemMaintenanceMirrors"
                tags: ["system", "pacman", "mirror", "reflector", "зеркала"]

                StyledText {
                    width: parent.width
                    text: "Проверяет актуальные HTTPS-зеркала, выбирает быстрые и записывает новый список только после успешной проверки."
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    text: root.statusLoading ? "Получение информации…" : root.mirrorStatusText()
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    visible: root.systemStatus.reflector_available === "0"
                    text: "Не найден reflector. Установите пакет reflector."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                MaintenanceProgress {
                    operation: "update-mirrors"
                }

                Row {
                    width: parent.width
                    layoutDirection: I18n.isRtl ? Qt.LeftToRight : Qt.RightToLeft

                    DankButton {
                        text: root.operationRunning && root.activeOperation === "update-mirrors"
                            ? "Обновление…" : "Обновить зеркала"
                        iconName: "sync"
                        enabled: !root.operationRunning
                            && !root.statusLoading
                            && PolkitService.polkitAvailable
                            && root.systemStatus.reflector_available === "1"
                        onClicked: root.confirmMirrorUpdate()
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "cleaning_services"
                title: "Кэш пакетов"
                settingKey: "systemMaintenanceCache"
                tags: ["system", "pacman", "cache", "cleanup", "кэш", "очистка"]

                StyledText {
                    width: parent.width
                    text: "Удаляет ненужные архивы пакетов, но сохраняет две последние версии установленных пакетов для возможного отката."
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    text: root.statusLoading ? "Подсчёт размера…" : "Занято в кэше: " + root.formatBytes(root.systemStatus.cache_bytes)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    visible: root.systemStatus.paccache_available === "0"
                    text: "Не найден paccache. Установите пакет pacman-contrib."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                MaintenanceProgress {
                    operation: "clean-cache"
                }

                Row {
                    width: parent.width
                    layoutDirection: I18n.isRtl ? Qt.LeftToRight : Qt.RightToLeft

                    DankButton {
                        text: root.operationRunning && root.activeOperation === "clean-cache"
                            ? "Очистка…" : "Очистить кэш"
                        iconName: "delete_sweep"
                        enabled: !root.operationRunning
                            && !root.statusLoading
                            && PolkitService.polkitAvailable
                            && root.systemStatus.paccache_available === "1"
                        onClicked: root.confirmCacheCleanup()
                    }
                }
            }

            StyledRect {
                width: parent.width
                height: resultColumn.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                visible: root.resultMessage.length > 0 || root.operationRunning

                Row {
                    id: resultColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    DankIcon {
                        name: root.operationRunning ? "sync" : (root.resultIsError ? "error" : "check_circle")
                        size: Theme.iconSize
                        color: root.operationRunning ? Theme.primary : (root.resultIsError ? Theme.error : Theme.success)
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        width: parent.width - Theme.iconSize - parent.spacing
                        text: root.operationRunning
                            ? (root.activeOperation === "update-mirrors" ? "Проверка и сортировка зеркал…" : "Очистка кэша пакетов…")
                            : root.resultMessage
                        font.pixelSize: Theme.fontSizeMedium
                        color: root.resultIsError ? Theme.error : Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
