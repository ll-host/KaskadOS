/*
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
    SPDX-License-Identifier: GPL-3.0-or-later
*/

#include "macqueenipcclient.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QJsonDocument>

namespace
{

template<typename T>
T converted(const QVariant &value)
{
    if (value.canConvert<QDBusArgument>()) {
        return qdbus_cast<T>(value.value<QDBusArgument>());
    }
    if (value.canConvert<T>()) {
        return value.value<T>();
    }
    return {};
}

QVariant unpackDbusValue(const QVariant &value);

QVariantMap unpackDbusMap(const QVariantMap &raw)
{
    QVariantMap result;
    for (auto it = raw.cbegin(); it != raw.cend(); ++it) {
        result.insert(it.key(), unpackDbusValue(it.value()));
    }
    return result;
}

QVariantList unpackDbusList(const QVariantList &raw)
{
    QVariantList result;
    result.reserve(raw.size());
    for (const QVariant &entry : raw) {
        result.append(unpackDbusValue(entry));
    }
    return result;
}

QVariant unpackDbusValue(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QDBusVariant>()) {
        return unpackDbusValue(value.value<QDBusVariant>().variant());
    }

    if (value.canConvert<QDBusArgument>()) {
        const QDBusArgument argument = value.value<QDBusArgument>();
        switch (argument.currentType()) {
        case QDBusArgument::MapType:
            return unpackDbusMap(qdbus_cast<QVariantMap>(argument));
        case QDBusArgument::ArrayType:
            if (argument.currentSignature() == QStringLiteral("as")) {
                return qdbus_cast<QStringList>(argument);
            }
            return unpackDbusList(qdbus_cast<QVariantList>(argument));
        default:
            return unpackDbusValue(argument.asVariant());
        }
    }

    if (value.metaType() == QMetaType::fromType<QVariantMap>()) {
        return unpackDbusMap(value.toMap());
    }
    if (value.metaType() == QMetaType::fromType<QVariantList>()) {
        return unpackDbusList(value.toList());
    }
    return value;
}

QVariantList mapList(const QVariant &value)
{
    const QVariantList raw = converted<QVariantList>(value);
    QVariantList result;
    result.reserve(raw.size());
    for (const QVariant &entry : raw) {
        if (entry.canConvert<QDBusArgument>()) {
            result.append(unpackDbusMap(qdbus_cast<QVariantMap>(entry.value<QDBusArgument>())));
        } else {
            result.append(unpackDbusMap(entry.toMap()));
        }
    }
    return result;
}

}

