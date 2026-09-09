/*
    SPDX-License-Identifier: LGPL-2.0-or-later
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
*/

#pragma once

#include <QDBusContext>
#include <QObject>
#include <QHash>

class ScreenChooserDialog;

class MacqueenScreenChooserBridge : public QObject, protected QDBusContext
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.macqueen.ScreenCastChooser1")

public:
    static MacqueenScreenChooserBridge *self();

    bool request(ScreenChooserDialog *dialog, const QString &title, const QString &optionsJson);
    void forget(ScreenChooserDialog *dialog);

public Q_SLOTS:
    bool select(const QString &requestId, const QString &kind, const QString &id, bool allowRestore);
    bool cancel(const QString &requestId);

Q_SIGNALS:
    void selectionRequested(const QString &requestId, const QString &title, const QString &optionsJson);

private:
    explicit MacqueenScreenChooserBridge(QObject *parent = nullptr);
    bool isMolniyaCaller() const;

    QHash<QString, ScreenChooserDialog *> m_requests;
};
