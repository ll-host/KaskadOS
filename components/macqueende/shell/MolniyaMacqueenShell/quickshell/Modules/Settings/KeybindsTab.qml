pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Macqueen.Ipc
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets

Item {
    id: keybindsTab

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property var parentModal: null
    property string selectedCategory: ""
    property string searchQuery: ""
    property string requestedSearchQuery: ""
    property string expandedKey: ""
    property bool showingNewBind: false

    property int _lastDataVersion: -1
    property var _cachedCategories: []
    property var _filteredBinds: []
    property real _savedScrollY: 0
    property bool _preserveScroll: false
    property string _editingKey: ""
    property bool microphoneShortcutRecording: false

    function stopMicrophoneShortcutRecording() {
        if (!microphoneShortcutRecording)
            return;
        microphoneShortcutRecording = false;
        Macqueen.setShortcutCaptureActive(false);
    }

    Component.onDestruction: stopMicrophoneShortcutRecording()

    Connections {
        target: Macqueen
        function onShortcutCaptured(shortcut) {
            if (!keybindsTab.microphoneShortcutRecording)
                return;
            keybindsTab.stopMicrophoneShortcutRecording();
            if (!Macqueen.setMicrophoneShortcut(shortcut))
                ToastService.showError("Не удалось назначить клавишу микрофона", shortcut);
        }
    }

    function _updateFiltered() {
        const allBinds = KeybindsService.getFlatBinds();
        if (!searchQuery && !selectedCategory) {
            _filteredBinds = allBinds;
            return;
        }

        const q = searchQuery.toLowerCase();
        const isOverrideFilter = selectedCategory === "__overrides__";
        const result = [];

        for (let i = 0; i < allBinds.length; i++) {
            const group = allBinds[i];
            if (q) {
                let keyMatch = false;
                for (let k = 0; k < group.keys.length; k++) {
                    if (group.keys[k].key.toLowerCase().indexOf(q) !== -1) {
                        keyMatch = true;
                        break;
                    }
                }
                if (!keyMatch && group.desc.toLowerCase().indexOf(q) === -1 && group.action.toLowerCase().indexOf(q) === -1)
                    continue;
            }
            if (isOverrideFilter) {
                let hasOverride = false;
                for (let k = 0; k < group.keys.length; k++) {
                    if (group.keys[k].isOverride) {
                        hasOverride = true;
                        break;
                    }
                }
                if (!hasOverride)
                    continue;
            } else if (selectedCategory && group.category !== selectedCategory) {
                continue;
            }
            result.push(group);
        }
        _filteredBinds = result;
    }

    function _updateCategories() {
        _cachedCategories = ["__overrides__"].concat(KeybindsService.getCategories());
    }

    function getCategoryLabel(cat) {
        if (cat === "__overrides__")
            return I18n.tr("Overrides");
        return cat;
    }

    function toggleExpanded(action) {
        expandedKey = expandedKey === action ? "" : action;
    }

    function startNewBind() {
        if (KeybindsService.readOnly) {
            KeybindsService.showHyprlandReadOnlyWarning();
            return;
        }
        showingNewBind = true;
        expandedKey = "";
    }

    function cancelNewBind() {
        showingNewBind = false;
    }

    function saveNewBind(bindData) {
        KeybindsService.saveBind("", bindData);
        _editingKey = bindData.key;
        expandedKey = bindData.action;
    }

    function confirmRemoveBind(key, remainingKey) {
        removeBindConfirm.showWithOptions({
            title: I18n.tr("Remove Shortcut?"),
            message: KeybindsService.currentProvider === "hyprland" ? I18n.tr("Remove the shortcut %1? An unbind entry will be saved to dms/binds-user.lua so it stays removed across DMS updates.").arg(key) : I18n.tr("Remove the shortcut %1?").arg(key),
            confirmText: I18n.tr("Remove"),
            confirmColor: Theme.primary,
            onConfirm: () => {
                KeybindsService.removeBind(key);
                keybindsTab._editingKey = remainingKey;
            }
        });
    }

    function confirmResetBind(key, remainingKey) {
        removeBindConfirm.showWithOptions({
            title: I18n.tr("Reset to default"),
            message: I18n.tr("Drop your override for %1 so the DMS default action re-applies?").arg(key),
            confirmText: I18n.tr("Reset"),
            confirmColor: Theme.primary,
            onConfirm: () => {
                KeybindsService.resetBind(key);
                keybindsTab._editingKey = remainingKey;
            }
        });
    }

    function _onSaveSuccess() {
        if (showingNewBind) {
            showingNewBind = false;
            selectedCategory = "";
        }
    }

    function scrollToTop() {
        flickable.contentY = 0;
    }

    function _scrollToExpandedItem() {
        for (let i = 0; i < bindsRepeater.count; i++) {
            const item = bindsRepeater.itemAt(i);
            if (item && item.modelData.action === expandedKey) {
                const itemY = item.mapToItem(flickable.contentItem, 0, 0).y;
                const itemH = item.height;
                const viewH = flickable.height;
                if (itemY >= flickable.contentY && itemY + itemH <= flickable.contentY + viewH)
                    return;
                flickable.contentY = Math.max(0, Math.min(itemY - viewH / 4, flickable.contentHeight - viewH));
                return;
            }
        }
        flickable.contentY = _savedScrollY;
    }

    Timer {
        id: searchDebounce
        interval: 150
        onTriggered: keybindsTab._updateFiltered()
    }

    ConfirmModal {
        id: removeBindConfirm
    }

    Connections {
        target: KeybindsService
        function onBindsLoaded() {
            const savedY = keybindsTab._savedScrollY;
            const wasPreserving = keybindsTab._preserveScroll;
            keybindsTab._lastDataVersion = KeybindsService._dataVersion;
            keybindsTab._updateCategories();
            keybindsTab._updateFiltered();
            keybindsTab._preserveScroll = false;
            if (wasPreserving) {
                if (keybindsTab.expandedKey)
                    Qt.callLater(keybindsTab._scrollToExpandedItem);
                else
                    Qt.callLater(() => flickable.contentY = savedY);
            }
        }
        function onBindSaved(key) {
            keybindsTab._savedScrollY = flickable.contentY;
            keybindsTab._preserveScroll = true;
        }
        function onBindSaveCompleted(success) {
            if (success)
                keybindsTab._onSaveSuccess();
        }
        function onBindRemoved(key) {
            keybindsTab._savedScrollY = flickable.contentY;
            keybindsTab._preserveScroll = true;
        }
    }

    function _ensureCurrentProvider() {
        if (!KeybindsService.available)
            return;
        const cachedProvider = KeybindsService.keybinds?.provider;
        const targetProvider = KeybindsService.currentProvider;
        if (cachedProvider !== targetProvider || KeybindsService._dataVersion === 0) {
            KeybindsService.loadBinds();
            return;
        }
        if (_lastDataVersion !== KeybindsService._dataVersion) {
            _lastDataVersion = KeybindsService._dataVersion;
            _updateCategories();
            _updateFiltered();
        }
    }

    function _applyRequestedSearch() {
        if (!requestedSearchQuery)
            return;
        const query = requestedSearchQuery;
        selectedCategory = "";
        searchField.text = query;
        searchQuery = query;
        _updateFiltered();
        if (parentModal?.keybindSearchQuery === query)
            parentModal.keybindSearchQuery = "";
        Qt.callLater(scrollToTop);
    }

    Component.onCompleted: {
        _ensureCurrentProvider();
        Qt.callLater(_applyRequestedSearch);
    }

    onRequestedSearchQueryChanged: Qt.callLater(_applyRequestedSearch)

    onVisibleChanged: {
        if (!visible) {
            stopMicrophoneShortcutRecording();
            return;
        }
        _ensureCurrentProvider();
        Qt.callLater(() => {
            _applyRequestedSearch();
            scrollToTop();
        });
    }

    DankFlickable {
        id: flickable
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: contentColumn.implicitHeight

        Column {
            id: contentColumn
            width: flickable.width
            spacing: Theme.spacingL
            topPadding: Theme.spacingXL
            bottomPadding: Theme.spacingXL

            StyledRect {
                width: Math.min(650, parent.width - Theme.spacingL * 2)
                height: headerSection.implicitHeight + Theme.spacingL * 2
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 0

                Column {
                    id: headerSection
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        DankIcon {
                            name: "keyboard"
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - Theme.iconSize - Theme.spacingM * 2
                            spacing: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                text: I18n.tr("Keyboard Shortcuts")
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }

                            StyledText {
                                readonly property string bindsFile: KeybindsService.currentProvider === "niri" ? "dms/binds.kdl" : KeybindsService.currentProvider === "hyprland" ? "dms/binds-user.lua" : "dms/binds.conf"
                                text: KeybindsService.readOnly ? I18n.tr("Hyprland conf mode is read-only in Settings") : I18n.tr("Click any shortcut to edit. Changes save to %1").arg(bindsFile)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        DankTextField {
                            id: searchField
                            width: parent.width - addButton.width - Theme.spacingM
                            placeholderText: I18n.tr("Search keybinds...")
                            leftIconName: "search"
                            onTextChanged: {
                                keybindsTab.searchQuery = text;
                                searchDebounce.restart();
                            }
                        }

                        DankActionButton {
                            id: addButton
                            width: searchField.height
                            height: searchField.height
                            circular: false
                            iconName: "add"
                            iconSize: Theme.iconSize
                            iconColor: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                            enabled: !keybindsTab.showingNewBind && !KeybindsService.readOnly
                            opacity: enabled ? 1 : 0.5
                            onClicked: keybindsTab.startNewBind()
                        }
                    }
                }
            }

            StyledRect {
                width: Math.min(650, parent.width - Theme.spacingL * 2)
                height: microphoneShortcutSection.implicitHeight + Theme.spacingL * 2
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 0
                visible: Macqueen.available && Macqueen.protocolVersion >= 13

                Column {
                    id: microphoneShortcutSection
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    StyledText {
                        text: "Микрофон"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: "По умолчанию — V. Она срабатывает и при обычном наборе текста; здесь можно записать сочетание клавиш."
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    Row {
                        spacing: Theme.spacingM

                        FocusScope {
                            id: microphoneShortcutField
                            width: 170
                            height: 40
                            activeFocusOnTab: true
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    keybindsTab.stopMicrophoneShortcutRecording();
                                    event.accepted = true;
                                }
                            }
                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.cornerRadius
                                color: keybindsTab.microphoneShortcutRecording ? Theme.primaryContainer : Theme.surfaceContainerHighest
                                border.width: 1
                                border.color: keybindsTab.microphoneShortcutRecording ? Theme.primary : Theme.outlineVariant
                            }
                            StyledText {
                                anchors.centerIn: parent
                                text: keybindsTab.microphoneShortcutRecording ? "Нажмите сочетание…" : (Macqueen.microphoneShortcut || "V")
                                color: Theme.surfaceText
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (keybindsTab.microphoneShortcutRecording)
                                        keybindsTab.stopMicrophoneShortcutRecording();
                                    else {
                                        keybindsTab.microphoneShortcutRecording = true;
                                        microphoneShortcutField.forceActiveFocus();
                                        Macqueen.setShortcutCaptureActive(true);
                                    }
                                }
                            }
                        }

                        DankButton {
                            text: "Сбросить на V"
                            buttonHeight: 40
                            backgroundColor: "transparent"
                            textColor: Theme.surfaceVariantText
                            onClicked: {
                                keybindsTab.stopMicrophoneShortcutRecording();
                                Macqueen.setMicrophoneShortcut("V");
                            }
                        }
                    }

                    Repeater {
                        model: [
                            { value: "toggle", label: "Переключение", detail: "Нажать — выключить; нажать снова — вернуть прежнюю громкость" },
                            { value: "holdToTalk", label: "Включён, пока удерживаю", detail: "Без нажатия микрофон выключен" },
                            { value: "holdToMute", label: "Выключен, пока удерживаю", detail: "После отпускания прежняя громкость вернётся" }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            width: microphoneShortcutSection.width
                            height: modeText.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: SessionData.microphoneShortcutMode === modelData.value ? Theme.primaryContainer : Theme.surfaceContainerHighest

                            Column {
                                id: modeText
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: Theme.spacingM
                                StyledText { text: modelData.label; color: Theme.surfaceText; font.weight: Font.Medium }
                                StyledText { text: modelData.detail; color: Theme.surfaceVariantText; wrapMode: Text.WordWrap; width: parent.width }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: SessionData.set("microphoneShortcutMode", modelData.value)
                            }
                        }
                    }
                }
            }

            StyledRect {
                id: warningBox
                width: Math.min(650, parent.width - Theme.spacingL * 2)
                height: warningSection.implicitHeight + Theme.spacingL * 2
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.cornerRadius

                readonly property var status: KeybindsService.dmsStatus
                readonly property bool showLegacy: KeybindsService.readOnly
                readonly property bool showWarning: !showLegacy && status.included && status.overriddenBy > 0
                readonly property bool showSetup: !showLegacy && !status.included

                color: (showLegacy || showWarning || showSetup) ? Theme.withAlpha(Theme.primary, 0.15) : Theme.withAlpha(Theme.primary, 0)
                border.color: (showLegacy || showWarning || showSetup) ? Theme.withAlpha(Theme.primary, 0.3) : Theme.withAlpha(Theme.primary, 0)
                border.width: 1
                visible: (showLegacy || showWarning || showSetup) && !KeybindsService.loading

                Column {
                    id: warningSection
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        DankIcon {
                            name: warningBox.showWarning ? "info" : "warning"
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - Theme.iconSize - (fixButton.visible ? fixButton.width + Theme.spacingM : 0) - Theme.spacingM
                            spacing: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                text: {
                                    if (warningBox.showLegacy)
                                        return I18n.tr("Hyprland conf mode");
                                    if (warningBox.showSetup)
                                        return I18n.tr("First Time Setup");
                                    if (warningBox.showWarning)
                                        return I18n.tr("Possible Override Conflicts");
                                    return "";
                                }
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.primary
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }

                            StyledText {
                                text: {
                                    if (warningBox.showLegacy)
                                        return I18n.tr("This install is still using hyprland.conf. Run dms setup to migrate before changing these settings.");
                                    if (warningBox.showSetup)
                                        return I18n.tr("Click 'Setup' to create %1 and add include to your compositor config.").arg("dms/binds");
                                    if (warningBox.showWarning) {
                                        const count = warningBox.status.overriddenBy;
                                        return I18n.ntr("%1 DMS bind may be overridden by config binds that come after the include.", "%1 DMS binds may be overridden by config binds that come after the include.", count).arg(count);
                                    }
                                    return "";
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }
                        }

                        DankButton {
                            id: fixButton
                            visible: !warningBox.showLegacy && warningBox.showSetup
                            text: KeybindsService.fixing ? I18n.tr("Setting up...") : I18n.tr("Setup")
                            backgroundColor: Theme.primary
                            textColor: Theme.primaryText
                            enabled: !KeybindsService.fixing
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: KeybindsService.fixDmsBindsInclude()
                        }
                    }
                }
            }

            StyledRect {
                width: Math.min(650, parent.width - Theme.spacingL * 2)
                height: categorySection.implicitHeight + Theme.spacingL * 2
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 0

                Column {
                    id: categorySection
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingS

                        Rectangle {
                            readonly property real chipHeight: allChip.implicitHeight + Theme.spacingM
                            width: allChip.implicitWidth + Theme.spacingL
                            height: chipHeight
                            radius: chipHeight / 2
                            color: !keybindsTab.selectedCategory ? Theme.primary : Theme.surfaceContainerHighest

                            StyledText {
                                id: allChip
                                text: I18n.tr("All")
                                font.pixelSize: Theme.fontSizeSmall
                                color: !keybindsTab.selectedCategory ? Theme.primaryText : Theme.surfaceVariantText
                                anchors.centerIn: parent
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    keybindsTab.selectedCategory = "";
                                    keybindsTab._updateFiltered();
                                }
                            }
                        }

                        Repeater {
                            model: keybindsTab._cachedCategories

                            delegate: Rectangle {
                                required property string modelData
                                required property int index

                                readonly property real chipHeight: catText.implicitHeight + Theme.spacingM
                                width: catText.implicitWidth + Theme.spacingL
                                height: chipHeight
                                radius: chipHeight / 2
                                color: keybindsTab.selectedCategory === modelData ? Theme.primary : (modelData === "__overrides__" ? Theme.withAlpha(Theme.primary, 0.15) : Theme.surfaceContainerHighest)

                                StyledText {
                                    id: catText
                                    text: keybindsTab.getCategoryLabel(modelData)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: keybindsTab.selectedCategory === modelData ? Theme.primaryText : (modelData === "__overrides__" ? Theme.primary : Theme.surfaceVariantText)
                                    anchors.centerIn: parent
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        keybindsTab.selectedCategory = modelData;
                                        keybindsTab._updateFiltered();
                                    }
                                }
                            }
                        }
                    }
                }
            }

            StyledRect {
                width: Math.min(650, parent.width - Theme.spacingL * 2)
                height: newBindSection.implicitHeight + Theme.spacingL * 2
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.color: Theme.outlineVariant
                border.width: 1
                visible: keybindsTab.showingNewBind

                Column {
                    id: newBindSection
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        DankIcon {
                            name: "add"
                            size: Theme.iconSize
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: I18n.tr("New Keybind")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    KeybindItem {
                        width: parent.width
                        isNew: true
                        isExpanded: true
                        bindData: ({
                                keys: [
                                    {
                                        key: "",
                                        source: "dms",
                                        isOverride: true
                                    }
                                ],
                                action: "",
                                desc: ""
                            })
                        panelWindow: keybindsTab.parentModal
                        readOnly: KeybindsService.readOnly
                        onSaveBind: (originalKey, newData) => keybindsTab.saveNewBind(newData)
                        onCancelEdit: keybindsTab.cancelNewBind()
                    }
                }
            }

            StyledRect {
                width: Math.min(650, parent.width - Theme.spacingL * 2)
                height: bindsListHeader.implicitHeight + Theme.spacingL * 2
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 0

                Column {
                    id: bindsListHeader
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        DankIcon {
                            name: "list"
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: {
                                if (KeybindsService.loading)
                                    return I18n.tr("Shortcuts");
                                const count = keybindsTab._filteredBinds.length;
                                return count === 1 ? I18n.tr("Shortcut (%1)").arg(count) : I18n.tr("Shortcuts (%1)").arg(count);
                            }
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM
                        visible: KeybindsService.loading

                        DankIcon {
                            id: loadingIcon
                            name: "sync"
                            size: 20
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                            smoothTransform: KeybindsService.loading

                            RotationAnimator on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: KeybindsService.loading
                            }
                        }

                        StyledText {
                            text: I18n.tr("Loading keybinds...")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    StyledText {
                        text: I18n.tr("No keybinds found")
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                        visible: !KeybindsService.loading && keybindsTab._filteredBinds.length === 0
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingXS

                Repeater {
                    id: bindsRepeater
                    model: ScriptModel {
                        values: keybindsTab._filteredBinds
                        objectProp: "action"
                    }

                    delegate: Item {
                        required property var modelData
                        required property int index

                        width: parent.width
                        height: bindItem.height

                        KeybindItem {
                            id: bindItem
                            width: Math.min(650, parent.width - Theme.spacingL * 2)
                            anchors.horizontalCenter: parent.horizontalCenter
                            bindData: modelData
                            isExpanded: keybindsTab.expandedKey === modelData.action
                            panelWindow: keybindsTab.parentModal
                            readOnly: KeybindsService.readOnly
                            onToggleExpand: keybindsTab.toggleExpanded(modelData.action)
                            onSaveBind: (originalKey, newData) => {
                                KeybindsService.saveBind(originalKey, newData);
                                keybindsTab._editingKey = newData.key;
                                keybindsTab.expandedKey = newData.action;
                            }
                            onRemoveBind: key => {
                                const remainingKey = bindItem.keys.find(k => k.key !== key)?.key ?? "";
                                keybindsTab.confirmRemoveBind(key, remainingKey);
                            }
                            onResetBind: key => {
                                const remainingKey = bindItem.keys.find(k => k.key !== key)?.key ?? "";
                                keybindsTab.confirmResetBind(key, remainingKey);
                            }
                            onIsExpandedChanged: {
                                if (!isExpanded || !keybindsTab._editingKey)
                                    return;
                                const keyExists = keys.some(k => k.key === keybindsTab._editingKey);
                                if (keyExists) {
                                    restoreKey = keybindsTab._editingKey;
                                    keybindsTab._editingKey = "";
                                }
                            }

                            onKeysChanged: {
                                if (!isExpanded || !keybindsTab._editingKey)
                                    return;
                                const keyExists = keys.some(k => k.key === keybindsTab._editingKey);
                                if (keyExists) {
                                    restoreKey = keybindsTab._editingKey;
                                    keybindsTab._editingKey = "";
                                }
                            }

                            Connections {
                                target: keybindsTab
                                function on_EditingKeyChanged() {
                                    if (!bindItem.isExpanded || !keybindsTab._editingKey)
                                        return;
                                    const keyExists = bindItem.keys.some(k => k.key === keybindsTab._editingKey);
                                    if (keyExists) {
                                        bindItem.restoreKey = keybindsTab._editingKey;
                                        keybindsTab._editingKey = "";
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
