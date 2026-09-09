/*
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
    SPDX-License-Identifier: GPL-2.0-or-later
*/

#pragma once

#include <QObject>
#include <QAction>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>

#include "effect/globals.h"
#include "input_event.h"

namespace KWin
{

class Window;
class Workspace;

class MacqueenIpc : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.macqueen.Compositor1")

public:
    explicit MacqueenIpc(Workspace *workspace);
    ~MacqueenIpc() override;

public Q_SLOTS:
    uint protocolVersion() const;
    QString compositorVersion() const;
    QVariantMap activeWindow() const;
    QVariantList windows() const;
    QVariantList outputs() const;
    bool applyOutputConfiguration(const QVariantList &outputs);
    QString outputAtCursor() const;
    QVariantList workspaces() const;
    QVariantList keyboardLayouts() const;
    QVariantList availableKeyboardLayouts() const;
    uint currentKeyboardLayout() const;
    bool setKeyboardLayouts(const QStringList &layouts);
    bool setCurrentKeyboardLayout(uint index);
    QString keyboardLayoutShortcut() const;
    bool setKeyboardLayoutShortcut(const QString &shortcut);
    bool resetKeyboardLayoutShortcut();
    bool activateWorkspace(const QString &id);
    QString createWorkspace(uint position, const QString &name);
    bool removeWorkspace(const QString &id);
    bool renameWorkspace(const QString &id, const QString &name);
    bool activateWindow(const QString &id);
    bool closeWindow(const QString &id);
    bool setWindowMinimized(const QString &id, bool minimized);
    bool setWindowFullscreen(const QString &id, bool fullscreen);
    bool moveWindowToWorkspace(const QString &windowId, const QString &workspaceId);
    void requestOverview(const QString &reason = QStringLiteral("ipc"));
    QString screenshotShortcut() const;
    bool setScreenshotShortcut(const QString &shortcut);
    void setShortcutCaptureActive(bool active);
    QStringList pressedShortcutModifiers() const;
    QVariantMap screenshotShortcutDebug() const;
    void requestScreenshot();
    bool toggleHoveredWindowBorder();

private Q_SLOTS:
    bool overviewBorderActivated(ElectricBorder border);
    void handleRawKeyState(quint32 keyCode, KeyboardKeyState state);

Q_SIGNALS:
    void windowAdded(const QString &id);
    void windowRemoved(const QString &id);
    void windowChanged(const QString &id, const QStringList &fields);
    void activeWindowChanged(const QString &id);
    void outputsChanged();
    void workspacesChanged();
    void keyboardLayoutsChanged();
    void keyboardLayoutShortcutChanged(const QString &shortcut);
    void overviewRequested(const QString &reason);
    void screenshotRequested();
    void screenshotShortcutChanged(const QString &shortcut);
    void shortcutCaptured(const QString &shortcut);

private:
    void watchWindow(Window *window);
    QVariantMap windowData(const Window *window) const;

    Workspace *m_workspace;
    QAction *m_screenshotAction = nullptr;
    QAction *m_toggleHoveredBorderAction = nullptr;
    bool m_shortcutCaptureActive = false;
    QSet<quint32> m_pressedRawKeys;
    QSet<quint32> m_captureModifierKeys;
    bool m_captureSawNonModifier = false;
    QStringList m_recentRawKeyEvents;
    quint32 m_lastRawKeyCode = 0;
    KeyboardKeyState m_lastRawKeyState = KeyboardKeyState::Released;
    quint64 m_screenshotShortcutTriggerCount = 0;
    const QString m_serviceName = QStringLiteral("org.macqueen.Compositor1");
};

} // namespace KWin
