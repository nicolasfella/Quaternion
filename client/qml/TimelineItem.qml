import QtQuick 2.6
import QtQuick.Controls 2.2
//import QtGraphicalEffects 1.0 // For fancy highlighting
import Quotient 1.0

Item {
    // Supplementary components

    TimelineSettings {
        id: settings
        readonly property bool autoload_images: value("UI/autoload_images", true)
        readonly property string highlight_mode: value("UI/highlight_mode", "background")
        readonly property color highlight_color: value("UI/highlight_color", "orange")
        readonly property color outgoing_color_base: value("UI/outgoing_color", "#4A8780")
        readonly property color outgoing_color:
            mixColors(defaultPalette.text, settings.outgoing_color_base, 0.7)
        readonly property bool show_author_avatars:
            value("UI/show_author_avatars", timeline_style != "xchat")
    }
    SystemPalette { id: defaultPalette; colorGroup: SystemPalette.Active }
    SystemPalette { id: disabledPalette; colorGroup: SystemPalette.Disabled }

    // Property interface

    /** Determines whether the view is moving at the moment */
    property var view
    property bool moving: view.moving

    // TimelineItem definition

    visible: marks !== EventStatus.Hidden
    enabled: visible
    height: childrenRect.height * visible

    readonly property bool sectionVisible: section !== aboveSection
    readonly property bool authorSectionVisible:
                            sectionVisible || author !== aboveAuthor
    readonly property bool redacted: marks === EventStatus.Redacted
    readonly property bool replaced: marks === EventStatus.Replaced
    readonly property bool pending: [
                                        EventStatus.Submitted,
                                        EventStatus.Departed,
                                        EventStatus.ReachedServer,
                                        EventStatus.SendingFailed
                                    ].indexOf(marks) != -1
    readonly property bool failed: marks === EventStatus.SendingFailed
    readonly property bool eventWithTextPart: ["message", "emote", "image", "file"].indexOf(eventType) >= 0
    /*readonly*/ property string textColor:
        marks === EventStatus.Submitted || failed ? defaultPalette.mid :
        marks === EventStatus.Departed ? disabledPalette.text :
        redacted ? disabledPalette.text :
        (eventWithTextPart && author === room.localUser) ? settings.outgoing_color :
        highlight && settings.highlight_mode == "text" ? settings.highlight_color :
        (["state", "notice", "other"].indexOf(eventType) >= 0) ?
                disabledPalette.text : defaultPalette.text
    readonly property string authorName: room && room.safeMemberName(author.id)
    // FIXME: boilerplate with models/userlistmodel.cpp:115
    readonly property string authorColor: Qt.hsla(userHue,
                                                  (1-defaultPalette.window.hslSaturation),
                                                  /* contrast but not too heavy: */
                                                  (-0.7*defaultPalette.window.hslLightness + 0.9),
                                                  defaultPalette.buttonText.a)

    readonly property bool xchatStyle: settings.timeline_style === "xchat"
    readonly property bool actionEvent: eventType == "state" || eventType == "emote"

    readonly property bool readMarkerHere: messageModel.readMarkerVisualIndex === index

    // A message is considered shown if its bottom is within the
    // viewing area of the timeline.
    readonly property bool shown: y + height - 1 > view.contentY &&
                                  y + height - 1 < view.contentY + view.height

    readonly property bool partiallyShown: y + height - 1 > view.contentY
                                           && y < view.contentY + view.height

    onShownChanged: {
        if (!pending)
            controller.onMessageShownChanged(eventId, shown)
    }

    onPendingChanged: shownChanged()

    onReadMarkerHereChanged: {
        if (readMarkerHere) {
            if (partiallyShown)
                chatView.readMarkerContentPos =
                    Qt.binding(function() { return y + height })
            else
                chatView.parkReadMarker(index)
        }
    }

    onPartiallyShownChanged: readMarkerHereChanged()

    Component.onCompleted: {
        if (shown)
            shownChanged(true)
        readMarkerHereChanged()
    }

    AnimationBehavior on textColor {
        ColorAnimation { duration: settings.animations_duration_ms }
    }

    property bool showingDetails

    Connections {
        target: controller
        onShowDetails: {
            if (currentIndex === index) {
                showingDetails = !showingDetails
                if (!settings.enable_animations) {
                    detailsAreaLoader.visible = showingDetails
                    detailsAreaLoader.opacity = showingDetails
                } else
                    detailsAnimation.start()
            }
        }
        onAnimateMessage: {
            if (currentIndex === index)
                blinkAnimation.start()
        }
    }

    SequentialAnimation {
        id: detailsAnimation
        PropertyAction {
            target: detailsAreaLoader; property: "visible"
            value: true
        }
        FastNumberAnimation {
            target: detailsAreaLoader; property: "opacity"
            to: showingDetails
            easing.type: Easing.OutQuad
        }
        PropertyAction {
            target: detailsAreaLoader; property: "visible"
            value: showingDetails
        }
    }
    SequentialAnimation {
        id: blinkAnimation
        loops: 3
        PropertyAction {
            target: messageFlasher; property: "visible"
            value: true
        }
        PauseAnimation {
            // `settings.animations_duration_ms` intentionally is not in use here
            // because this is not just an eye candy animation - the user will lose
            // functionality if this animation stops working.
            duration: 200
        }
        PropertyAction {
            target: messageFlasher; property: "visible"
            value: false
        }
        PauseAnimation {
            duration: 200
        }
    }

    TimelineMouseArea {
        anchors.fill: fullMessage
        acceptedButtons: Qt.AllButtons
    }

    Column {
        id: fullMessage
        width: parent.width

        Rectangle {
            width: parent.width
            height: childrenRect.height + 2
            visible: sectionVisible
            color: defaultPalette.window
            Label {
                font.family: settings.font.family
                font.pointSize: settings.font.pointSize
                font.bold: true
                renderType: settings.render_type
                text: section
            }
        }
        Loader {
            id: detailsAreaLoader
//            asynchronous: true // https://bugreports.qt.io/browse/QTBUG-50992
            active: visible
            visible: false // Controlled by showDetailsButton
            opacity: 0
            width: parent.width

            sourceComponent: detailsArea
        }

        Item {
            id: message
            width: parent.width
            height: childrenRect.height

            // There are several layout styles (av - author avatar,
            // al - author label, ts - timestamp, c - content
            // default (when "timeline_style" is not "xchat"):
            //   av al
            //   ts c
            // state-emote (default for state and emote events):
            //   av (al+c in a single control
            //   ts  spanning both rows)
            // xchat (when "timeline_style" is "xchat"):
            //   ts av al c
            // xchat state-emote
            //   ts av *(asterisk) al c

            Image {
                function desiredHeight() {
                    return xchatStyle ? authorLabel.height :
                           visible ? authorLabel.height * 2 - timelabel.height
                                   : undefined
                }
                function desiredWidth() {
                    return !xchatStyle ? timelabel.width : undefined
                }

                id: authorAvatar
                visible: settings.show_author_avatars && source &&
                         (authorSectionVisible || xchatStyle)
                anchors.left: xchatStyle ? timelabel.right : parent.left
                anchors.leftMargin: xchatStyle * 3
                height: desiredHeight()
                width: desiredWidth()
                fillMode: Image.PreserveAspectFit

                source: author.avatarMediaId ?
                            "image://mtx/" + author.avatarMediaId : ""
                sourceSize: Qt.size(desiredWidth() * 2, desiredHeight() * 2)
            }
            Label {
                id: authorLabel
                visible: xchatStyle || (!actionEvent && authorSectionVisible)
                anchors.left: authorAvatar.right
                anchors.leftMargin: 2
                anchors.top: authorAvatar.top
                width: if (xchatStyle) { 120 - authorAvatar.width }
                horizontalAlignment:
                    actionEvent ? Text.AlignRight : Text.AlignLeft
                elide: Text.ElideRight

                color: authorColor
                textFormat: Label.PlainText
                font.family: settings.font.family
                font.pointSize: settings.font.pointSize
                font.bold: !xchatStyle
                renderType: settings.render_type

                text: (actionEvent ? "* " : "") + authorName
            }
            TimelineMouseArea {
                anchors.left: authorAvatar.left
                anchors.right: authorLabel.right
                anchors.top: authorLabel.top
                anchors.bottom:  authorLabel.bottom
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton|Qt.MiddleButton
                hoverEnabled: true
                onEntered: controller.showStatusMessage(author.id)
                onExited: controller.showStatusMessage("")
                onClicked:
                    controller.resourceRequested(author.id,
                                                 mouse.button === Qt.LeftButton
                                                 ? "mention" : "_interactive")
            }

            Label {
                id: timelabel
                anchors.top: xchatStyle ? authorAvatar.top : authorAvatar.bottom
                anchors.left: parent.left

                opacity: 0.8
                renderType: settings.render_type
                font.family: settings.font.family
                font.pointSize: settings.font.pointSize
                font.italic: pending

                text: "<" + time.toLocaleTimeString(Qt.locale(), Locale.ShortFormat) + ">"
            }

            Item {
                id: highlighter
                anchors.fill: textField
                visible: highlight && settings.highlight_mode != "text"
                // Uncomment for fancy highlighting
//                RectangularGlow {
//                    anchors.fill: parent
//                    glowRadius: 5
//                    cornerRadius: 2
//                    color: settings.highlight_color
//                    cached: true
//                }
//                Rectangle {
//                    anchors.fill: parent
//                    border.color: settings.highlight_color
//                    border.width: 1
//                }
                Rectangle {
                    anchors.fill: parent
                    opacity: 0.2
                    color: settings.highlight_color
                    radius: 2
                }
            }
            Item {
                id: messageFlasher
                anchors.fill: textField
                visible: false
                Rectangle {
                    anchors.fill: parent
                    opacity: 0.5
                    color: settings.highlight_color
                    radius: 2
                }
            }
            Item {
                id: textField
                anchors.top: !xchatStyle && authorLabel.visible
                             ? authorLabel.bottom : authorAvatar.top
                anchors.left: xchatStyle ? authorLabel.right : timelabel.right
                anchors.leftMargin: 1
                anchors.right: parent.right
                anchors.rightMargin: 1
                height: textFieldImpl.height
                clip: true

                TextEdit {
                    id: textFieldImpl
                    anchors.top: textField.top
                    width: parent.width
                    leftPadding: 2
                    rightPadding: 2
                    x: -textScrollBar.position * contentWidth

                    // Doesn't work for attributes
                    function toHtmlEscaped(txt) {
                        // Make sure to replace & first
                        return txt.replace(/&/g, '&amp;')
                                  .replace(/</g, '&lt;').replace(/>/g, '&gt;')
                    }

                    selectByMouse: true
                    readOnly: true
                    textFormat: TextEdit.RichText
                    // FIXME: The text is clumsy and slows down creation
                    text: (actionEvent && !xchatStyle ?
                           ("<a href='" + author.id + "' style='text-decoration:none;color:\""
                                    + authorColor + "\";font-weight:bold'>"
                                    + toHtmlEscaped(authorName) + "</a> ") : "")
                          + display
                          + (replaced
                             ? "<small style='color:\""
                               + mixColors(disabledPalette.text, defaultPalette.text, 0.3)
                               + "\"'>" + " (" + qsTr("edited") + ")</small>"
                             : "")
                    horizontalAlignment: Text.AlignLeft
                    wrapMode: Text.Wrap
                    color: textColor
                    font: settings.font
                    renderType: settings.render_type

                    // TODO: In the code below, links should be resolved
                    // with Qt.resolvedLink, once we figure out what
                    // to do with relative URLs (note: www.google.com
                    // is a relative URL, https://www.google.com is not).
                    // Instead of Qt.resolvedUrl (and, most likely,
                    // QQmlAbstractUrlInterceptor to convert URLs)
                    // we might just prefer to do the whole resolving
                    // in C++.
                    onHoveredLinkChanged:
                        controller.showStatusMessage(hoveredLink)

                    onLinkActivated: controller.resourceRequested(link)

                    TimelineTextEditSelector {}
                }

                TimelineMouseArea {
                    anchors.fill: parent
                    cursorShape: textFieldImpl.hoveredLink
                                 ? Qt.PointingHandCursor : Qt.IBeamCursor
                    acceptedButtons: Qt.MiddleButton | Qt.RightButton

                    onClicked: {
                        if (mouse.button === Qt.MiddleButton) {
                            if (textFieldImpl.hoveredLink)
                                controller.resourceRequested(
                                    textFieldImpl.hoveredLink, "_interactive")
                        } else if (mouse.button === Qt.RightButton) {
                            controller.showMenu(index, textFieldImpl.hoveredLink,
                                textFieldImpl.selectedText, showingDetails)
                        }
                    }

                    onWheel: {
                        if (wheel.angleDelta.x != 0 &&
                                textFieldImpl.width < textFieldImpl.contentWidth)
                        {
                            if (wheel.pixelDelta.x != 0)
                                textScrollBar.position -=
                                            wheel.pixelDelta.x / width
                            else
                                textScrollBar.position -=
                                            wheel.angleDelta.x / 6 / width
                            textScrollBar.position =
                                    Math.min(1, Math.max(0,
                                        textScrollBar.position))
                        } else
                            wheel.accepted = false
                    }
                }
                ScrollBar {
                    id: textScrollBar
                    hoverEnabled: true
                    visible: textFieldImpl.contentWidth > textFieldImpl.width
                    active: visible
                    orientation: Qt.Horizontal
                    size: textFieldImpl.width / textFieldImpl.contentWidth
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                }
            }

            Loader {
                id: imageLoader
                active: eventType == "image"

                anchors.top: textField.bottom
                anchors.left: textField.left
                anchors.right: textField.right

                sourceComponent: ImageContent {
                    property var info:
                        !progressInfo.isUpload && !progressInfo.active &&
                        content.info && content.info.thumbnail_info
                        ? content.info.thumbnail_info
                        : content.info
                    sourceSize: if (info) { Qt.size(info.w, info.h) }
                    source: downloaded || progressInfo.isUpload
                            ? progressInfo.localPath
                            : progressInfo.failed
                              ? ""
                              : content.info && content.info.thumbnail_info
                                && !autoload
                                ? "image://mtx/" + content.thumbnailMediaId
                                : ""
                    maxHeight: chatView.height - textField.height -
                               authorLabel.height * !xchatStyle
                    autoload: settings.autoload_images
                }
            }
            Loader {
                id: fileLoader
                active: eventType == "file"

                anchors.top: textField.bottom
                anchors.left: textField.left
                anchors.right: textField.right
                height: childrenRect.height

                sourceComponent: FileContent { }
            }

            Label {
                id: annotationLabel
                anchors.top: imageLoader.active ? imageLoader.bottom
                                                : fileLoader.bottom
                anchors.left: textField.left
                anchors.right: parent.right
                height: annotation ? implicitHeight : 0
                visible: annotation

                font.family: settings.font.family
                font.pointSize: settings.font.pointSize
                font.italic: true
                leftPadding: 2
                rightPadding: 2

                text: annotation
            }
            Flow {
                anchors.top: annotationLabel.bottom
                anchors.left: textField.left
                anchors.right: parent.right

                Repeater {
                    model: reactions
                    ToolButton {
                        id: reactionButton
                        readonly property bool includesLocalUser:
                            modelData.authors.indexOf(
                                room.safeMemberName(room.localUser.id)) !== -1

                        topPadding: 2
                        bottomPadding: 2

                        contentItem: Text {
                            text: modelData.key + " \u00d7" /* Math "multiply" */
                                  + modelData.authors.length
                            font.family: settings.font.family
                            font.pointSize: settings.font.pointSize - 1
                            color: reactionButton.includesLocalUser
                                       ? defaultPalette.highlight
                                       : defaultPalette.buttonText
                        }

                        background: Rectangle {
                            radius: 4
                            color: reactionButton.down ? defaultPalette.button
                                                       : "transparent"
                            border.color: reactionButton.includesLocalUser
                                              ? defaultPalette.highlight
                                              : disabledPalette.buttonText
                            border.width: 1
                        }

                        hoverEnabled: true
                        MyToolTip {
                            visible: hovered
                            text: qsTr("%1 reacted with '%2'",
                                       "%1 is a list of users, %2 is " +
                                       "the reaction (usually an emoji)",
                                       modelData.authors.length)
                                  .arg(modelData.authors.length <= 10
                                       ? modelData.authors.join(", ")
                                       : qsTr("%n author(s)", "",
                                              model.data.authors.length))
                                  .arg(modelData.key)
                        }

                        onClicked: controller.reactionButtonClicked(eventId,
                                                                    modelData.key)
                    }
                }
            }
            Loader {
                id: buttonAreaLoader
                active: failed || // resendButton
                        (pending && marks !== EventStatus.ReachedServer && marks !== EventStatus.Departed) || // discardButton
                        (!pending && eventResolvedType == "m.room.create" && refId) || // goToPredecessorButton
                        (!pending && eventResolvedType == "m.room.tombstone") // goToSuccessorButton

                anchors.top: textField.top
                anchors.right: parent.right
                height: textField.height

                sourceComponent: buttonArea
            }
        }
    }

    // Components loaded on demand

    Component {
        id: buttonArea

        Item {
            TimelineItemToolButton {
                id: resendButton
                visible: failed
                anchors.right: discardButton.left
                text: qsTr("Resend")

                onClicked: room.retryMessage(eventId)
            }
            TimelineItemToolButton {
                id: discardButton
                visible: pending && marks !== EventStatus.ReachedServer
                         && marks !== EventStatus.Departed
                anchors.right: parent.right
                text: qsTr("Discard")

                onClicked: room.discardMessage(eventId)
            }
            TimelineItemToolButton {
                id: goToPredecessorButton
                visible: !pending && eventResolvedType == "m.room.create" && refId
                anchors.right: parent.right
                text: qsTr("Go to\nolder room")

                // TODO: Treat unjoined invite-only rooms specially
                onClicked: controller.resourceRequested(refId, "join")
            }
            TimelineItemToolButton {
                id: goToSuccessorButton
                visible: !pending && eventResolvedType == "m.room.tombstone"
                anchors.right: parent.right
                text: qsTr("Go to\nnew room")

                // TODO: Treat unjoined invite-only rooms specially
                onClicked: controller.resourceRequested(refId, "join")
            }
        }
    }

    Component {
        id: detailsArea

        Rectangle {
            height: childrenRect.height
            radius: 5

            color: defaultPalette.button
            border.color: defaultPalette.mid

            readonly property url evtLink:
                "https://matrix.to/#/" + room.id + "/" + eventId
            readonly property string sourceText: toolTip

            Item {
                id: detailsHeader
                width: parent.width
                height: childrenRect.height
                anchors.top: parent.top

                TextEdit {
                    text: "<" + time.toLocaleString(Qt.locale(), Locale.ShortFormat) + ">"
                    font.bold: true
                    font.family: settings.font.family
                    font.pointSize: settings.font.pointSize
                    renderType: settings.render_type
                    readOnly: true
                    selectByKeyboard: true; selectByMouse: true

                    anchors.top: eventTitle.bottom
                    anchors.left: parent.left
                    anchors.leftMargin: 3
                    z: 1
                }
                TextEdit {
                    id: eventTitle
                    text: "<a href=\"" + evtLink + "\">"+ eventId + "</a>"
                    textFormat: Text.RichText
                    font.bold: true
                    font.family: settings.font.family
                    font.pointSize: settings.font.pointSize
                    renderType: settings.render_type
                    horizontalAlignment: Text.AlignHCenter
                    readOnly: true
                    selectByKeyboard: true; selectByMouse: true

                    width: parent.width

                    onLinkActivated: Qt.openUrlExternally(link)

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: parent.hoveredLink ?
                                         Qt.PointingHandCursor :
                                         Qt.IBeamCursor
                        acceptedButtons: Qt.NoButton
                    }
                }
                TextEdit {
                    text: eventResolvedType
                    textFormat: Text.PlainText
                    font.bold: true
                    font.family: settings.font.family
                    font.pointSize: settings.font.pointSize
                    renderType: settings.render_type

                    anchors.top: eventTitle.bottom
                    anchors.right: parent.right
                    anchors.rightMargin: 3
                }

                TextEdit {
                    id: permalink
                    text: evtLink
                    font: settings.font
                    renderType: settings.render_type
                    width: 0; height: 0; visible: false
                }
            }

            ScrollView {
                anchors.top: detailsHeader.bottom
                width: parent.width
                height: Math.min(implicitContentHeight, chatView.height / 2)
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOn
                ScrollBar.vertical.policy: ScrollBar.AlwaysOn

                TextEdit {
                    text: sourceText
                    textFormat: Text.PlainText
                    readOnly: true;
                    font.family: "Monospace"
                    font.pointSize: settings.font.pointSize
                    renderType: settings.render_type
                    selectByKeyboard: true; selectByMouse: true
                }
            }
        }
    }
}
