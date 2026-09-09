/*
    SPDX-FileCopyrightText: 2026 KaskadOS contributors

    SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
*/

#include "extsessionlock_v1.h"

#include "display.h"
#include "output.h"
#include "surface.h"
#include "surface_p.h"

#include <QPointer>
#include <QQueue>
#include <QSet>

#include <algorithm>
#include <optional>

#include "qwayland-server-ext-session-lock-v1.h"

namespace KWin
{

static constexpr int s_version = 1;

class ExtSessionLockManagerV1InterfacePrivate : public QtWaylandServer::ext_session_lock_manager_v1
{
public:
    ExtSessionLockManagerV1InterfacePrivate(ExtSessionLockManagerV1Interface *q, Display *display)
        : QtWaylandServer::ext_session_lock_manager_v1(*display, s_version)
        , q(q)
    {
    }

    ExtSessionLockManagerV1Interface *q;

protected:
    void ext_session_lock_manager_v1_destroy(Resource *resource) override
    {
        wl_resource_destroy(resource->handle);
    }

    void ext_session_lock_manager_v1_lock(Resource *resource, uint32_t id) override
    {
        auto lock = new ExtSessionLockV1Interface(q, resource->client(), id, resource->version());
        Q_EMIT q->lockCreated(lock);
    }
};

struct ExtSessionLockSurfaceV1Configure {
    quint32 serial;
    QSizeF size;
};

class ExtSessionLockSurfaceV1Commit : public SurfaceAttachedState<ExtSessionLockSurfaceV1Commit>
{
public:
    std::optional<ExtSessionLockSurfaceV1Configure> acknowledgedConfigure;
};

class ExtSessionLockSurfaceV1InterfacePrivate : public SurfaceExtension<ExtSessionLockSurfaceV1InterfacePrivate, ExtSessionLockSurfaceV1Commit>,
                                                public QtWaylandServer::ext_session_lock_surface_v1
{
public:
    ExtSessionLockSurfaceV1InterfacePrivate(ExtSessionLockSurfaceV1Interface *q,
                                            SurfaceInterface *surface,
                                            OutputInterface *output,
                                            wl_resource *resource)
        : SurfaceExtension(surface)
        , QtWaylandServer::ext_session_lock_surface_v1(resource)
        , q(q)
        , output(output)
    {
    }

    void apply(ExtSessionLockSurfaceV1Commit *commit)
    {
        if (commit->acknowledgedConfigure) {
            acknowledgedConfigure = commit->acknowledgedConfigure;
            Q_EMIT q->configureAcknowledged(acknowledgedConfigure->serial);
        }

        if (!acknowledgedConfigure) {
            wl_resource_post_error(resource()->handle, error_commit_before_first_ack, "lock surface committed before its first configure was acknowledged");
            return;
        }
        if (!surface->buffer()) {
            wl_resource_post_error(resource()->handle, error_null_buffer, "lock surface committed a null buffer");
            return;
        }

        const QSizeF actualSize = surface->size();
        const QSizeF expectedSize = acknowledgedConfigure->size;
        if (!qFuzzyCompare(actualSize.width(), expectedSize.width()) || !qFuzzyCompare(actualSize.height(), expectedSize.height())) {
            wl_resource_post_error(resource()->handle,
                                   error_dimensions_mismatch,
                                   "lock surface size %.2fx%.2f does not match configure %.2fx%.2f",
                                   actualSize.width(),
                                   actualSize.height(),
                                   expectedSize.width(),
                                   expectedSize.height());
        }
    }

    ExtSessionLockSurfaceV1Interface *q;
    QPointer<OutputInterface> output;
    QQueue<ExtSessionLockSurfaceV1Configure> configures;
    std::optional<ExtSessionLockSurfaceV1Configure> acknowledgedConfigure;

protected:
    void ext_session_lock_surface_v1_destroy_resource(Resource *resource) override
    {
        Q_UNUSED(resource)
        Q_EMIT q->aboutToBeDestroyed();
        delete q;
    }

    void ext_session_lock_surface_v1_destroy(Resource *resource) override
    {
        wl_resource_destroy(resource->handle);
    }

    void ext_session_lock_surface_v1_ack_configure(Resource *resource, uint32_t serial) override
    {
        auto it = std::find_if(configures.cbegin(), configures.cend(), [serial](const auto &configure) {
            return configure.serial == serial;
        });
        if (it == configures.cend()) {
            wl_resource_post_error(resource->handle, error_invalid_serial, "unknown configure serial %u", serial);
            return;
        }

        const ExtSessionLockSurfaceV1Configure configure = *it;
        while (!configures.isEmpty()) {
            const auto candidate = configures.dequeue();
            if (candidate.serial == serial) {
                break;
            }
        }
        pending->acknowledgedConfigure = configure;
    }
};

class ExtSessionLockV1InterfacePrivate : public QtWaylandServer::ext_session_lock_v1
{
public:
    ExtSessionLockV1InterfacePrivate(ExtSessionLockV1Interface *q, wl_client *client, uint32_t id, int version)
        : QtWaylandServer::ext_session_lock_v1(client, id, version)
        , q(q)
    {
    }

    ExtSessionLockV1Interface *q;
    QSet<OutputInterface *> outputs;
    bool locked = false;
    bool finished = false;

protected:
    void ext_session_lock_v1_destroy_resource(Resource *resource) override
    {
        Q_UNUSED(resource)
        Q_EMIT q->aboutToBeDestroyed();
        delete q;
    }

