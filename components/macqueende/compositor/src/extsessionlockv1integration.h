/*
    SPDX-FileCopyrightText: 2026 KaskadOS contributors

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#pragma once

#include "waylandshellintegration.h"

#include <QList>
#include <QMetaObject>
#include <QPointer>
#include <QSet>

namespace KWin
{

class ExtSessionLockManagerV1Interface;
class ExtSessionLockSurfaceV1Interface;
class ExtSessionLockV1Interface;
class ExtSessionLockV1Window;
class LogicalOutput;

class ExtSessionLockV1Integration : public WaylandShellIntegration
{
    Q_OBJECT

public:
    explicit ExtSessionLockV1Integration(QObject *parent = nullptr);

    bool isLocked() const;

Q_SIGNALS:
    void aboutToLock();
    void lockStateChanged();

private:
    void handleLockCreated(ExtSessionLockV1Interface *lock);
    void handleLockDestroyed(ExtSessionLockV1Interface *lock);
    void handleUnlockRequested(ExtSessionLockV1Interface *lock);
    void createWindow(ExtSessionLockV1Interface *lock, ExtSessionLockSurfaceV1Interface *surface);
    void trackOutput(LogicalOutput *output);
    void maybeSendLocked();
    void resetOutputTracking();
    void destroyWindows();
    void releaseLock();

    ExtSessionLockManagerV1Interface *m_manager;
    QPointer<ExtSessionLockV1Interface> m_lock;
    QList<QPointer<ExtSessionLockV1Window>> m_windows;
    QList<QMetaObject::Connection> m_dpmsConnections;
    QSet<LogicalOutput *> m_presentedOutputs;
    quint64 m_lockGeneration = 0;
    bool m_locked = false;
    bool m_orphaned = false;
};

} // namespace KWin
