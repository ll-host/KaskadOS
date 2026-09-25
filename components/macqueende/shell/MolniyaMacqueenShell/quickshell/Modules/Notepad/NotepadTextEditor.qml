pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import Macqueen.Ipc
import qs.Common
import qs.Services
import qs.Widgets
import "NotepadLogic.js" as NotepadLogic

Column {
    id: root

    property alias text: textArea.text
    property alias textArea: textArea
    property bool contentLoaded: false
    property string lastSavedContent: ""
    property var currentTab: NotepadStorageService.tabs.length > NotepadStorageService.currentTabIndex ? NotepadStorageService.tabs[NotepadStorageService.currentTabIndex] : null
    property bool searchVisible: false
    property string searchQuery: ""
    property var searchMatches: []
    property int currentMatchIndex: -1
    property int matchCount: 0
    property int loadRequestId: 0
    property bool ignoreNextExternalChange: false
    property bool watcherReloadPending: false
    property bool externalWatchPaused: false
    property bool inPopout: false
    property bool surfaceVisible: true
    // Tab ids are Date.now() timestamps (~1.78e12) which overflow a 32-bit `int`,
    // corrupting the value (e.g. -946062153) and breaking buffer keying. `var`
    // holds the full JS-safe integer.
    property var loadedTabId: -1
    property bool applyingShared: false
    property bool showPathInfo: false
    property string previewMode: "edit"
    property bool annotationsApplying: false
    property bool bookmarksVisible: false
    property var pendingAnnotationsTabId: -1
    property var pendingAnnotations: null
    readonly property bool splitPreviewAvailable: inPopout && width >= 760
    readonly property bool markdownDocument: {
        const path = currentFilePath().toLowerCase();
        return path.endsWith(".md") || path.endsWith(".markdown");
    }

    function currentFilePath() {
        if (!currentTab)
            return "";
        return currentTab.isTemporary ? (NotepadStorageService.baseDir + "/" + currentTab.filePath) : currentTab.filePath;
    }

    function currentDocumentBaseUrl() {
        const path = currentFilePath();
        const slash = path.lastIndexOf('/');
        return slash >= 0 ? Paths.toFileUrl(path.substring(0, slash + 1)) : "";
    }

    signal saveRequested
    signal openRequested
    signal newRequested
    signal escapePressed
    signal contentChanged
    signal settingsRequested
    signal popoutRequested
    signal dockRequested
    signal conflictDetected(string diskContent)
    signal autoSaveRequested
    signal imageRequested

    onSplitPreviewAvailableChanged: {
        if (!splitPreviewAvailable && previewMode === "split")
            previewMode = "edit";
    }

    component EditorContextMenuItem: MenuItem {
        id: menuItem

        property string iconName: ""
        property string shortcutText: ""

        implicitWidth: 220
        implicitHeight: 38
        leftPadding: Theme.spacingS
        rightPadding: Theme.spacingS

        contentItem: RowLayout {
            spacing: Theme.spacingS
            opacity: menuItem.enabled ? 1 : 0.38

            DankIcon {
                Layout.preferredWidth: Theme.iconSize
                name: menuItem.iconName
                size: Theme.iconSizeSmall
                color: Theme.surfaceText
            }

            StyledText {
                Layout.fillWidth: true
                text: menuItem.text
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeMedium
                verticalAlignment: Text.AlignVCenter
            }

            StyledText {
                visible: menuItem.shortcutText.length > 0
                text: menuItem.shortcutText
                color: Theme.surfaceTextSecondary
                font.pixelSize: Theme.fontSizeSmall
                verticalAlignment: Text.AlignVCenter
            }
        }

        background: Rectangle {
            radius: Theme.cornerRadius / 2
            color: menuItem.highlighted && menuItem.enabled ? Theme.primaryHoverLight : "transparent"
        }
    }

    function applyEdit(edit) {
        if (!edit || !edit.handled)
            return false;
        textArea.remove(edit.start, edit.end);
        if (edit.replacement && edit.replacement.length > 0)
            textArea.insert(edit.start, edit.replacement);
        textArea.cursorPosition = edit.cursor;
        return true;
    }

    function wrapSelection(prefix, suffix, placeholder) {
        const start = textArea.selectionStart;
        const end = textArea.selectionEnd;
        const selected = start < end ? textArea.selectedText : (placeholder || "текст");
        const replacement = prefix + selected + suffix;
        textArea.remove(start, end);
        textArea.insert(start, replacement);
        textArea.select(start + prefix.length, start + prefix.length + selected.length);
        textArea.forceActiveFocus();
    }

    function prefixCurrentLine(prefix) {
        const bounds = NotepadLogic.lineBounds(textArea.text, textArea.cursorPosition);
        textArea.insert(bounds.start, prefix);
        textArea.cursorPosition += prefix.length;
        textArea.forceActiveFocus();
    }

    function insertAtCursor(value) {
        const start = textArea.selectionStart;
        const end = textArea.selectionEnd;
        textArea.remove(start, end);
        textArea.insert(start, value);
        textArea.cursorPosition = start + value.length;
        textArea.forceActiveFocus();
    }

    function insertImagePath(path, alt) {
        insertAtCursor(NotepadLogic.markdownImage(alt, path));
    }

    function cyclePreviewMode() {
        if (!splitPreviewAvailable) {
            previewMode = previewMode === "preview" ? "edit" : "preview";
            return;
        }
        previewMode = previewMode === "edit" ? "split" : (previewMode === "split" ? "preview" : "edit");
    }

    function chooseTextColor() {
        if (textArea.selectionStart === textArea.selectionEnd) {
            ToastService.showInfo(I18n.tr("Select text first"));
            return;
        }
        const start = textArea.selectionStart;
        const end = textArea.selectionEnd;
        PopoutService.colorPickerModal.selectedColor = Theme.primary;
        PopoutService.colorPickerModal.pickerTitle = I18n.tr("Text Color");
        PopoutService.colorPickerModal.onColorSelectedCallback = function (color) {
            documentController.applyTextColor(start, end, color);
        };
        PopoutService.showColorPicker();
    }

    function toggleBookmark() {
        if (documentController.hasBookmarkAt(textArea.cursorPosition)) {
            documentController.toggleBookmark(textArea.cursorPosition, Theme.primary);
            return;
        }
        const position = textArea.cursorPosition;
        PopoutService.colorPickerModal.selectedColor = Theme.primary;
        PopoutService.colorPickerModal.pickerTitle = I18n.tr("Bookmark Color");
        PopoutService.colorPickerModal.onColorSelectedCallback = function (color) {
            documentController.toggleBookmark(position, color);
            bookmarksVisible = true;
        };
        PopoutService.showColorPicker();
    }

    function loadAnnotationsForCurrentTab() {
        const tabId = currentTab ? currentTab.id : -1;
        NotepadStorageService.loadDocumentAnnotations(NotepadStorageService.currentTabIndex, annotations => {
            if (!currentTab || currentTab.id !== tabId)
                return;
            annotationsApplying = true;
            documentController.setAnnotations(annotations || NotepadStorageService.emptyAnnotations());
            annotationsApplying = false;
        });
    }

    function hasUnsavedChanges() {
        if (!currentTab || !contentLoaded) {
            return false;
        }

        if (currentTab.isTemporary) {
            return textArea.text.length > 0;
        }
        return textArea.text !== lastSavedContent;
    }

    function commitLiveBuffer() {
        if (loadedTabId < 0 || !contentLoaded)
            return;
        flushAnnotations();
        NotepadStorageService.setSessionBuffer(loadedTabId, textArea.text, lastSavedContent);
    }

    function flushAnnotations() {
        annotationSaveTimer.stop();
        const tabIndex = NotepadStorageService.tabIndexById(pendingAnnotationsTabId);
        if (tabIndex >= 0 && pendingAnnotations)
            NotepadStorageService.saveDocumentAnnotations(tabIndex, pendingAnnotations);
        pendingAnnotationsTabId = -1;
        pendingAnnotations = null;
    }

    function loadCurrentTabContent() {
        if (!currentTab)
            return;
        const requestedTabId = currentTab.id;
        const requestId = ++loadRequestId;
        contentLoaded = false;
        NotepadStorageService.loadTabContent(NotepadStorageService.currentTabIndex, content => {
            const activeTab = NotepadStorageService.tabs.length > NotepadStorageService.currentTabIndex ? NotepadStorageService.tabs[NotepadStorageService.currentTabIndex] : null;
            if (requestId !== loadRequestId || !activeTab || activeTab.id !== requestedTabId)
                return;

            const buffer = NotepadStorageService.getSessionBuffer(requestedTabId);
            if (buffer !== undefined) {
                applyingShared = true;
                lastSavedContent = buffer.baseline;
                textArea.text = buffer.content;
                applyingShared = false;
                loadedTabId = requestedTabId;
                contentLoaded = true;
                applyDiskContent(content);
                loadAnnotationsForCurrentTab();
                return;
            }

            applyingShared = true;
            lastSavedContent = content;
            textArea.text = content;
            applyingShared = false;
            loadedTabId = requestedTabId;
            contentLoaded = true;
            loadAnnotationsForCurrentTab();
        });
    }

    function saveCurrentTabContent() {
        if (!currentTab || !contentLoaded)
            return;
        if (!currentTab.isTemporary)
            return;
        NotepadStorageService.saveTabContent(NotepadStorageService.currentTabIndex, textArea.text);
        lastSavedContent = textArea.text;
        NotepadStorageService.clearSessionBuffer(loadedTabId);
    }

    function autoSaveToSession() {
        commitLiveBuffer();
        if (!currentTab || !contentLoaded)
            return;
        if (currentTab.isTemporary) {
            saveCurrentTabContent();
        } else if (SettingsData.notepadAutoSave) {
            root.autoSaveRequested();
        }
    }

    function syncFromDisk() {
        if (!currentTab)
            return;
        loadCurrentTabContent();
    }

    function applyDiskContent(diskContent) {
        if (diskContent === undefined || diskContent === null)
            return;
        if (diskContent === textArea.text) {
            lastSavedContent = diskContent;
            return;
        }
        if (diskContent === lastSavedContent) {
            return;
        }
        if (textArea.text === lastSavedContent) {
            reloadFromDisk(diskContent);
        } else if (surfaceVisible) {
            conflictDetected(diskContent);
        }
    }

    function reloadFromDisk(diskContent) {
        applyingShared = true;
        contentLoaded = false;
        textArea.text = diskContent;
        lastSavedContent = diskContent;
        contentLoaded = true;
        applyingShared = false;
        NotepadStorageService.clearSessionBuffer(loadedTabId);
    }

    function setTextDocumentLineHeight() {
        return;
    }

    property string lastTextForLineModel: ""
    property var lineModel: []

    function updateLineModel() {
        if (!SettingsData.notepadShowLineNumbers) {
            lineModel = [];
            lastTextForLineModel = "";
            return;
        }

        if (textArea.text !== lastTextForLineModel || lineModel.length === 0) {
            lastTextForLineModel = textArea.text;
            lineModel = textArea.text.split('\n');
        }
    }

    function performSearch() {
        let matches = [];
        currentMatchIndex = -1;

        if (!searchQuery || searchQuery.length === 0) {
            searchMatches = [];
            matchCount = 0;
            textArea.select(0, 0);
            return;
        }

        const text = textArea.text;
        const query = searchQuery.toLowerCase();
        let index = 0;

        while (index < text.length) {
            const foundIndex = text.toLowerCase().indexOf(query, index);
            if (foundIndex === -1)
                break;
            matches.push({
                start: foundIndex,
                end: foundIndex + searchQuery.length
            });
            index = foundIndex + 1;
        }

        searchMatches = matches;
        matchCount = matches.length;

        if (matchCount > 0) {
            currentMatchIndex = 0;
            highlightCurrentMatch();
        } else {
            textArea.select(0, 0);
        }
    }

    function highlightCurrentMatch() {
        if (currentMatchIndex >= 0 && currentMatchIndex < searchMatches.length) {
            const match = searchMatches[currentMatchIndex];

            textArea.cursorPosition = match.start;
            textArea.moveCursorSelection(match.end, TextEdit.SelectCharacters);

            const flickable = textArea.parent;
            if (flickable && flickable.contentY !== undefined) {
                const lineHeight = textArea.font.pixelSize * 1.5;
                const approxLine = textArea.text.substring(0, match.start).split('\n').length;
                const targetY = approxLine * lineHeight - flickable.height / 2;
                flickable.contentY = Math.max(0, Math.min(targetY, flickable.contentHeight - flickable.height));
            }
        }
    }

    function findNext() {
        if (matchCount === 0 || searchMatches.length === 0)
            return;
        currentMatchIndex = (currentMatchIndex + 1) % matchCount;
        highlightCurrentMatch();
    }

    function findPrevious() {
        if (matchCount === 0 || searchMatches.length === 0)
            return;
        currentMatchIndex = currentMatchIndex <= 0 ? matchCount - 1 : currentMatchIndex - 1;
        highlightCurrentMatch();
    }

    function showSearch() {
        searchVisible = true;
        Qt.callLater(() => {
            searchField.forceActiveFocus();
        });
    }

    function hideSearch() {
        searchVisible = false;
        searchQuery = "";
        searchMatches = [];
        matchCount = 0;
        currentMatchIndex = -1;
        textArea.select(0, 0);
        textArea.forceActiveFocus();
    }

    Component {
        id: clipboardCopyProcComp
        Process {
            property string content: ""
            command: ["sh", "-c", "printf '%s' \"$CONTENT\" | dms clipboard copy"]
            environment: ({
                    "CONTENT": content
                })
        }
    }

    spacing: Theme.spacingM

    NotepadDocumentController {
        id: documentController
        textDocument: textArea.textDocument
        markdownEnabled: root.markdownDocument
        onAnnotationsChanged: {
            if (!root.annotationsApplying && root.contentLoaded) {
                root.pendingAnnotationsTabId = root.loadedTabId;
                root.pendingAnnotations = documentController.annotations();
                annotationSaveTimer.restart();
            }
        }
    }

    Menu {
        id: editorContextMenu

        parent: root
        width: 228
        padding: Theme.spacingXS
        modal: false
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        onClosed: Qt.callLater(() => textArea.forceActiveFocus())

        background: Rectangle {
            color: Theme.floatingSurface
            radius: Theme.cornerRadius
            border.color: BlurService.borderColor
            border.width: BlurService.borderWidth
        }

        EditorContextMenuItem {
            text: I18n.tr("Undo")
            iconName: "undo"
            shortcutText: "Ctrl+Z"
            enabled: textArea.canUndo
            onTriggered: textArea.undo()
        }

        EditorContextMenuItem {
            text: I18n.tr("Redo")
            iconName: "redo"
            shortcutText: "Ctrl+Shift+Z"
            enabled: textArea.canRedo
            onTriggered: textArea.redo()
        }

        MenuSeparator {
            implicitHeight: Theme.spacingM
            contentItem: Rectangle {
                implicitHeight: 1
                color: Theme.outlineMedium
            }
        }

        EditorContextMenuItem {
            text: I18n.tr("Cut")
            iconName: "content_cut"
            shortcutText: "Ctrl+X"
            enabled: textArea.selectionStart !== textArea.selectionEnd
            onTriggered: textArea.cut()
        }

        EditorContextMenuItem {
            text: I18n.tr("Copy")
            iconName: "content_copy"
            shortcutText: "Ctrl+C"
            enabled: textArea.selectionStart !== textArea.selectionEnd
            onTriggered: textArea.copy()
        }

        EditorContextMenuItem {
            text: I18n.tr("Paste")
            iconName: "content_paste"
            shortcutText: "Ctrl+V"
            enabled: textArea.canPaste
            onTriggered: textArea.paste()
        }

        EditorContextMenuItem {
            text: I18n.tr("Delete")
            iconName: "delete"
            enabled: textArea.selectionStart !== textArea.selectionEnd
            onTriggered: textArea.remove(textArea.selectionStart, textArea.selectionEnd)
        }

        MenuSeparator {
            implicitHeight: Theme.spacingM
            contentItem: Rectangle {
                implicitHeight: 1
                color: Theme.outlineMedium
            }
        }

        EditorContextMenuItem {
            text: I18n.tr("Select All")
            iconName: "select_all"
            shortcutText: "Ctrl+A"
            enabled: textArea.length > 0
            onTriggered: textArea.selectAll()
        }
    }

    StyledRect {
        id: searchBar
        width: parent.width
        height: 48
        visible: searchVisible
        opacity: searchVisible ? 1 : 0
        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
        border.color: searchField.activeFocus ? Theme.primary : Theme.outlineMedium
        border.width: searchField.activeFocus ? 2 : 1
        radius: Theme.cornerRadius

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingS

            // Search icon
            DankIcon {
                Layout.alignment: Qt.AlignVCenter
                name: "search"
                size: Theme.iconSize - 2
                color: searchField.activeFocus ? Theme.primary : Theme.surfaceVariantText
            }

            // Search input field
            TextInput {
                id: searchField
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                height: 32
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                clip: true

                Component.onCompleted: {
                    text = root.searchQuery;
                }

                Connections {
                    target: root
                    function onSearchQueryChanged() {
                        if (searchField.text !== root.searchQuery) {
                            searchField.text = root.searchQuery;
                        }
                    }
                }

                onTextChanged: {
                    if (root.searchQuery !== text) {
                        root.searchQuery = text;
                        root.performSearch();
                    }
                }
                Keys.onEscapePressed: event => {
                    root.hideSearch();
                    event.accepted = true;
                }
                Keys.onReturnPressed: event => {
                    if (event.modifiers & Qt.ShiftModifier) {
                        root.findPrevious();
                    } else {
                        root.findNext();
                    }
                    event.accepted = true;
                }
                Keys.onEnterPressed: event => {
                    if (event.modifiers & Qt.ShiftModifier) {
                        root.findPrevious();
                    } else {
                        root.findNext();
                    }
                    event.accepted = true;
                }
            }

            // Placeholder text
            StyledText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: I18n.tr("Find in note...")
                font: searchField.font
                color: Theme.surfaceTextSecondary
                visible: searchField.text.length === 0 && !searchField.activeFocus
                Layout.leftMargin: -(searchField.width - 20) // Position over the input field
            }

            // Match count display
            StyledText {
                Layout.alignment: Qt.AlignVCenter
                text: matchCount > 0 ? "%1/%2".arg(currentMatchIndex + 1).arg(matchCount) : searchQuery.length > 0 ? I18n.tr("No matches") : ""
                font.pixelSize: Theme.fontSizeSmall
                color: matchCount > 0 ? Theme.primary : Theme.surfaceTextMedium
                visible: searchQuery.length > 0
                Layout.rightMargin: Theme.spacingS
            }

            // Navigation buttons
            DankActionButton {
                id: prevButton
                Layout.alignment: Qt.AlignVCenter
                iconName: "keyboard_arrow_up"
                iconSize: Theme.iconSize
                iconColor: matchCount > 0 ? Theme.surfaceText : Theme.surfaceTextAlpha
                enabled: matchCount > 0
                onClicked: root.findPrevious()
            }

            DankActionButton {
                id: nextButton
                Layout.alignment: Qt.AlignVCenter
                iconName: "keyboard_arrow_down"
                iconSize: Theme.iconSize
                iconColor: matchCount > 0 ? Theme.surfaceText : Theme.surfaceTextAlpha
                enabled: matchCount > 0
                onClicked: root.findNext()
            }

            DankActionButton {
                id: closeSearchButton
                Layout.alignment: Qt.AlignVCenter
                iconName: "close"
                iconSize: Theme.iconSize - 2
                iconColor: Theme.surfaceText
                onClicked: root.hideSearch()
            }
        }
    }

    StyledRect {
        id: formatBar
        width: parent.width
        height: 42
        color: Theme.withAlpha(Theme.surfaceContainer, Theme.notepadTransparency)
        border.color: Theme.outlineMedium
        border.width: 1
        radius: Theme.cornerRadius

        DankFlickable {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            contentWidth: formatButtons.width
            contentHeight: height
            flickableDirection: Flickable.HorizontalFlick
            clip: true

            Row {
                id: formatButtons
                height: parent.height
                spacing: Theme.spacingXS

                DankActionButton {
                    visible: root.markdownDocument
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "title"
                    iconColor: Theme.surfaceText
                    tooltipText: I18n.tr("Heading")
                    onClicked: root.prefixCurrentLine("## ")
                }
                DankActionButton {
                    visible: root.markdownDocument
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "format_bold"
                    iconColor: Theme.surfaceText
                    tooltipText: I18n.tr("Bold") + " · Ctrl+B"
                    onClicked: root.wrapSelection("**", "**", I18n.tr("bold text"))
                }
                DankActionButton {
                    visible: root.markdownDocument
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "format_italic"
                    iconColor: Theme.surfaceText
                    tooltipText: I18n.tr("Italic") + " · Ctrl+I"
                    onClicked: root.wrapSelection("*", "*", I18n.tr("italic text"))
                }
                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "checklist"
                    iconColor: Theme.surfaceText
                    tooltipText: I18n.tr("Checklist")
                    onClicked: root.prefixCurrentLine("- [ ] ")
                }
                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "format_list_numbered"
                    iconColor: Theme.surfaceText
                    tooltipText: I18n.tr("Numbered List")
                    onClicked: root.prefixCurrentLine("1. ")
                }
                DankActionButton {
                    visible: root.markdownDocument
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "image"
                    iconColor: Theme.surfaceText
                    tooltipText: I18n.tr("Add Image")
                    onClicked: root.imageRequested()
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1
                    height: 24
                    color: Theme.outlineMedium
                }
                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "format_color_text"
                    iconColor: Theme.primary
                    tooltipText: I18n.tr("Text Color")
                    onClicked: root.chooseTextColor()
                }
                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "format_color_reset"
                    iconColor: Theme.surfaceTextMedium
                    tooltipText: I18n.tr("Clear Text Color")
                    enabled: textArea.selectionStart !== textArea.selectionEnd
                    onClicked: documentController.clearTextColor(textArea.selectionStart, textArea.selectionEnd)
                }
                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: documentController.hasBookmarkAt(textArea.cursorPosition) ? "bookmark_remove" : "bookmark_add"
                    iconColor: documentController.hasBookmarkAt(textArea.cursorPosition) ? Theme.warning : Theme.primary
                    tooltipText: documentController.hasBookmarkAt(textArea.cursorPosition) ? I18n.tr("Remove Bookmark") : I18n.tr("Add Bookmark")
                    onClicked: root.toggleBookmark()
                }
                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "bookmarks"
                    iconColor: root.bookmarksVisible ? Theme.primary : Theme.surfaceText
                    tooltipText: I18n.tr("Bookmarks")
                    enabled: documentController.bookmarks.length > 0
                    onClicked: root.bookmarksVisible = !root.bookmarksVisible
                }
                DankActionButton {
                    visible: root.markdownDocument
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: root.previewMode === "edit" ? (root.splitPreviewAvailable ? "splitscreen" : "visibility") : (root.previewMode === "split" ? "visibility" : "edit")
                    iconColor: root.previewMode === "edit" ? Theme.surfaceText : Theme.primary
                    tooltipText: I18n.tr("Markdown Preview") + " · Ctrl+P"
                    onClicked: root.cyclePreviewMode()
                }
            }
        }
    }

    StyledRect {
        width: parent.width
        height: parent.height - bottomControls.height - formatBar.height - Theme.spacingM * 2 - (searchVisible ? searchBar.height + Theme.spacingM : 0)
        color: Theme.withAlpha(Theme.surface, Theme.notepadTransparency)
        border.color: Theme.outlineMedium
        border.width: 1
        radius: Theme.cornerRadius

        RowLayout {
            id: editorPreviewRow
            anchors.fill: parent
            anchors.margins: 1
            spacing: Theme.spacingM

            Item {
                id: editorPane
                visible: !root.markdownDocument || root.previewMode !== "preview"
                Layout.fillHeight: true
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                clip: true

                DankFlickable {
                    id: flickable
                    anchors.fill: parent
                    clip: true
                    contentWidth: width - 11

                    Rectangle {
                        id: lineNumberArea
                        anchors.left: parent.left
                        anchors.top: parent.top
                        width: SettingsData.notepadShowLineNumbers ? Math.max(30, 32 + Theme.spacingXS) : 0
                        height: textArea.contentHeight + textArea.topPadding + textArea.bottomPadding
                        color: "transparent"
                        visible: SettingsData.notepadShowLineNumbers

                        ListView {
                            id: lineNumberList
                            anchors.top: parent.top
                            anchors.topMargin: textArea.topPadding
                            anchors.right: parent.right
                            anchors.rightMargin: 2
                            width: 32
                            height: textArea.contentHeight
                            model: SettingsData.notepadShowLineNumbers ? root.lineModel : []
                            interactive: false
                            spacing: 0

                            delegate: Item {
                                id: lineDelegate
                                required property int index
                                required property string modelData
                                width: 32
                                height: measuringText.contentHeight

                                StyledText {
                                    id: measuringText
                                    width: textArea.width - textArea.leftPadding - textArea.rightPadding
                                    text: modelData || " "
                                    font: textArea.font
                                    wrapMode: Text.Wrap
                                    visible: false
                                }

                                StyledText {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 4
                                    anchors.top: parent.top
                                    text: index + 1
                                    font.family: textArea.font.family
                                    font.pixelSize: textArea.font.pixelSize
                                    color: Theme.surfaceVariantText
                                    horizontalAlignment: Text.AlignRight
                                }
                            }
                        }
                    }

                    TextArea.flickable: TextArea {
                        id: textArea
                        placeholderText: ""
                        placeholderTextColor: Theme.surfaceTextSecondary
                        font.family: SettingsData.notepadUseMonospace ? SettingsData.monoFontFamily : (SettingsData.notepadFontFamily || SettingsData.fontFamily)
                        font.pixelSize: SettingsData.notepadFontSize * SettingsData.fontScale
                        font.letterSpacing: 0
                        color: Theme.surfaceText
                        selectedTextColor: Theme.background
                        selectionColor: Theme.primary
                        selectByMouse: true
                        selectByKeyboard: true
                        wrapMode: TextArea.Wrap
                        focus: true
                        activeFocusOnTab: true
                        textFormat: TextEdit.PlainText
                        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                        persistentSelection: true
                        tabStopDistance: 40
                        leftPadding: (SettingsData.notepadShowLineNumbers ? lineNumberArea.width + Theme.spacingXS : Theme.spacingM)
                        topPadding: Theme.spacingM
                        rightPadding: Theme.spacingM
                        bottomPadding: Theme.spacingM
                        cursorDelegate: DankTextCursor {
                            id: notepadCursor
                            width: 1.5
                            color: Theme.surfaceText
                            x: textArea.cursorRectangle.x
                            y: textArea.cursorRectangle.y
                            height: textArea.cursorRectangle.height
                            shown: textArea.cursorVisible

                            Connections {
                                target: textArea

                                function onCursorPositionChanged() {
                                    notepadCursor.resetBlink();
                                }
                            }
                        }

                        Component.onCompleted: {
                            loadCurrentTabContent();
                            setTextDocumentLineHeight();
                            root.updateLineModel();
                            Qt.callLater(() => {
                                textArea.forceActiveFocus();
                            });
                        }

                        Connections {
                            target: NotepadStorageService
                            function onCurrentTabIndexChanged() {
                                root.commitLiveBuffer();
                                loadCurrentTabContent();
                                Qt.callLater(() => {
                                    textArea.forceActiveFocus();
                                });
                            }
                            function onTabsChanged() {
                                if (NotepadStorageService.tabs.length > 0 && !contentLoaded) {
                                    loadCurrentTabContent();
                                }
                            }
                        }

                        Connections {
                            target: SettingsData
                            function onNotepadShowLineNumbersChanged() {
                                root.updateLineModel();
                            }
                        }

                        onTextChanged: {
                            // Debounced flush to the shared buffer (+ optional disk
                            // autosave) for every loaded tab, not just scratch notes.
                            if (contentLoaded && !applyingShared) {
                                autoSaveTimer.restart();
                            }
                            root.contentChanged();
                            root.updateLineModel();
                        }

                        Keys.onEscapePressed: event => {
                            root.escapePressed();
                            event.accepted = true;
                        }

                        Keys.onPressed: event => {
                            if (SettingsData.notepadAutoContinueLists && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                    && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier))) {
                                if (root.applyEdit(NotepadLogic.continueList(textArea.text, textArea.cursorPosition))) {
                                    event.accepted = true;
                                    return;
                                }
                            }
                            if (event.key === Qt.Key_Tab && textArea.selectionStart === textArea.selectionEnd) {
                                if (root.applyEdit(NotepadLogic.changeListLevel(textArea.text, textArea.cursorPosition,
                                                                                event.modifiers & Qt.ShiftModifier))) {
                                    event.accepted = true;
                                    return;
                                }
                            }
                            if (event.modifiers & Qt.ControlModifier) {
                                switch (event.key) {
                                case Qt.Key_S:
                                    event.accepted = true;
                                    root.saveRequested();
                                    break;
                                case Qt.Key_O:
                                    event.accepted = true;
                                    root.openRequested();
                                    break;
                                case Qt.Key_N:
                                    event.accepted = true;
                                    root.newRequested();
                                    break;
                                case Qt.Key_A:
                                    event.accepted = true;
                                    textArea.selectAll();
                                    break;
                                case Qt.Key_F:
                                    event.accepted = true;
                                    root.showSearch();
                                    break;
                                case Qt.Key_B:
                                    if (root.markdownDocument) {
                                        event.accepted = true;
                                        root.wrapSelection("**", "**", I18n.tr("bold text"));
                                    }
                                    break;
                                case Qt.Key_I:
                                    if (root.markdownDocument) {
                                        event.accepted = true;
                                        root.wrapSelection("*", "*", I18n.tr("italic text"));
                                    }
                                    break;
                                case Qt.Key_P:
                                    if (root.markdownDocument) {
                                        event.accepted = true;
                                        root.cyclePreviewMode();
                                    }
                                    break;
                                }
                            }
                        }

                        background: Rectangle {
                            color: "transparent"
                        }

                        MouseArea {
                            anchors.fill: parent
                            z: 100
                            acceptedButtons: Qt.RightButton
                            hoverEnabled: false
                            scrollGestureEnabled: false

                            onPressed: mouse => {
                                const clickedPosition = textArea.positionAt(mouse.x, mouse.y);
                                if (clickedPosition < textArea.selectionStart || clickedPosition > textArea.selectionEnd) {
                                    textArea.deselect();
                                    textArea.cursorPosition = clickedPosition;
                                }

                                const menuPosition = mapToItem(root, mouse.x, mouse.y);
                                editorContextMenu.x = Math.max(0, Math.min(menuPosition.x, root.width - editorContextMenu.width));
                                editorContextMenu.y = Math.max(0, Math.min(menuPosition.y, root.height - editorContextMenu.height));
                                editorContextMenu.open();
                                mouse.accepted = true;
                            }
                        }
                    }

                    StyledText {
                        id: placeholderOverlay
                        text: I18n.tr("Start typing your notes here...")
                        color: Theme.surfaceTextSecondary
                        font.family: textArea.font.family
                        font.pixelSize: textArea.font.pixelSize
                        visible: textArea.text.length === 0
                        anchors.left: textArea.left
                        anchors.top: textArea.top
                        anchors.leftMargin: textArea.leftPadding
                        anchors.topMargin: textArea.topPadding
                        z: textArea.z + 1
                    }
                }
            }

            Item {
                id: previewPane
                visible: root.markdownDocument && root.previewMode !== "edit"
                Layout.fillHeight: true
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                clip: true

                ScrollView {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM

                    TextArea {
                        readOnly: true
                        text: textArea.text
                        textFormat: TextEdit.MarkdownText
                        baseUrl: root.currentDocumentBaseUrl()
                        wrapMode: TextEdit.Wrap
                        color: Theme.surfaceText
                        font.family: SettingsData.fontFamily
                        font.pixelSize: SettingsData.notepadFontSize * SettingsData.fontScale
                        background: null
                        selectByMouse: true
                    }
                }
            }

            StyledRect {
                visible: root.bookmarksVisible && documentController.bookmarks.length > 0
                Layout.fillHeight: true
                Layout.preferredWidth: 190
                color: Theme.withAlpha(Theme.surfaceContainer, 0.72)
                border.color: Theme.outlineMedium
                border.width: 1
                radius: Theme.cornerRadius

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingS

                    StyledText {
                        Layout.fillWidth: true
                        text: I18n.tr("Bookmarks")
                        color: Theme.surfaceText
                        font.weight: Font.DemiBold
                    }

                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: Theme.spacingXS
                        clip: true
                        model: documentController.bookmarks

                        delegate: StyledRect {
                            required property var modelData
                            width: ListView.view.width
                            height: 38
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.65)

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8
                                height: 22
                                radius: 4
                                color: modelData.color
                            }
                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingXL
                                anchors.right: removeBookmark.left
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                font.pixelSize: Theme.fontSizeSmall
                            }
                            DankActionButton {
                                id: removeBookmark
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: "close"
                                buttonSize: 26
                                iconSize: Theme.iconSizeSmall
                                onClicked: documentController.toggleBookmark(modelData.position, modelData.color)
                            }
                            StateLayer {
                                anchors.fill: parent
                                anchors.rightMargin: removeBookmark.width
                                cornerRadius: parent.radius
                                stateColor: Theme.primary
                                onClicked: {
                                    textArea.cursorPosition = modelData.position;
                                    textArea.forceActiveFocus();
                                }
                            }
                        }
                    }
                }
            }

        }
    }

    Column {
        id: bottomControls
        width: parent.width
        spacing: Theme.spacingS

        Item {
            id: buttonBarItem
            width: parent.width
            height: 32

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingL

                Row {
                    spacing: Theme.spacingS
                    DankActionButton {
                        iconName: "save"
                        iconSize: Theme.iconSize - 2
                        iconColor: Theme.primary
                        enabled: currentTab && (hasUnsavedChanges() || textArea.text.length > 0)
                        onClicked: root.saveRequested()
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Save")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceTextMedium
                    }
                }

                Row {
                    spacing: Theme.spacingS
                    DankActionButton {
                        iconName: "folder_open"
                        iconSize: Theme.iconSize - 2
                        iconColor: Theme.secondary
                        onClicked: root.openRequested()
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Open")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceTextMedium
                    }
                }

                Row {
                    spacing: Theme.spacingS
                    DankActionButton {
                        iconName: "note_add"
                        iconSize: Theme.iconSize - 2
                        iconColor: Theme.surfaceText
                        onClicked: root.newRequested()
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("New")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceTextMedium
                    }
                }

            }

            Row {
                id: rightButtonRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                DankActionButton {
                    visible: !root.inPopout
                    iconName: "open_in_new"
                    iconSize: Theme.iconSize - 2
                    iconColor: Theme.surfaceText
                    onClicked: root.popoutRequested()
                }

                DankActionButton {
                    visible: root.inPopout
                    iconName: "dock_to_right"
                    iconSize: Theme.iconSize - 2
                    iconColor: Theme.surfaceText
                    onClicked: root.dockRequested()
                }

                DankActionButton {
                    iconName: "more_horiz"
                    iconSize: Theme.iconSize - 2
                    iconColor: Theme.surfaceText
                    onClicked: root.settingsRequested()
                }
            }

            StyledRect {
                id: pathInfoPopup
                visible: root.showPathInfo
                anchors.right: parent.right
                anchors.bottom: parent.top
                anchors.bottomMargin: Theme.spacingS
                width: Math.min(root.width, 360)
                height: pathInfoRow.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                border.color: Theme.outlineMedium
                border.width: 1
                z: 10

                Row {
                    id: pathInfoRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingS

                    DankIcon {
                        name: currentTab && currentTab.isTemporary ? "draft" : "description"
                        size: Theme.iconSize - 4
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        width: pathInfoRow.width - (Theme.iconSize - 4) - copyPathButton.width - Theme.spacingS * 2
                        text: root.currentFilePath()
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideMiddle
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    DankActionButton {
                        id: copyPathButton
                        iconName: "content_copy"
                        iconSize: Theme.iconSize - 6
                        iconColor: Theme.surfaceTextMedium
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                            const proc = clipboardCopyProcComp.createObject(root, {
                                content: root.currentFilePath(),
                                running: true
                            });
                            proc.exited.connect(() => {
                                ToastService.showInfo(I18n.tr("Path copied to clipboard"));
                                proc.destroy();
                            });
                        }
                    }
                }
            }
        }

        Row {
            id: statusRow
            width: parent.width
            spacing: Theme.spacingL

            StyledText {
                text: {
                    const len = textArea.text.length;
                    if (len === 0)
                        return I18n.tr("Empty");
                    return len === 1 ? I18n.tr("%1 character").arg(len) : I18n.tr("%1 characters").arg(len);
                }
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextMedium
            }

            StyledText {
                text: textArea.lineCount === 1 ? I18n.tr("Line: %1").arg(textArea.lineCount) : I18n.tr("Lines: %1").arg(textArea.lineCount)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextMedium
                visible: textArea.text.length > 0
                opacity: 1.0
            }

            Row {
                visible: textArea.text.length > 0
                spacing: Theme.spacingXS

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property bool savingToDisk: autoSaveTimer.running && currentTab && (currentTab.isTemporary || SettingsData.notepadAutoSave)
                    text: {
                        if (savingToDisk) {
                            return I18n.tr("Saving...");
                        }

                        if (currentTab && currentTab.isTemporary) {
                            return I18n.tr("Auto saved");
                        }

                        return hasUnsavedChanges() ? I18n.tr("Unsaved changes") : I18n.tr("Saved");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: {
                        if (savingToDisk) {
                            return Theme.primary;
                        }

                        if (currentTab && currentTab.isTemporary) {
                            return Theme.success;
                        }

                        return hasUnsavedChanges() ? Theme.warning : Theme.success;
                    }
                }

                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "info"
                    iconSize: Theme.iconSizeSmall
                    iconColor: root.showPathInfo ? Theme.primary : Theme.surfaceTextMedium
                    buttonSize: 20
                    onClicked: root.showPathInfo = !root.showPathInfo
                }
            }
        }
    }

    Timer {
        id: autoSaveTimer
        interval: 2000
        repeat: false
        onTriggered: {
            autoSaveToSession();
        }
    }

    Timer {
        id: annotationSaveTimer
        interval: 350
        repeat: false
        onTriggered: {
            const tabIndex = NotepadStorageService.tabIndexById(root.pendingAnnotationsTabId);
            if (tabIndex >= 0 && root.pendingAnnotations)
                NotepadStorageService.saveDocumentAnnotations(tabIndex, root.pendingAnnotations);
            root.pendingAnnotationsTabId = -1;
            root.pendingAnnotations = null;
        }
    }

    FileView {
        id: externalWatch
        path: (!root.externalWatchPaused && currentTab && !currentTab.isTemporary && currentTab.filePath) ? currentTab.filePath : ""
        blockLoading: true
        preload: true
        watchChanges: true

        onFileChanged: {
            root.watcherReloadPending = true;
            reload();
        }

        onLoaded: {
            if (root.ignoreNextExternalChange) {
                root.ignoreNextExternalChange = false;
                root.lastSavedContent = externalWatch.text();
                root.watcherReloadPending = false;
                return;
            }
            if (!root.watcherReloadPending)
                return;
            root.watcherReloadPending = false;
            if (!root.contentLoaded || !root.currentTab || root.currentTab.isTemporary)
                return;
            if (!root.surfaceVisible)
                return;
            root.applyDiskContent(externalWatch.text());
        }

        onLoadFailed: error => {}
    }

    Connections {
        target: NotepadStorageService
        function onSessionBufferRevisionChanged() {
            if (applyingShared || !contentLoaded || loadedTabId < 0)
                return;
            if (textArea.activeFocus)
                return;
            var buffer = NotepadStorageService.getSessionBuffer(loadedTabId);
            if (buffer === undefined || buffer.content === textArea.text)
                return;
            if (textArea.text === lastSavedContent) {
                applyingShared = true;
                lastSavedContent = buffer.baseline;
                textArea.text = buffer.content;
                applyingShared = false;
            }
        }
    }
}