    void ext_session_lock_v1_destroy(Resource *resource) override
    {
        if (locked) {
            wl_resource_post_error(resource->handle, error_invalid_destroy, "a locked session lock must be released with unlock_and_destroy");
            return;
        }
        wl_resource_destroy(resource->handle);
    }

    void ext_session_lock_v1_get_lock_surface(Resource *resource, uint32_t id, wl_resource *surfaceResource, wl_resource *outputResource) override
    {
        SurfaceInterface *surface = SurfaceInterface::get(surfaceResource);
        OutputInterface *output = OutputInterface::get(outputResource);

        if (!surface || !output || output->isRemoved()) {
            wl_resource_post_error(resource->handle, WL_DISPLAY_ERROR_INVALID_OBJECT, "invalid surface or output for lock surface");
            return;
        }
        if (outputs.contains(output)) {
            wl_resource_post_error(resource->handle, error_duplicate_output, "the output already has a lock surface");
            return;
        }
        if (surface->role()) {
            wl_resource_post_error(resource->handle, error_role, "the wl_surface already has role %s", surface->role()->name().constData());
            return;
        }
        const SurfaceInterfacePrivate *surfacePrivate = SurfaceInterfacePrivate::get(surface);
        const bool hasPendingBuffer = (surfacePrivate->pending->committed & SurfaceState::Field::Buffer) && surfacePrivate->pending->buffer;
        if (surfacePrivate->committedOnce || surface->buffer() || hasPendingBuffer) {
            wl_resource_post_error(resource->handle, error_already_constructed, "the wl_surface was already committed or has a buffer");
            return;
        }

        wl_resource *lockSurfaceResource = wl_resource_create(resource->client(), &ext_session_lock_surface_v1_interface, resource->version(), id);
        if (!lockSurfaceResource) {
            wl_resource_post_no_memory(resource->handle);
            return;
        }

        surface->setRole(ExtSessionLockSurfaceV1Interface::role());
        outputs.insert(output);

        auto lockSurface = new ExtSessionLockSurfaceV1Interface(q, surface, output, lockSurfaceResource);
        QObject::connect(lockSurface, &ExtSessionLockSurfaceV1Interface::aboutToBeDestroyed, q, [this, output]() {
            outputs.remove(output);
        });
        Q_EMIT q->surfaceCreated(lockSurface);
    }

    void ext_session_lock_v1_unlock_and_destroy(Resource *resource) override
    {
        if (!locked) {
            wl_resource_post_error(resource->handle, error_invalid_unlock, "unlock requested before the locked event");
            return;
        }
        Q_EMIT q->unlockRequested();
        wl_resource_destroy(resource->handle);
    }
};

ExtSessionLockManagerV1Interface::ExtSessionLockManagerV1Interface(Display *display, QObject *parent)
    : QObject(parent)
    , d(std::make_unique<ExtSessionLockManagerV1InterfacePrivate>(this, display))
{
}

ExtSessionLockManagerV1Interface::~ExtSessionLockManagerV1Interface() = default;

ExtSessionLockV1Interface::ExtSessionLockV1Interface(ExtSessionLockManagerV1Interface *manager, wl_client *client, uint32_t id, int version)
    : QObject(manager)
    , d(std::make_unique<ExtSessionLockV1InterfacePrivate>(this, client, id, version))
{
}

ExtSessionLockV1Interface::~ExtSessionLockV1Interface() = default;

void ExtSessionLockV1Interface::sendLocked()
{
    if (d->locked || d->finished) {
        return;
    }
    d->locked = true;
    d->send_locked();
}

void ExtSessionLockV1Interface::sendFinished()
{
    if (d->locked || d->finished) {
        return;
    }
    d->finished = true;
    d->send_finished();
}

bool ExtSessionLockV1Interface::isLocked() const
{
    return d->locked;
}

bool ExtSessionLockV1Interface::isFinished() const
{
    return d->finished;
}

ExtSessionLockSurfaceV1Interface::ExtSessionLockSurfaceV1Interface(ExtSessionLockV1Interface *lock,
                                                                   SurfaceInterface *surface,
                                                                   OutputInterface *output,
                                                                   wl_resource *resource)
    : QObject(lock->parent())
    , d(std::make_unique<ExtSessionLockSurfaceV1InterfacePrivate>(this, surface, output, resource))
{
}

ExtSessionLockSurfaceV1Interface::~ExtSessionLockSurfaceV1Interface() = default;

SurfaceRole *ExtSessionLockSurfaceV1Interface::role()
{
    static SurfaceRole role(QByteArrayLiteral("ext_session_lock_surface_v1"));
    return &role;
}

SurfaceInterface *ExtSessionLockSurfaceV1Interface::surface() const
{
    return d->surface;
}

OutputInterface *ExtSessionLockSurfaceV1Interface::output() const
{
    return d->output;
}

QSizeF ExtSessionLockSurfaceV1Interface::configuredSize() const
{
    return d->acknowledgedConfigure ? d->acknowledgedConfigure->size : QSizeF();
}

quint32 ExtSessionLockSurfaceV1Interface::sendConfigure(const QSizeF &size)
{
    const quint32 serial = d->output->display()->nextSerial();
    const QSize nativeSize = (size * d->surface->compositorToClientScale()).toSize();
    d->configures.enqueue({serial, size});
    d->send_configure(serial, nativeSize.width(), nativeSize.height());
    return serial;
}

} // namespace KWin

#include "moc_extsessionlock_v1.cpp"
