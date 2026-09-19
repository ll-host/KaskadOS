import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Modals.Common
import qs.Modals.FileBrowser
import qs.Common
import qs.Services
import qs.Widgets

DankModal {
    id: root
    visible: false
    layerNamespace: "dms:wifi-qrcode"

    property bool disablePopupTransparency: true
    property string wifiSSID: ""
    property string wifiPassword: ""
    property bool passwordLoading: false
    property string themedQrCodePath: ""
    property string normalQrCodePath: ""
    modalWidth: 420
    modalHeight: 560
    onBackgroundClicked: hide()
    onOpened: {
        Qt.callLater(() => {
            modalFocusScope.forceActiveFocus();
            contentLoader.item.wifiSSID = wifiSSID;
            contentLoader.item.themedQrCodePath = themedQrCodePath;
            contentLoader.item.saveBrowserLoader = saveBrowserLoader;
        });
    }

    function show(ssid) {
        wifiSSID = ssid;
        wifiPassword = "";
        passwordLoading = true;
        fetchNetworkQRCode(ssid);
        fetchNetworkPassword(ssid);
    }

    function unescapeWifiValue(value) {
        let result = "";
        let escaped = false;
        for (let i = 0; i < value.length; i++) {
            const ch = value[i];
            if (escaped) {
                result += ch === "n" ? "\n" : ch;
                escaped = false;
            } else if (ch === "\\") {
                escaped = true;
            } else {
                result += ch;
            }
        }
        return result;
    }

    function wifiField(content, field) {
        const marker = field + ":";
        const start = content.indexOf(marker);
        if (start < 0)
            return "";
        let value = "";
        let escaped = false;
        for (let i = start + marker.length; i < content.length; i++) {
            const ch = content[i];
            if (!escaped && ch === ";")
                break;
            value += ch;
            escaped = !escaped && ch === "\\";
            if (ch !== "\\")
                escaped = false;
        }
        return unescapeWifiValue(value);
    }

    function fetchNetworkPassword(ssid) {
        DMSService.sendRequest("network.qrcode-content", { ssid: ssid }, response => {
            passwordLoading = false;
            if (response.error)
                return;
            wifiPassword = wifiField(response.result || "", "P");
        });
    }

    function hide() {
        if (themedQrCodePath !== "") {
            deleteQRCodeFile(themedQrCodePath);
        }
        if (normalQrCodePath !== "") {
            deleteQRCodeFile(normalQrCodePath);
        }
        close();
    }

    function fetchNetworkQRCode(ssid) {
        // TODO: Add loading UI?

        DMSService.sendRequest("network.qrcode", {
            ssid: ssid
        }, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to fetch network QR code: %1").arg(JSON.stringify(response.error)));
            } else if (response.result) {
                themedQrCodePath = response.result[0];
                normalQrCodePath = response.result[1];
                open();
            }
        });
    }

    function deleteQRCodeFile(path) {
        DMSService.sendRequest("network.delete-qrcode", {
            path: path
        }, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to remove QR code at %1: %2").arg(path).arg(JSON.stringify(response.error)));
            }
        });
    }

    LazyLoader {
        id: saveBrowserLoader
        active: false

        FileBrowserSurfaceModal {
            id: saveBrowser

            browserTitle: I18n.tr("Save QR Code")
            browserIcon: "qr_code"
            browserType: "default"
            fileExtensions: ["*.png"]
            allowStacking: true
            saveMode: true
            defaultFileName: `${root.wifiSSID ?? "wifi-qrcode"}.png`
            onFileSelected: path => {
                const cleanPath = decodeURI(path.toString().replace(/^file:\/\//, ''));
                const fileName = cleanPath.split('/').pop();
                const fileUrl = "file://" + cleanPath;

                copyQrCodeProcess.exec(["cp", root.normalQrCodePath, cleanPath, "-f"]);
            }

            Process {
                id: copyQrCodeProcess
                stdout: StdioCollector {
                    onStreamFinished: {
                        saveBrowser.close();
                    }
                }
            }
        }
    }

    content: Component {
        Item {
            id: theItem
            property alias themedQrCodePath: qrCodeImg.source
            property var saveBrowserLoader: null
            property string wifiSSID: ""
            anchors.fill: parent

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingL

                RowLayout {
                    id: modalTitle
                    width: parent.width

                    StyledText {
                        text: I18n.tr("WiFi QR code for ") + theItem.wifiSSID
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.surfaceText
                        font.weight: Font.Bold
                        Layout.alignment: Qt.AlignLeft
                    }

                    DankActionButton {
                        iconName: "save"
                        iconSize: Theme.iconSize - 4
                        iconColor: Theme.surfaceText
                        onClicked: {
                            saveBrowserLoader.active = true;
                            if (saveBrowserLoader.item) {
                                saveBrowserLoader.item.open();
                            }
                        }
                        Layout.alignment: Qt.AlignRight
                    }

                    DankActionButton {
                        iconName: "close"
                        iconSize: Theme.iconSize - 4
                        iconColor: Theme.surfaceText
                        onClicked: root.hide()
                        Layout.alignment: Qt.AlignRight
                    }
                }

                Image {
                    id: qrCodeImg
                    height: 330
                    width: height
                    anchors.horizontalCenter: parent.horizontalCenter

                    MultiEffect {
                        source: qrCodeImg
                        anchors.fill: source
                        colorization: 1.0
                        colorizationColor: Theme.primary
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 64
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHighest
                    visible: root.passwordLoading || root.wifiPassword.length > 0

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingS

                        Column {
                            Layout.fillWidth: true
                            spacing: 2

                            StyledText {
                                text: "Пароль Wi‑Fi"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                text: root.passwordLoading ? "Загрузка…" : root.wifiPassword
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                width: parent.width
                            }
                        }

                        DankActionButton {
                            visible: !root.passwordLoading && root.wifiPassword.length > 0
                            iconName: "content_copy"
                            onClicked: {
                                Quickshell.execDetached(["dms", "cl", "copy", root.wifiPassword]);
                                ToastService.showInfo("Пароль скопирован");
                            }
                        }
                    }
                }
            }
        }
    }
}
