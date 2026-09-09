/*
    SPDX-License-Identifier: LGPL-2.0-or-later
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
*/

#include "macqueenscreenchooserbridge.h"
#include "screenchooserdialog.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QUuid>

using namespace Qt::StringLiterals;

MacqueenScreenChooserBridge::MacqueenScreenChooserBridge(QObject *parent)
    : QObject(parent)
{
    QDBusConnection::sessionBus().registerObject(
        u"/org/macqueen/ScreenCastChooser1"_s,
        this,
        QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals);
}

MacqueenScreenChooserBridge *MacqueenScreenChooserBridge::self()
{
    static auto bridge = new MacqueenScreenChooserBridge;
    return bridge;
}

bool MacqueenScreenChooserBridge::request(ScreenChooserDialog *dialog, const QString &title, const QString &optionsJson)
{
    const auto bus = QDBusConnection::sessionBus().interface();
    if (!bus || !bus->isServiceRegistered(u"org.macqueen.MolniyaShell1"_s)) {
        return false;
    }

    const QString requestId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_requests.insert(requestId, dialog);
    connect(dialog, &QObject::destroyed, this, [this, dialog] {
        forget(dialog);
    });
    Q_EMIT selectionRequested(requestId, title, optionsJson);
    return true;
}

void MacqueenScreenChooserBridge::forget(ScreenChooserDialog *dialog)
{
    for (auto it = m_requests.begin(); it != m_requests.end();) {
        if (it.value() == dialog) {
            it = m_requests.erase(it);
        } else {
            ++it;
        }
    }
}

bool MacqueenScreenChooserBridge::select(const QString &requestId, const QString &kind, const QString &id, bool allowRestore)
{
    if (!isMolniyaCaller()) {
        return false;
    }
    ScreenChooserDialog *dialog = m_requests.take(requestId);
    if (!dialog || !dialog->selectExternal(kind, id, allowRestore)) {
        return false;
    }
    dialog->accept();
    return true;
}

bool MacqueenScreenChooserBridge::cancel(const QString &requestId)
{
    if (!isMolniyaCaller()) {
        return false;
    }
    ScreenChooserDialog *dialog = m_requests.take(requestId);
    if (!dialog) {
        return false;
    }
    dialog->reject();
    return true;
}

bool MacqueenScreenChooserBridge::isMolniyaCaller() const
{
    if (!calledFromDBus()) {
        return true;
    }
    const auto bus = QDBusConnection::sessionBus().interface();
    if (!bus) {
        return false;
    }
    return bus->serviceOwner(u"org.macqueen.MolniyaShell1"_s).value() == message().service();
}
