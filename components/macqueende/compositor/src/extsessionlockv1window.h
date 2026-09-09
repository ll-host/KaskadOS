/*
    SPDX-FileCopyrightText: 2026 KaskadOS contributors

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#pragma once

#include "waylandwindow.h"

#include <QPointer>

namespace KWin
{

class ExtSessionLockSurfaceV1Interface;
class LogicalOutput;

class ExtSessionLockV1Window : public WaylandWindow
{
    Q_OBJECT

public:
    explicit ExtSessionLockV1Window(ExtSessionLockSurfaceV1Interface *shellSurface, LogicalOutput *output);

    ExtSessionLockSurfaceV1Interface *shellSurface() const;

    WindowType windowType() const override;
    bool isPlaceable() const override;
    bool isCloseable() const override;
    bool isMovable() const override;
    bool isMovableAcrossScreens() const override;
    bool isResizable() const override;
    bool wantsInput() const override;
    bool isLockScreen() const override;
    void destroyWindow() override;
    void closeWindow() override;

protected:
    Layer belongsToLayer() const override;
    bool acceptsFocus() const override;
    void moveResizeInternal(const RectF &rect, MoveResizeMode mode) override;
    void doSetNextTargetScale() override;
    void doSetPreferredBufferTransform() override;
    void doSetPreferredColorDescription() override;

private:
    void handleCommitted();
    void handleOutputGeometryChanged();
    void handleOutputRemoved(LogicalOutput *output);

    QPointer<ExtSessionLockSurfaceV1Interface> m_shellSurface;
    QPointer<LogicalOutput> m_desiredOutput;
    QSizeF m_requestedSize;
};

} // namespace KWin