MacqueenIpcClient::MacqueenIpcClient(QObject *parent)
    : QObject(parent)
    , m_watcher(QString::fromLatin1(Service),
                QDBusConnection::sessionBus(),
                QDBusServiceWatcher::WatchForRegistration | QDBusServiceWatcher::WatchForUnregistration)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, &MacqueenIpcClient::handleServiceRegistered);
    connect(&m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, &MacqueenIpcClient::handleServiceUnregistered);

    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("windowAdded"), this, SLOT(handleWindowAdded(QString)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("windowRemoved"), this, SLOT(handleWindowRemoved(QString)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("windowChanged"), this, SLOT(handleWindowChanged(QString,QStringList)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("activeWindowChanged"), this, SLOT(handleActiveWindowChanged(QString)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("outputsChanged"), this, SLOT(refreshOutputs()));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("workspacesChanged"), this, SLOT(refreshWorkspaces()));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("keyboardLayoutsChanged"), this, SLOT(refreshKeyboardLayouts()));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("keyboardLayoutShortcutChanged"), this, SLOT(handleKeyboardLayoutShortcutChanged(QString)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("overviewRequested"), this, SLOT(handleOverviewRequested(QString)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("screenshotRequested"), this, SIGNAL(screenshotRequested()));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("screenshotShortcutChanged"), this, SLOT(handleScreenshotShortcutChanged(QString)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("microphoneShortcutChanged"), this, SLOT(handleMicrophoneShortcutChanged(QString)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("microphoneShortcutKeyChanged"), this, SIGNAL(microphoneShortcutKeyChanged(bool)));
    bus.connect(QString::fromLatin1(Service), QString::fromLatin1(Path), QString::fromLatin1(Interface),
                QStringLiteral("shortcutCaptured"), this, SIGNAL(shortcutCaptured(QString)));
    bus.interface()->registerService(QStringLiteral("org.macqueen.MolniyaShell1"),
                                     QDBusConnectionInterface::DontQueueService,
                                     QDBusConnectionInterface::DontAllowReplacement);
    bus.connect(QStringLiteral("org.freedesktop.impl.portal.desktop.macqueen"),
                QStringLiteral("/org/macqueen/ScreenCastChooser1"),
                QStringLiteral("org.macqueen.ScreenCastChooser1"),
                QStringLiteral("selectionRequested"),
                this,
                SLOT(handleScreenCastSelectionRequested(QString,QString,QString)));

    const QDBusReply<bool> registered = bus.interface()->isServiceRegistered(QString::fromLatin1(Service));
    if (registered.isValid() && registered.value()) {
        handleServiceRegistered();
    }
}

bool MacqueenIpcClient::available() const
{
    return m_available;
}

uint MacqueenIpcClient::protocolVersion() const
{
    return m_protocolVersion;
}

QString MacqueenIpcClient::compositorVersion() const
{
    return m_compositorVersion;
}

QVariantMap MacqueenIpcClient::activeWindow() const
{
    return m_activeWindow;
}

QVariantList MacqueenIpcClient::windows() const
{
    return m_windows;
}

QVariantList MacqueenIpcClient::outputs() const
{
    return m_outputs;
}

QVariantList MacqueenIpcClient::workspaces() const
{
    return m_workspaces;
}

QVariantList MacqueenIpcClient::keyboardLayouts() const
{
    return m_keyboardLayouts;
}

QVariantList MacqueenIpcClient::availableKeyboardLayouts() const
{
    return m_availableKeyboardLayouts;
}

uint MacqueenIpcClient::currentKeyboardLayout() const
{
    return m_currentKeyboardLayout;
}

QString MacqueenIpcClient::keyboardLayoutShortcut() const
{
    return m_keyboardLayoutShortcut;
}

QString MacqueenIpcClient::screenshotShortcut() const
{
    return m_screenshotShortcut;
}

QString MacqueenIpcClient::microphoneShortcut() const
{
    return m_microphoneShortcut;
}

void MacqueenIpcClient::refresh()
{
    if (!m_available) {
        return;
    }
    refreshVersions();
    refreshWindows();
    refreshActiveWindow();
    refreshOutputs();
    refreshWorkspaces();
    refreshKeyboardLayouts();
    if (m_protocolVersion >= 10) {
        handleKeyboardLayoutShortcutChanged(call(QStringLiteral("keyboardLayoutShortcut")).toString());
    } else {
        handleKeyboardLayoutShortcutChanged({});
    }
    if (m_protocolVersion >= 4) {
        handleScreenshotShortcutChanged(call(QStringLiteral("screenshotShortcut")).toString());
    } else {
        handleScreenshotShortcutChanged({});
    }
    handleMicrophoneShortcutChanged(m_protocolVersion >= 13
        ? call(QStringLiteral("microphoneShortcut")).toString() : QString());
}

bool MacqueenIpcClient::activateWorkspace(const QString &id)
{
    return call(QStringLiteral("activateWorkspace"), {id}).toBool();
}

QString MacqueenIpcClient::createWorkspace(uint position, const QString &name)
{
    return call(QStringLiteral("createWorkspace"), {position, name}).toString();
}

bool MacqueenIpcClient::removeWorkspace(const QString &id)
{
    return call(QStringLiteral("removeWorkspace"), {id}).toBool();
}

bool MacqueenIpcClient::renameWorkspace(const QString &id, const QString &name)
{
    return call(QStringLiteral("renameWorkspace"), {id, name}).toBool();
}

bool MacqueenIpcClient::activateWindow(const QString &id)
{
    return call(QStringLiteral("activateWindow"), {id}).toBool();
}

bool MacqueenIpcClient::closeWindow(const QString &id)
{
    return call(QStringLiteral("closeWindow"), {id}).toBool();
}

bool MacqueenIpcClient::setWindowMinimized(const QString &id, bool minimized)
{
    return call(QStringLiteral("setWindowMinimized"), {id, minimized}).toBool();
}

bool MacqueenIpcClient::setWindowFullscreen(const QString &id, bool fullscreen)
{
    return call(QStringLiteral("setWindowFullscreen"), {id, fullscreen}).toBool();
}

bool MacqueenIpcClient::moveWindowToWorkspace(const QString &windowId, const QString &workspaceId)
{
    return call(QStringLiteral("moveWindowToWorkspace"), {windowId, workspaceId}).toBool();
}

QString MacqueenIpcClient::outputAtCursor() const
{
    if (m_protocolVersion < 8) {
        return {};
    }
    return call(QStringLiteral("outputAtCursor")).toString();
}

bool MacqueenIpcClient::applyOutputConfiguration(const QVariantList &outputs)
{
    if (!m_available || m_protocolVersion < 11 || outputs.isEmpty()) {
        return false;
    }
    const bool applied = m_protocolVersion >= 12
        ? call(QStringLiteral("applyOutputConfigurationJson"), {
            QString::fromUtf8(QJsonDocument::fromVariant(outputs).toJson(QJsonDocument::Compact))
        }).toBool()
        : call(QStringLiteral("applyOutputConfiguration"), {outputs}).toBool();
    if (applied) {
        refreshOutputs();
    }
    return applied;
}

bool MacqueenIpcClient::setKeyboardLayouts(const QStringList &layouts)
{
    const bool changed = call(QStringLiteral("setKeyboardLayouts"), {layouts}).toBool();
    if (changed) {
        refreshKeyboardLayouts();
    }
    return changed;
}

bool MacqueenIpcClient::setCurrentKeyboardLayout(uint index)
{
    const bool changed = call(QStringLiteral("setCurrentKeyboardLayout"), {index}).toBool();
    if (changed) {
        refreshKeyboardLayouts();
    }
    return changed;
}

bool MacqueenIpcClient::setKeyboardLayoutShortcut(const QString &shortcut)
{
    if (!m_available || m_protocolVersion < 10) {
        return false;
    }
    const bool changed = call(QStringLiteral("setKeyboardLayoutShortcut"), {shortcut}).toBool();
    if (changed) {
        handleKeyboardLayoutShortcutChanged(call(QStringLiteral("keyboardLayoutShortcut")).toString());
    }
    return changed;
}

bool MacqueenIpcClient::resetKeyboardLayoutShortcut()
{
    if (!m_available || m_protocolVersion < 10) {
        return false;
    }
    const bool changed = call(QStringLiteral("resetKeyboardLayoutShortcut")).toBool();
    if (changed) {
        handleKeyboardLayoutShortcutChanged(call(QStringLiteral("keyboardLayoutShortcut")).toString());
    }
    return changed;
}

bool MacqueenIpcClient::submitScreenCastSelection(const QString &requestId, const QString &kind, const QString &id, bool allowRestore)
{
    QDBusInterface chooser(QStringLiteral("org.freedesktop.impl.portal.desktop.macqueen"),
                           QStringLiteral("/org/macqueen/ScreenCastChooser1"),
                           QStringLiteral("org.macqueen.ScreenCastChooser1"),
                           QDBusConnection::sessionBus());
    const QDBusReply<bool> reply = chooser.call(QStringLiteral("select"), requestId, kind, id, allowRestore);
    return reply.isValid() && reply.value();
}

bool MacqueenIpcClient::cancelScreenCastSelection(const QString &requestId)
{
    QDBusInterface chooser(QStringLiteral("org.freedesktop.impl.portal.desktop.macqueen"),
                           QStringLiteral("/org/macqueen/ScreenCastChooser1"),
                           QStringLiteral("org.macqueen.ScreenCastChooser1"),
                           QDBusConnection::sessionBus());
    const QDBusReply<bool> reply = chooser.call(QStringLiteral("cancel"), requestId);
    return reply.isValid() && reply.value();
}

bool MacqueenIpcClient::setScreenshotShortcut(const QString &shortcut)
{
    if (!m_available || m_protocolVersion < 4) {
        return false;
    }
    const bool changed = call(QStringLiteral("setScreenshotShortcut"), {shortcut}).toBool();
    if (changed) {
        handleScreenshotShortcutChanged(call(QStringLiteral("screenshotShortcut")).toString());
    }
    return changed;
}

bool MacqueenIpcClient::setMicrophoneShortcut(const QString &shortcut)
{
    if (!m_available || m_protocolVersion < 13) {
        return false;
    }
    const bool changed = call(QStringLiteral("setMicrophoneShortcut"), {shortcut}).toBool();
    if (changed) {
        handleMicrophoneShortcutChanged(call(QStringLiteral("microphoneShortcut")).toString());
    }
    return changed;
}

void MacqueenIpcClient::setShortcutCaptureActive(bool active)
{
    if (m_protocolVersion >= 5) {
        call(QStringLiteral("setShortcutCaptureActive"), {active});
    }
}

QStringList MacqueenIpcClient::pressedShortcutModifiers() const
{
    if (m_protocolVersion < 6) {
        return {};
    }
    return call(QStringLiteral("pressedShortcutModifiers")).toStringList();
}

void MacqueenIpcClient::requestScreenshot()
{
    if (!m_available || m_protocolVersion < 4) {
        return;
    }
    call(QStringLiteral("requestScreenshot"));
}

void MacqueenIpcClient::handleServiceRegistered()
{
    if (!m_available) {
        m_available = true;
        Q_EMIT availableChanged();
    }
    refresh();
}

void MacqueenIpcClient::handleServiceUnregistered()
{
    clear();
}

void MacqueenIpcClient::handleWindowAdded(const QString &id)
{
    Q_UNUSED(id)
    refreshWindows();
}

void MacqueenIpcClient::handleWindowRemoved(const QString &id)
{
    Q_UNUSED(id)
    refreshWindows();
    refreshActiveWindow();
}

void MacqueenIpcClient::handleWindowChanged(const QString &id, const QStringList &fields)
{
    Q_UNUSED(id)
    Q_UNUSED(fields)
    refreshWindows();
    refreshActiveWindow();
}

void MacqueenIpcClient::handleActiveWindowChanged(const QString &id)
{
    Q_UNUSED(id)
    refreshActiveWindow();
    refreshWindows();
}

void MacqueenIpcClient::handleOverviewRequested(const QString &reason)
{
    Q_EMIT overviewRequested(reason);
}

void MacqueenIpcClient::handleScreenCastSelectionRequested(const QString &requestId, const QString &title, const QString &optionsJson)
{
    Q_EMIT screenCastSelectionRequested(requestId, title, optionsJson);
}

void MacqueenIpcClient::handleKeyboardLayoutShortcutChanged(const QString &shortcut)
{
    if (m_keyboardLayoutShortcut == shortcut) {
        return;
    }
    m_keyboardLayoutShortcut = shortcut;
    Q_EMIT keyboardLayoutShortcutChanged();
}

void MacqueenIpcClient::handleScreenshotShortcutChanged(const QString &shortcut)
{
    if (m_screenshotShortcut == shortcut) {
        return;
    }
    m_screenshotShortcut = shortcut;
    Q_EMIT screenshotShortcutChanged();
}

void MacqueenIpcClient::handleMicrophoneShortcutChanged(const QString &shortcut)
{
    if (m_microphoneShortcut == shortcut) {
        return;
    }
    m_microphoneShortcut = shortcut;
    Q_EMIT microphoneShortcutChanged();
}

void MacqueenIpcClient::refreshOutputs()
{
    const QVariantList value = mapList(call(QStringLiteral("outputs")));
    if (m_outputs != value) {
        m_outputs = value;
        Q_EMIT outputsChanged();
    }
}

void MacqueenIpcClient::refreshWorkspaces()
{
    const QVariantList value = mapList(call(QStringLiteral("workspaces")));
    if (m_workspaces != value) {
        m_workspaces = value;
        Q_EMIT workspacesChanged();
    }
}

void MacqueenIpcClient::refreshKeyboardLayouts()
{
    const QVariantList layouts = mapList(call(QStringLiteral("keyboardLayouts")));
    const QVariantList available = mapList(call(QStringLiteral("availableKeyboardLayouts")));
    const uint current = call(QStringLiteral("currentKeyboardLayout")).toUInt();
    if (m_keyboardLayouts != layouts || m_currentKeyboardLayout != current) {
        m_keyboardLayouts = layouts;
        m_currentKeyboardLayout = current;
        Q_EMIT keyboardLayoutsChanged();
    }
    if (m_availableKeyboardLayouts != available) {
        m_availableKeyboardLayouts = available;
        Q_EMIT availableKeyboardLayoutsChanged();
    }
}

QVariant MacqueenIpcClient::call(const QString &method, const QVariantList &arguments) const
{
    QDBusInterface interface(QString::fromLatin1(Service),
                             QString::fromLatin1(Path),
                             QString::fromLatin1(Interface),
                             QDBusConnection::sessionBus());
    const QDBusMessage reply = interface.callWithArgumentList(QDBus::Block, method, arguments);
    if (reply.type() == QDBusMessage::ReplyMessage && !reply.arguments().isEmpty()) {
        return reply.arguments().constFirst();
    }
    return {};
}

void MacqueenIpcClient::refreshVersions()
{
    const uint protocol = call(QStringLiteral("protocolVersion")).toUInt();
    const QString compositor = call(QStringLiteral("compositorVersion")).toString();
    if (m_protocolVersion != protocol || m_compositorVersion != compositor) {
        m_protocolVersion = protocol;
        m_compositorVersion = compositor;
        Q_EMIT versionsChanged();
    }
}

void MacqueenIpcClient::refreshWindows()
{
    const QVariantList value = mapList(call(QStringLiteral("windows")));
    if (m_windows != value) {
        m_windows = value;
        Q_EMIT windowsChanged();
    }
}

void MacqueenIpcClient::refreshActiveWindow()
{
    const QVariantMap value = unpackDbusMap(converted<QVariantMap>(call(QStringLiteral("activeWindow"))));
    if (m_activeWindow != value) {
        m_activeWindow = value;
        Q_EMIT activeWindowChanged();
    }
}

void MacqueenIpcClient::clear()
{
    const bool wasAvailable = m_available;
    m_available = false;
    m_protocolVersion = 0;
    m_compositorVersion.clear();
    m_activeWindow.clear();
    m_windows.clear();
    m_outputs.clear();
    m_workspaces.clear();
    m_keyboardLayouts.clear();
    m_availableKeyboardLayouts.clear();
    m_currentKeyboardLayout = 0;
    m_keyboardLayoutShortcut.clear();
    m_screenshotShortcut.clear();
    m_microphoneShortcut.clear();

    if (wasAvailable) {
        Q_EMIT availableChanged();
    }
    Q_EMIT versionsChanged();
    Q_EMIT activeWindowChanged();
    Q_EMIT windowsChanged();
    Q_EMIT outputsChanged();
    Q_EMIT workspacesChanged();
    Q_EMIT keyboardLayoutsChanged();
    Q_EMIT availableKeyboardLayoutsChanged();
    Q_EMIT keyboardLayoutShortcutChanged();
    Q_EMIT screenshotShortcutChanged();
    Q_EMIT microphoneShortcutChanged();
}
