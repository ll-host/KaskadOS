/*
    SPDX-FileCopyrightText: 2026 KaskadOS contributors

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "extsessionlockv1integration.h"

#include "core/backendoutput.h"
#include "core/output.h"
#include "core/renderloop.h"
#include "extsessionlockv1window.h"
#include "wayland/extsessionlock_v1.h"
#include "wayland/output.h"
#include "wayland_server.h"
#include "workspace.h"

#include <utility>

namespace KWin
{

ExtSessionLockV1Integration::ExtSessionLockV1Integration(QObject *parent)
    : WaylandShellIntegration(parent)
    , m_manager(new ExtSessionLockManagerV1Interface(waylandServer()->display(), this))
{
    connect(m_manager, &ExtSessionLockManagerV1Interface::lockCreated, this, &ExtSessionLockV1Integration::handleLockCreated);
    connect(workspace(), &Workspace::outputAdded, this, [this](LogicalOutput *output) {
        if (m_locked) {
            trackOutput(output);
        }
    });
    connect(workspace(), &Workspace::outputRemoved, this, [this](LogicalOutput *output) {
        m_presentedOutputs.remove(output);
        maybeSendLocked();
    });
}

bool ExtSessionLockV1Integration::isLocked() const
{
    return m_locked;
}

void ExtSessionLockV1Integration::handleLockCreated(ExtSessionLockV1Interface *lock)
{
    if ((m_lock && !m_orphaned) || waylandServer()->isNativeScreenLocked()) {
        lock->sendFinished();
        return;
    }

    m_lock = lock;
    m_orphaned = false;
    resetOutputTracking();
    ++m_lockGeneration;

    connect(lock, &ExtSessionLockV1Interface::surfaceCreated, this, [this, lock](ExtSessionLockSurfaceV1Interface *surface) {
        createWindow(lock, surface);
    });
    connect(lock, &ExtSessionLockV1Interface::unlockRequested, this, [this, lock]() {
        handleUnlockRequested(lock);
    });
    connect(lock, &ExtSessionLockV1Interface::aboutToBeDestroyed, this, [this, lock]() {
        handleLockDestroyed(lock);
    });

    if (!m_locked) {
        Q_EMIT aboutToLock();
        m_locked = true;
        Q_EMIT lockStateChanged();
    }

    for (LogicalOutput *output : workspace()->outputs()) {
        trackOutput(output);
    }
    maybeSendLocked();
}

void ExtSessionLockV1Integration::handleLockDestroyed(ExtSessionLockV1Interface *lock)
{
    if (m_lock != lock) {
        return;
    }

    m_lock = nullptr;
    destroyWindows();

    if (lock->isLocked()) {
        // If the locker crashes after acquiring the lock, keep the desktop
        // hidden and accept a new locker as a secure recovery path.
        m_orphaned = true;
        return;
    }

    releaseLock();
}

void ExtSessionLockV1Integration::handleUnlockRequested(ExtSessionLockV1Interface *lock)
{
    if (m_lock != lock || !lock->isLocked()) {
        return;
    }

    m_lock = nullptr;
    destroyWindows();
    releaseLock();
}

void ExtSessionLockV1Integration::createWindow(ExtSessionLockV1Interface *lock, ExtSessionLockSurfaceV1Interface *surface)
{
    if (m_lock != lock || !m_locked || !surface->output() || surface->output()->isRemoved()) {
        return;
    }

    auto window = new ExtSessionLockV1Window(surface, surface->output()->handle());
    m_windows.append(window);
    connect(window, &Window::closed, this, [this, window]() {
        m_windows.removeAll(QPointer<ExtSessionLockV1Window>(window));
    });
    Q_EMIT windowCreated(window);
}

void ExtSessionLockV1Integration::trackOutput(LogicalOutput *output)
{
    if (!output || !m_locked) {
        return;
    }

    const quint64 generation = m_lockGeneration;
    const QPointer<LogicalOutput> outputGuard = output;
    BackendOutput *backendOutput = output->backendOutput();
    if (backendOutput->dpmsMode() == BackendOutput::DpmsMode::Off) {
        m_presentedOutputs.insert(output);
        maybeSendLocked();
        return;
    }

    m_dpmsConnections.append(connect(backendOutput, &BackendOutput::dpmsModeChanged, this, [this, outputGuard, backendOutput, generation]() {
        if (!m_locked || generation != m_lockGeneration || !outputGuard || !workspace()->outputs().contains(outputGuard.data())
            || backendOutput->dpmsMode() != BackendOutput::DpmsMode::Off) {
            return;
        }
        m_presentedOutputs.insert(outputGuard.data());
        maybeSendLocked();
    }));

    RenderLoop *renderLoop = backendOutput->renderLoop();
    connect(
        renderLoop,
        &RenderLoop::framePresented,
        this,
        [this, outputGuard, generation]() {
            if (!m_locked || generation != m_lockGeneration || !outputGuard || !workspace()->outputs().contains(outputGuard.data())) {
                return;
            }
            m_presentedOutputs.insert(outputGuard.data());
            maybeSendLocked();
        },
        Qt::SingleShotConnection);
    renderLoop->scheduleRepaint();
}

void ExtSessionLockV1Integration::maybeSendLocked()
{
    if (!m_lock || m_lock->isLocked() || m_lock->isFinished()) {
        return;
    }

    const QList<LogicalOutput *> outputs = workspace()->outputs();
    for (LogicalOutput *output : outputs) {
        if (!m_presentedOutputs.contains(output)) {
            return;
        }
    }
    m_lock->sendLocked();
}

void ExtSessionLockV1Integration::resetOutputTracking()
{
    for (const QMetaObject::Connection &connection : std::as_const(m_dpmsConnections)) {
        disconnect(connection);
    }
    m_dpmsConnections.clear();
    m_presentedOutputs.clear();
}

void ExtSessionLockV1Integration::destroyWindows()
{
    const auto windows = std::exchange(m_windows, QList<QPointer<ExtSessionLockV1Window>>());
    resetOutputTracking();
    for (const QPointer<ExtSessionLockV1Window> &window : windows) {
        if (window) {
            window->destroyWindow();
        }
    }
}

void ExtSessionLockV1Integration::releaseLock()
{
    m_orphaned = false;
    if (!m_locked) {
        return;
    }
    m_locked = false;
    Q_EMIT lockStateChanged();
}

} // namespace KWin

#include "moc_extsessionlockv1integration.cpp"
