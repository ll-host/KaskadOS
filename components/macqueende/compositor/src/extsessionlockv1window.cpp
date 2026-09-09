/*
    SPDX-FileCopyrightText: 2026 KaskadOS contributors

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "extsessionlockv1window.h"

#include "core/backendoutput.h"
#include "core/output.h"
#include "wayland/extsessionlock_v1.h"
#include "wayland/surface.h"
#include "wayland_server.h"
#include "workspace.h"

namespace KWin
{

ExtSessionLockV1Window::ExtSessionLockV1Window(ExtSessionLockSurfaceV1Interface *shellSurface, LogicalOutput *output)
    : WaylandWindow(shellSurface->surface())
    , m_shellSurface(shellSurface)
    , m_desiredOutput(output)
{
    setOutput(output);
    setMoveResizeOutput(output);
    setSkipSwitcher(true);
    setSkipPager(true);
    setSkipTaskbar(true);

    connect(shellSurface, &ExtSessionLockSurfaceV1Interface::aboutToBeDestroyed, this, &ExtSessionLockV1Window::destroyWindow);
    connect(shellSurface->surface(), &SurfaceInterface::aboutToBeDestroyed, this, &ExtSessionLockV1Window::destroyWindow);
    connect(shellSurface->surface(), &SurfaceInterface::committed, this, &ExtSessionLockV1Window::handleCommitted);
    connect(output, &LogicalOutput::geometryChanged, this, &ExtSessionLockV1Window::handleOutputGeometryChanged);
    connect(workspace(), &Workspace::outputRemoved, this, &ExtSessionLockV1Window::handleOutputRemoved);

    const RectF geometry = output->geometryF();
    m_requestedSize = geometry.size();
    shellSurface->sendConfigure(m_requestedSize);
    updateGeometry(geometry);
}

ExtSessionLockSurfaceV1Interface *ExtSessionLockV1Window::shellSurface() const
{
    return m_shellSurface;
}

WindowType ExtSessionLockV1Window::windowType() const
{
    return WindowType::Utility;
}

bool ExtSessionLockV1Window::isPlaceable() const
{
    return false;
}

bool ExtSessionLockV1Window::isCloseable() const
{
    return false;
}

bool ExtSessionLockV1Window::isMovable() const
{
    return false;
}

bool ExtSessionLockV1Window::isMovableAcrossScreens() const
{
    return false;
}

bool ExtSessionLockV1Window::isResizable() const
{
    return false;
}

bool ExtSessionLockV1Window::wantsInput() const
{
    return acceptsFocus() && readyForPainting();
}

bool ExtSessionLockV1Window::isLockScreen() const
{
    return true;
}

Layer ExtSessionLockV1Window::belongsToLayer() const
{
    return OverlayLayer;
}

bool ExtSessionLockV1Window::acceptsFocus() const
{
    return !isDeleted();
}

void ExtSessionLockV1Window::moveResizeInternal(const RectF &rect, MoveResizeMode mode)
{
    Q_UNUSED(mode)

    if (m_shellSurface && rect.size() != m_requestedSize) {
        m_requestedSize = rect.size();
        m_shellSurface->sendConfigure(m_requestedSize);
    }
    updateGeometry(rect);
}

void ExtSessionLockV1Window::doSetNextTargetScale()
{
    if (isDeleted()) {
        return;
    }
    surface()->setPreferredBufferScale(nextTargetScale());
    setTargetScale(nextTargetScale());
    handleOutputGeometryChanged();
}

void ExtSessionLockV1Window::doSetPreferredBufferTransform()
{
    if (!isDeleted()) {
        surface()->setPreferredBufferTransform(preferredBufferTransform());
    }
}

void ExtSessionLockV1Window::doSetPreferredColorDescription()
{
    if (!isDeleted()) {
        surface()->setPreferredColorDescription(preferredColorDescription());
    }
}

void ExtSessionLockV1Window::handleCommitted()
{
    if (!m_desiredOutput || !surface()->buffer()) {
        return;
    }

    updateGeometry(m_desiredOutput->geometryF());
    markAsMapped();
    workspace()->activateWindow(this, true);
    m_desiredOutput->backendOutput()->renderLoop()->scheduleRepaint();
}

void ExtSessionLockV1Window::handleOutputGeometryChanged()
{
    if (!isDeleted() && m_desiredOutput) {
        moveResize(m_desiredOutput->geometryF());
    }
}

void ExtSessionLockV1Window::handleOutputRemoved(LogicalOutput *output)
{
    if (output == m_desiredOutput) {
        destroyWindow();
    }
}

void ExtSessionLockV1Window::destroyWindow()
{
    if (isDeleted()) {
        return;
    }

    if (m_shellSurface) {
        m_shellSurface->disconnect(this);
    }
    surface()->disconnect(this);
    if (m_desiredOutput) {
        m_desiredOutput->disconnect(this);
    }
    disconnect(workspace(), &Workspace::outputRemoved, this, &ExtSessionLockV1Window::handleOutputRemoved);

    markAsDeleted();
    Q_EMIT closed();
    cleanTabBox();
    StackingUpdatesBlocker blocker(workspace());
    cleanGrouping();
    waylandServer()->removeWindow(this);
    unref();
}

void ExtSessionLockV1Window::closeWindow()
{
    // A compositor must not dismiss a secure session-lock surface. It remains
    // active until the locker authenticates and requests unlock_and_destroy.
}

} // namespace KWin

#include "moc_extsessionlockv1window.cpp"
