import QtQuick
import qs.Common
import qs.Modules.DankBar.Components
import qs.Services
import qs.Widgets

BasePill {
    id: root

    property var widgetData: null
    property bool isActive: false

    readonly property bool hasUpdates: SystemUpdateService.updateCount > 0
    readonly property bool isChecking: SystemUpdateService.isChecking
    readonly property bool isClean: SystemUpdateService.sysupdateAvailable && !hasUpdates && !isChecking && !SystemUpdateService.hasError
    width: isVerticalOrientation ? barThickness : visualWidth
    height: isVerticalOrientation ? visualHeight : barThickness

    Ref {
        service: SystemUpdateService
    }

    content: Component {
        Item {
            implicitWidth: root.isVerticalOrientation ? root.widgetThickness : updaterIcon.implicitWidth
            implicitHeight: root.widgetThickness

            DankIcon {
                id: statusIcon
                anchors.centerIn: parent
                visible: root.isVerticalOrientation
                smoothTransform: root.isChecking
                name: {
                    if (root.isChecking)
                        return "refresh";
                    if (SystemUpdateService.hasError)
                        return "error";
                    if (root.hasUpdates)
                        return "system_update_alt";
                    return "check_circle";
                }
                size: Theme.barIconSize(root.barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                color: {
                    if (SystemUpdateService.hasError)
                        return Theme.error;
                    if (root.hasUpdates)
                        return Theme.primary;
                    return root.isActive ? Theme.primary : Theme.surfaceText;
                }

                RotationAnimator on rotation {
                    id: rotationAnimation
                    from: 0
                    to: 360
                    duration: 1000
                    loops: Animation.Infinite
                    running: root.isChecking

                    onRunningChanged: {
                        if (!running)
                            statusIcon.rotation = 0;
                    }
                }
            }

            Rectangle {
                width: 8
                height: 8
                radius: 4
                color: Theme.error
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: (barConfig?.removeWidgetPadding ?? false) ? 0 : 6
                anchors.topMargin: (barConfig?.removeWidgetPadding ?? false) ? 0 : 6
                visible: root.isVerticalOrientation && root.hasUpdates && !root.isChecking
            }

            Row {
                id: updaterIcon
                anchors.centerIn: parent
                spacing: Theme.spacingXS
                visible: !root.isVerticalOrientation

                DankIcon {
                    id: statusIconHorizontal
                    anchors.verticalCenter: parent.verticalCenter
                    smoothTransform: root.isChecking
                    name: {
                        if (root.isChecking)
                            return "refresh";
                        if (SystemUpdateService.hasError)
                            return "error";
                        if (root.hasUpdates)
                            return "system_update_alt";
                        return "check_circle";
                    }
                    size: Theme.barIconSize(root.barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: {
                        if (SystemUpdateService.hasError)
                            return Theme.error;
                        if (root.hasUpdates)
                            return Theme.primary;
                        return root.isActive ? Theme.primary : Theme.surfaceText;
                    }

                    RotationAnimator on rotation {
                        id: rotationAnimationHorizontal
                        from: 0
                        to: 360
                        duration: 1000
                        loops: Animation.Infinite
                        running: root.isChecking

                        onRunningChanged: {
                            if (!running)
                                statusIconHorizontal.rotation = 0;
                        }
                    }
                }

                StyledText {
                    id: countText
                    anchors.verticalCenter: parent.verticalCenter
                    text: SystemUpdateService.updateCount.toString()
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: Theme.widgetTextColor
                    visible: root.hasUpdates && !root.isChecking
                }
            }
        }
    }

    MouseArea {
        z: 1
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => {
            root.triggerRipple(this, mouse.x, mouse.y);
            if (popoutTarget && popoutTarget.setTriggerPosition) {
                const globalPos = root.visualContent.mapToItem(null, 0, 0);
                const currentScreen = parentScreen || Screen;
                const barPosition = root.axis?.edge === "left" ? 2 : (root.axis?.edge === "right" ? 3 : (root.axis?.edge === "top" ? 0 : 1));
                const pos = SettingsData.getPopupTriggerPosition(globalPos, currentScreen, barThickness, root.visualWidth, root.barSpacing, barPosition, root.barConfig);
                popoutTarget.setTriggerPosition(pos.x, pos.y, pos.width, section, currentScreen, barPosition, barThickness, root.barSpacing, root.barConfig);
            }
            root.clicked();
        }
    }
}
