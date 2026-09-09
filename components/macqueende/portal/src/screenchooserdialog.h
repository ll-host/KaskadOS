/*
 * SPDX-FileCopyrightText: 2018 Red Hat Inc
 *
 * SPDX-License-Identifier: LGPL-2.0-or-later
 *
 * SPDX-FileCopyrightText: 2018 Jan Grulich <jgrulich@redhat.com>
 */

#ifndef XDG_DESKTOP_PORTAL_KDE_SCREENCHOOSER_DIALOG_H
#define XDG_DESKTOP_PORTAL_KDE_SCREENCHOOSER_DIALOG_H

#include "outputsmodel.h"
#include "quickdialog.h"
#include "screencast.h"
#include <QEventLoop>
#include <QRect>

namespace KWayland
{
namespace Client
{
class PlasmaWindow;
}
}

class FilteredWindowModel;

class ScreenChooserDialog : public QuickDialog
{
    Q_OBJECT
public:
    ScreenChooserDialog(const QString &appName, bool multiple, ScreenCastPortal::SourceTypes types);
    ~ScreenChooserDialog() override;

    QList<Output> selectedOutputs() const;
    QList<KWayland::Client::PlasmaWindow *> selectedWindows() const;
    bool allowRestore() const;
    QRect selectedRegion() const;
    bool selectExternal(const QString &kind, const QString &id, bool allowRestore);

public Q_SLOTS:
    void accept() override;

Q_SIGNALS:
    void clearSelection();

private:
    void setRegion(const QRect region);

    QRect m_region;
    OutputsModel *m_outputsModel = nullptr;
    FilteredWindowModel *m_windowsModel = nullptr;
    bool m_external = false;
    bool m_externalAllowRestore = true;
};

#endif // XDG_DESKTOP_PORTAL_KDE_SCREENCHOOSER_DIALOG_H
