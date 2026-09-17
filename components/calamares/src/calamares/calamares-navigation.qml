/* SPDX-License-Identifier: GPL-3.0-or-later */

import io.calamares.ui 1.0
import io.calamares.core 1.0
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: navigationBar
    color: "#101411"
    height: 76

    function cleanLabel(label) {
        return label ? label.replace(/&/g, "") : ""
    }

    component ActionButton: Button {
        id: control
        implicitHeight: 52
        implicitWidth: Math.max(132, contentItem.implicitWidth + 48)

        contentItem: Text {
            text: control.highlighted ? "→  " + control.text : "←  " + control.text
            color: control.enabled
                ? (control.highlighted ? "#00391C" : "#96D5A9")
                : "#68716B"
            font.pixelSize: 16
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            radius: 18
            color: !control.enabled
                ? "#1C211E"
                : (control.highlighted
                    ? (control.down ? "#B1F1C5" : "#96D5A9")
                    : "transparent")
            border.width: control.highlighted ? 0 : 1
            border.color: control.highlighted ? "transparent" : "#3E4941"
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 52
        anchors.rightMargin: 52
        height: 1
        color: "#3E4941"
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 52
        anchors.rightMargin: 52
        anchors.topMargin: 12
        anchors.bottomMargin: 12
        spacing: 12

        Item { Layout.fillWidth: true }

        ActionButton {
            text: navigationBar.cleanLabel(ViewManager.backLabel)
            enabled: ViewManager.backEnabled
            visible: ViewManager.backAndNextVisible
            onClicked: ViewManager.back()
        }

        ActionButton {
            text: navigationBar.cleanLabel(ViewManager.nextLabel)
            highlighted: true
            enabled: ViewManager.nextEnabled
            visible: ViewManager.backAndNextVisible
            onClicked: ViewManager.next()
        }

        ActionButton {
            text: navigationBar.cleanLabel(ViewManager.quitLabel)
            enabled: ViewManager.quitEnabled
            visible: ViewManager.quitVisible
            highlighted: true
            onClicked: ViewManager.quit()
        }
    }
}
