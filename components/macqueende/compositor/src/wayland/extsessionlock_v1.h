/*
    SPDX-FileCopyrightText: 2026 KaskadOS contributors

    SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
*/

#pragma once

#include "kwin_export.h"

#include <QObject>
#include <QSizeF>

#include <cstdint>
#include <memory>

struct wl_client;
struct wl_resource;

namespace KWin
{

class Display;
class ExtSessionLockManagerV1InterfacePrivate;
class ExtSessionLockV1Interface;
class ExtSessionLockV1InterfacePrivate;
class ExtSessionLockSurfaceV1Interface;
class ExtSessionLockSurfaceV1InterfacePrivate;
class OutputInterface;
class SurfaceInterface;
class SurfaceRole;

class KWIN_EXPORT ExtSessionLockManagerV1Interface : public QObject
{
    Q_OBJECT

public:
    explicit ExtSessionLockManagerV1Interface(Display *display, QObject *parent = nullptr);
    ~ExtSessionLockManagerV1Interface() override;

Q_SIGNALS:
    void lockCreated(ExtSessionLockV1Interface *lock);

private:
    std::unique_ptr<ExtSessionLockManagerV1InterfacePrivate> d;
};

class KWIN_EXPORT ExtSessionLockV1Interface : public QObject
{
    Q_OBJECT

public:
    ~ExtSessionLockV1Interface() override;

    void sendLocked();
    void sendFinished();
    bool isLocked() const;
    bool isFinished() const;

Q_SIGNALS:
    void surfaceCreated(KWin::ExtSessionLockSurfaceV1Interface *surface);
    void unlockRequested();
    void aboutToBeDestroyed();

private:
    ExtSessionLockV1Interface(ExtSessionLockManagerV1Interface *manager, wl_client *client, uint32_t id, int version);

    std::unique_ptr<ExtSessionLockV1InterfacePrivate> d;
    friend class ExtSessionLockManagerV1InterfacePrivate;
    friend class ExtSessionLockV1InterfacePrivate;
};

class KWIN_EXPORT ExtSessionLockSurfaceV1Interface : public QObject
{
    Q_OBJECT

public:
    ~ExtSessionLockSurfaceV1Interface() override;

    static SurfaceRole *role();

    SurfaceInterface *surface() const;
    OutputInterface *output() const;
    QSizeF configuredSize() const;
    quint32 sendConfigure(const QSizeF &size);

Q_SIGNALS:
    void configureAcknowledged(quint32 serial);
    void aboutToBeDestroyed();

private:
    ExtSessionLockSurfaceV1Interface(ExtSessionLockV1Interface *lock, SurfaceInterface *surface, OutputInterface *output, wl_resource *resource);

    std::unique_ptr<ExtSessionLockSurfaceV1InterfacePrivate> d;
    friend class ExtSessionLockV1InterfacePrivate;
};

} // namespace KWin
