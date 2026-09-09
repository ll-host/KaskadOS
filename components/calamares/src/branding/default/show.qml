/* SPDX-License-Identifier: GPL-3.0-or-later */

import QtQuick 2.15
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Timer {
        interval: 6500
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    component BrandedSlide: Slide {
        required property string imageSource

        x: 0
        y: 0
        width: parent.width
        height: parent.height

        Rectangle {
            anchors.fill: parent
            color: "#101412"

            Image {
                anchors.fill: parent
                source: imageSource
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
            }
        }
    }

    BrandedSlide { imageSource: "slide-01.png" }
    BrandedSlide { imageSource: "slide-02.png" }
    BrandedSlide { imageSource: "slide-03.png" }
    BrandedSlide { imageSource: "slide-04.png" }

    function onActivate() {
        presentation.currentSlide = 0
    }

    function onLeave() {}
}
