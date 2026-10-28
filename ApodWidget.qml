import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins

// Optional bar/dock widget. Left click: info popout. Right click: refresh now.
PluginComponent {
    id: root

    layerNamespacePlugin: "apod-wallpaper"

    PluginGlobalVar { id: infoVar; varName: "info"; defaultValue: ({}) }
    PluginGlobalVar { id: busyVar; varName: "busy"; defaultValue: false }

    readonly property var info: infoVar.value || ({})
    readonly property bool busy: busyVar.value === true
    readonly property bool showTitle: pluginData.showTitle ?? false
    readonly property string icon: busy ? "sync" : "public"

    function refresh() {
        Quickshell.execDetached(["dms", "ipc", "call", "apodWallpaper", "refresh"]);
    }

    pillRightClickAction: () => root.refresh()

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: root.icon
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.showTitle && text !== ""
                text: root.info.title || ""
                width: Math.min(implicitWidth, 220)
                elide: Text.ElideRight
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        DIcon {
            name: root.icon
            size: root.iconSize
            color: Theme.widgetIconColor
        }
    }

    popoutWidth: 420
    popoutHeight: 560

    popoutContent: Component {
        PopoutComponent {
            id: pop

            headerText: root.info.title || "Astronomy Picture of the Day"
            detailsText: (root.info.date || "Not fetched yet") + (root.info.copyright ? "  ·  © " + root.info.copyright : "")
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Image {
                    width: parent.width
                    height: 200
                    visible: !!root.info.path
                    source: root.info.path ? "file://" + root.info.path : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 840
                }

                Flickable {
                    width: parent.width
                    height: root.popoutHeight - pop.headerHeight - pop.detailsHeight - 200 - Theme.buttonHeightXS - Theme.spacingXL * 3
                    contentHeight: explanation.implicitHeight
                    clip: true

                    StyledText {
                        id: explanation
                        width: parent.width
                        text: root.info.explanation || ""
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }

                Row {
                    spacing: Theme.spacingS

                    DButton {
                        text: root.busy ? "Checking…" : "Refresh"
                        iconName: "sync"
                        enabled: !root.busy
                        onClicked: root.refresh()
                    }

                    DButton {
                        text: "Open on NASA"
                        iconName: "open_in_new"
                        backgroundColor: Theme.secondaryContainer
                        textColor: Theme.onSecondaryContainer
                        onClicked: {
                            Qt.openUrlExternally(root.info.pageUrl || "https://apod.nasa.gov/apod/astropix.html");
                            pop.closePopout();
                        }
                    }
                }
            }
        }
    }
}
