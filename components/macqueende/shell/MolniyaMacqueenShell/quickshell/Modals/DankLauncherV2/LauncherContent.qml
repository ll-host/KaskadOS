pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets

FocusScope {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property var parentModal: null
    property string viewModeContext: "spotlight"
    property alias searchField: searchField
    property alias controller: controller
    property alias resultsList: resultsList
    property alias actionPanel: actionPanel
    readonly property alias activeContextMenu: contextMenu
    property var transientSurfaceTracker: null
    readonly property bool softwareMode: controller.searchMode === "store" || controller.searchMode === "installed"
    readonly property bool windowsMode: controller.searchMode === "windows"
    readonly property bool specialMode: softwareMode || windowsMode

    property bool editMode: false
    property var editingApp: null
    property string editAppId: ""
    readonly property bool _blurActive: Theme.blurForegroundLayers || Theme.transparentBlurLayers
    readonly property real _launcherFieldAlpha: {
        if (Theme.transparentBlurLayers)
            return 0.28;
        if (Theme.blurForegroundLayers)
            return Math.max(Theme.popupTransparency, 0.62);
        return Theme.popupTransparency;
    }
    readonly property color _launcherSearchFieldColor: Theme.withAlpha(Theme.surfaceContainerHigh, _launcherFieldAlpha)
    readonly property color _launcherSearchBorderColor: Theme.withAlpha(Theme.outline, _blurActive ? 0.16 : Theme.layerOutlineOpacity)
    readonly property color _launcherSearchFocusedBorderColor: Theme.withAlpha(Theme.primary, _blurActive ? 0.72 : 1.0)

    function resetScroll() {
        resultsList.resetScroll();
    }

    function focusSearchField() {
        searchField.forceActiveFocus();
    }

    function closeTransientUi() {
        transientSurfaceTracker?.closeAll?.();
        actionPanel.hide();
        root.enabled = true;
    }

    function openEditMode(app) {
        if (!app)
            return;
        editingApp = app;
        editAppId = app.id || app.execString || app.exec || "";
        editMode = true;
    }

    function closeEditMode() {
        editMode = false;
        editingApp = null;
        editAppId = "";
        Qt.callLater(() => searchField.forceActiveFocus());
    }

    function showContextMenu(item, x, y, fromKeyboard) {
        if (!item)
            return;
        if (!contextMenu.hasContextMenuActions(item))
            return;
        contextMenu.show(x, y, item, fromKeyboard);
    }

    anchors.fill: parent
    focus: true

    Controller {
        id: controller
        active: root.parentModal ? (root.parentModal.spotlightOpen || root.parentModal.isClosing) : true
        viewModeContext: root.viewModeContext

        onItemExecuted: {
            if (root.parentModal) {
                root.parentModal.hide();
            }
            if (SettingsData.spotlightCloseNiriOverview && NiriService.inOverview) {
                NiriService.toggleOverview();
            }
        }
    }

    LauncherContextMenu {
        id: contextMenu
        parent: root
        controller: root.controller
        searchField: root.searchField
        parentHandler: root
        transientSurfaceTracker: root.transientSurfaceTracker

        onEditAppRequested: app => {
            root.openEditMode(app);
        }
    }

    Connections {
        target: root.parentModal
        ignoreUnknownSignals: true

        function onSpotlightOpenChanged() {
            if (!root.parentModal?.spotlightOpen)
                root.closeTransientUi();
        }

        function onContentVisibleChanged() {
            if (!root.parentModal?.contentVisible)
                root.closeTransientUi();
        }
    }

    Keys.onPressed: event => {
        if (editMode) {
            if (event.key === Qt.Key_Escape) {
                closeEditMode();
                event.accepted = true;
            }
            return;
        }

        if (root.softwareMode) {
            switch (event.key) {
            case Qt.Key_Escape:
                if (root.parentModal)
                    root.parentModal.hide();
                event.accepted = true;
                return;
            case Qt.Key_Down:
                softwareCatalogView.selectNext();
                event.accepted = true;
                return;
            case Qt.Key_Up:
                softwareCatalogView.selectPrevious();
                event.accepted = true;
                return;
            case Qt.Key_Return:
            case Qt.Key_Enter:
                softwareCatalogView.activateSelected();
                event.accepted = true;
                return;
            }
        }

        if (root.windowsMode) {
            switch (event.key) {
            case Qt.Key_Escape:
                if (root.parentModal)
                    root.parentModal.hide();
                event.accepted = true;
                return;
            case Qt.Key_Down:
                windowsAppsView.selectNext();
                event.accepted = true;
                return;
            case Qt.Key_Up:
                windowsAppsView.selectPrevious();
                event.accepted = true;
                return;
            case Qt.Key_Return:
            case Qt.Key_Enter:
                windowsAppsView.activateSelected();
                event.accepted = true;
                return;
            }
        }

        var hasCtrl = event.modifiers & Qt.ControlModifier;
        var hasAlt = event.modifiers & Qt.AltModifier;
        event.accepted = true;

        switch (event.key) {
        case Qt.Key_Escape:
            if (actionPanel.expanded) {
                actionPanel.hide();
                return;
            }
            if (root.parentModal)
                root.parentModal.hide();
            return;
        case Qt.Key_Backspace:
            event.accepted = false;
            return;
        case Qt.Key_Down:
            controller.selectNext();
            return;
        case Qt.Key_Up:
            controller.selectPrevious();
            return;
        case Qt.Key_PageDown:
            controller.selectPageDown(8);
            return;
        case Qt.Key_PageUp:
            controller.selectPageUp(8);
            return;
        case Qt.Key_Right:
            if (controller.getCurrentSectionViewMode() !== "list") {
                controller.selectRight();
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_Left:
            if (controller.getCurrentSectionViewMode() !== "list") {
                controller.selectLeft();
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_J:
            if (hasCtrl) {
                controller.selectNext();
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_K:
            if (hasCtrl) {
                controller.selectPrevious();
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_L:
            if (hasCtrl) {
                if (controller.getCurrentSectionViewMode() !== "list") {
                    controller.selectRight();
                }
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_H:
            if (hasCtrl) {
                if (controller.getCurrentSectionViewMode() !== "list") {
                    controller.selectLeft();
                }
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_N:
            if (hasCtrl) {
                controller.selectNextSection();
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_P:
            if (hasCtrl) {
                controller.selectPreviousSection();
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_Tab:
            if (actionPanel.hasActions) {
                actionPanel.expanded ? actionPanel.cycleAction() : actionPanel.show();
            }
            return;
        case Qt.Key_Backtab:
            if (actionPanel.expanded)
                actionPanel.hide();
            return;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (event.modifiers & Qt.ShiftModifier) {
                controller.pasteSelected();
                return;
            }
            if (actionPanel.expanded && actionPanel.selectedActionIndex > 0) {
                actionPanel.executeSelectedAction();
            } else {
                controller.executeSelected();
            }
            return;
        case Qt.Key_Menu:
        case Qt.Key_F10:
            if (contextMenu.hasContextMenuActions(controller.selectedItem)) {
                var scenePos = resultsList.getSelectedItemPosition();
                var localPos = root.mapFromItem(null, scenePos.x, scenePos.y);
                showContextMenu(controller.selectedItem, localPos.x, localPos.y, true);
            }
            return;
        case Qt.Key_1:
            if (hasCtrl || hasAlt) {
                controller.setMode("all");
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_2:
            if (hasCtrl || hasAlt) {
                controller.setMode("apps");
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_3:
            if (hasCtrl || hasAlt) {
                controller.setMode("store");
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_4:
            if (hasCtrl || hasAlt) {
                controller.setMode("installed");
                return;
            }
            event.accepted = false;
            return;
        case Qt.Key_5:
            if (hasCtrl || hasAlt) {
                controller.setMode("windows");
                return;
            }
            event.accepted = false;
            return;
        default:
            event.accepted = false;
        }
    }

    Item {
        id: contentHolder
        anchors.fill: parent
        visible: !editMode

        readonly property bool inverted: (root.parentModal?.frameOwnsConnectedChrome ?? false) && (root.parentModal?.resolvedConnectedBarSide === "top")
        readonly property bool _connectedArcAtHeader: inverted && !(root.parentModal?.launcherArcExtenderActive ?? false)

        Item {
            id: footerBar
            readonly property bool _connectedBottomEmerge: (root.parentModal?.frameOwnsConnectedChrome ?? false) && (root.parentModal?.resolvedConnectedBarSide === "bottom")
            readonly property bool _connectedArcAtFooter: _connectedBottomEmerge && !(root.parentModal?.launcherArcExtenderActive ?? false)
            readonly property bool showFooter: SettingsData.dankLauncherV2Size !== "micro" && SettingsData.dankLauncherV2ShowFooter
            readonly property bool compactKeyboardHints: width < 720

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: root.parentModal?.borderWidth ?? 1
            anchors.rightMargin: root.parentModal?.borderWidth ?? 1
            y: contentHolder.inverted ? 0 : (parent.height - height - (_connectedBottomEmerge ? 0 : (root.parentModal?.borderWidth ?? 1)))
            height: showFooter ? ((_connectedArcAtFooter || contentHolder._connectedArcAtHeader) ? 76 : 36) : 0
            visible: showFooter
            clip: true

            Rectangle {
                anchors.fill: parent
                anchors.topMargin: -Theme.cornerRadius
                // In connected mode the launcher provides the surface so update the toolbar for arcs
                visible: !(root.parentModal?.frameOwnsConnectedChrome ?? false) && !root._blurActive
                color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                radius: Theme.cornerRadius
            }

            Row {
                id: modeButtonsRow
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                layoutDirection: I18n.isRtl ? Qt.RightToLeft : Qt.LeftToRight
                spacing: Theme.spacingXXS

                Repeater {
                    model: [
                        {
                            id: "all",
                            label: I18n.tr("All"),
                            icon: "search"
                        },
                        {
                            id: "apps",
                            label: I18n.tr("Apps"),
                            icon: "apps"
                        },
                        {
                            id: "store",
                            label: "Каталог",
                            icon: "storefront"
                        },
                        {
                            id: "installed",
                            label: "Установлено",
                            icon: "inventory_2"
                        },
                        {
                            id: "windows",
                            label: "Windows",
                            icon: "window"
                        }
                    ]

                    Rectangle {
                        required property var modelData
                        required property int index

                        width: buttonContent.width + Theme.spacingM * 2
                        height: 28
                        radius: Theme.cornerRadius
                        color: controller.searchMode === modelData.id ? Theme.buttonBg : modeArea.containsMouse ? Theme.surfaceContainerHighest : Theme.withAlpha(Theme.surfaceContainerHighest, 0)

                        Row {
                            id: buttonContent
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: modelData.icon
                                size: 14
                                color: controller.searchMode === modelData.id ? Theme.buttonText : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: footerBar.width >= 920 || controller.searchMode === modelData.id
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                color: controller.searchMode === modelData.id ? Theme.buttonText : Theme.surfaceText
                            }
                        }

                        MouseArea {
                            id: modeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: controller.setMode(modelData.id)
                        }
                    }
                }
            }

            Row {
                id: hintsRow
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                layoutDirection: I18n.isRtl ? Qt.RightToLeft : Qt.LeftToRight
                spacing: Theme.spacingM

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: footerBar.compactKeyboardHints ? "↑↓" : "↑↓ " + I18n.tr("nav")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: footerBar.compactKeyboardHints ? "↵" : "↵ " + I18n.tr("Open")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: footerBar.compactKeyboardHints ? "Tab" : "Tab " + I18n.tr("Actions")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    visible: actionPanel.hasActions
                }
            }
        }

        Row {
            id: searchRow
            spacing: Theme.spacingS
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            y: contentHolder.inverted ? (parent.height - height - Theme.spacingM) : Theme.spacingM

            Rectangle {
                id: pluginBadge
                visible: controller.activePluginName.length > 0
                width: visible ? pluginBadgeContent.implicitWidth + Theme.spacingM : 0
                height: searchField.height
                radius: 16
                color: Theme.primary

                Row {
                    id: pluginBadgeContent
                    anchors.centerIn: parent
                    spacing: Theme.spacingXS

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "extension"
                        size: 14
                        color: Theme.primaryText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: controller.activePluginName
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primaryText
                    }
                }

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }
            }

            DankTextField {
                id: searchField
                width: parent.width - (pluginBadge.visible ? pluginBadge.width + Theme.spacingS : 0)
                cornerRadius: Theme.cornerRadius
                backgroundColor: root._launcherSearchFieldColor
                normalBorderColor: root._launcherSearchBorderColor
                focusedBorderColor: root._launcherSearchFocusedBorderColor
                borderWidth: 1
                focusedBorderWidth: 2
                leftIconName: controller.activePluginId ? "extension" : controller.searchQuery.startsWith("/") ? "folder" : "search"
                leftIconSize: Theme.iconSize
                leftIconColor: Theme.surfaceVariantText
                leftIconFocusedColor: Theme.primary
                showClearButton: true
                textColor: Theme.surfaceText
                font.pixelSize: Theme.fontSizeLarge
                enabled: root.parentModal ? (root.parentModal.spotlightOpen || root.parentModal.isClosing) : true
                placeholderText: root.softwareMode ? "Найти приложение или пакет"
                    : root.windowsMode ? "Найти Windows-приложение" : ""
                ignoreUpDownKeys: true
                ignoreTabKeys: true
                keyForwardTargets: [root]

                onTextChanged: {
                    controller.setSearchQuery(text);
                    if (actionPanel.expanded) {
                        actionPanel.hide();
                    }
                }

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        if (root.parentModal) {
                            root.parentModal.hide();
                        }
                        event.accepted = true;
                    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                        if (actionPanel.expanded && actionPanel.selectedActionIndex > 0) {
                            actionPanel.executeSelectedAction();
                        } else {
                            controller.executeSelected();
                        }
                        event.accepted = true;
                    }
                }
            }
        }

        Item {
            id: contentStack
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: contentHolder.inverted ? footerBar.bottom : searchRow.bottom
            anchors.bottom: contentHolder.inverted ? searchRow.top : footerBar.top
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            anchors.topMargin: contentHolder.inverted && !footerBar.showFooter ? Theme.spacingM : contentStack.gap
            anchors.bottomMargin: contentHolder.inverted ? contentStack.gap : 0
            readonly property real gap: Theme.spacingXS
            clip: false

            Item {
                id: resultsSlot
                width: parent.width
                anchors.top: parent.top
                anchors.bottom: actionPanel.top
                anchors.bottomMargin: actionPanel.height > 0 || !contentHolder.inverted ? contentStack.gap : 0
                opacity: {
                    if (!root.parentModal)
                        return 1;
                    if (Theme.isDirectionalEffect && root.parentModal.isClosing)
                        return 1;
                    return root.parentModal.isClosing ? 0 : 1;
                }

                ResultsList {
                    id: resultsList
                    anchors.fill: parent
                    visible: !root.specialMode
                    controller: root.controller
                    leadingSectionHeaderAtBottom: contentHolder.inverted
                    transientSurfaceTracker: root.transientSurfaceTracker

                    onItemRightClicked: (index, item, sceneX, sceneY) => {
                        if (item && contextMenu.hasContextMenuActions(item)) {
                            var localPos = root.mapFromItem(null, sceneX, sceneY);
                            root.showContextMenu(item, localPos.x, localPos.y, false);
                        }
                    }
                }

                SoftwareCatalogView {
                    id: softwareCatalogView
                    anchors.fill: parent
                    visible: root.softwareMode
                    focus: visible
                    mode: controller.searchMode
                    query: controller.searchQuery
                    onLocalPackageRequested: localPackageBrowser.open()
                }

                WindowsAppsView {
                    id: windowsAppsView
                    anchors.fill: parent
                    visible: root.windowsMode
                    focus: visible
                    query: controller.searchQuery
                    onExecutableRequested: windowsExecutableBrowser.open()
                }
            }

            ActionPanel {
                id: actionPanel
                width: parent.width
                anchors.bottom: parent.bottom
                selectedItem: controller.selectedItem
                controller: controller
                visible: !root.specialMode
            }
        }
    }

    FileBrowserModal {
        id: localPackageBrowser
        browserTitle: "Установить пакет Arch Linux"
        browserIcon: "package_2"
        browserType: "generic"
        showHiddenFiles: true
        fileExtensions: ["*.pkg.tar.zst", "*.pkg.tar.xz", "*.pkg.tar.gz"]
        onFileSelected: path => {
            SoftwareService.installLocal(path);
            close();
        }
    }

    FileBrowserModal {
        id: windowsExecutableBrowser
        browserTitle: "Открыть Windows-приложение"
        browserIcon: "window"
        browserType: "generic"
        showHiddenFiles: true
        fileExtensions: ["*.exe", "*.EXE"]
        onFileSelected: path => {
            WindowsAppsService.openExecutable(path);
            close();
        }
    }

    Connections {
        target: controller
        function onSelectedItemChanged() {
            if (actionPanel.expanded && !actionPanel.hasActions) {
                actionPanel.hide();
            }
        }
        function onSearchQueryRequested(query) {
            searchField.text = query;
        }
        function onModeChanged() {
            extFilterField.text = "";
        }
    }

    Loader {
        id: editLoader
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        active: root.editMode
        visible: active
        focus: root.editMode

        sourceComponent: AppEditView {
            focus: true
            editingApp: root.editingApp
            editAppId: root.editAppId
            onCloseRequested: root.closeEditMode()
        }

        onLoaded: item.loadOverride()
    }
}
