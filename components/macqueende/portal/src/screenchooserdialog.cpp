/*
 * SPDX-FileCopyrightText: 2018 Red Hat Inc
 *
 * SPDX-License-Identifier: LGPL-2.0-or-later
 *
 * SPDX-FileCopyrightText: 2018 Jan Grulich <jgrulich@redhat.com>
 */

#include "screenchooserdialog.h"
#include "macqueenscreenchooserbridge.h"
#include "utils.h"
#include "waylandintegration.h"

#include "region-select/SelectionEditor.h"

#include <KLocalizedString>
#include <KWayland/Client/plasmawindowmanagement.h>
#include <KWayland/Client/plasmawindowmodel.h>

#include <QCoreApplication>
#include <QJsonDocument>
#include <QScreen>
#include <QSettings>
#include <QSortFilterProxyModel>
#include <QStandardPaths>
#include <QTimer>
#include <QWindow>

using namespace Qt::StringLiterals;

class FilteredWindowModel : public QSortFilterProxyModel
{
    Q_OBJECT
    Q_PROPERTY(bool hasSelection READ hasSelection NOTIFY hasSelectionChanged)
public:
    explicit FilteredWindowModel(QObject *parent)
        : QSortFilterProxyModel(parent)
    {
    }

    bool filterAcceptsRow(int source_row, const QModelIndex &source_parent) const override
    {
        if (source_parent.isValid())
            return false;

        const auto idx = sourceModel()->index(source_row, 0);
        using KWayland::Client::PlasmaWindowModel;

        return !idx.data(PlasmaWindowModel::SkipTaskbar).toBool() //
            && !idx.data(PlasmaWindowModel::SkipSwitcher).toBool() //
            && idx.data(PlasmaWindowModel::Pid) != QCoreApplication::applicationPid();
    }

    QMap<int, QVariant> itemData(const QModelIndex &index) const override
    {
        using KWayland::Client::PlasmaWindowModel;
        auto ret = QSortFilterProxyModel::itemData(index);
        for (int i = PlasmaWindowModel::AppId; i <= PlasmaWindowModel::Uuid; ++i) {
            ret[i] = index.data(i);
        }
        return ret;
    }

    bool setData(const QModelIndex &index, const QVariant &value, int role) override
    {
        if (!checkIndex(index, CheckIndexOption::IndexIsValid) || role != Qt::CheckStateRole) {
            return false;
        }

        if (value == Qt::Checked) {
            m_selected.insert(index);
        } else {
            m_selected.remove(index);
        }
        Q_EMIT dataChanged(index, index, {role});
        if (m_selected.count() <= 1) {
            Q_EMIT hasSelectionChanged();
        }
        return true;
    }

    QList<QMap<int, QVariant>> selectedWindowsData() const
    {
        QList<QMap<int, QVariant>> ret;
        ret.reserve(m_selected.size());
        for (const auto &index : m_selected) {
            if (index.isValid())
                ret << itemData(index);
        }
        return ret;
    }

    QVariantList selectionCandidates() const
    {
        using KWayland::Client::PlasmaWindowModel;
        QVariantList candidates;
        candidates.reserve(rowCount());
        for (int row = 0; row < rowCount(); ++row) {
            const QModelIndex idx = index(row, 0);
            candidates.append(QVariantMap{
                {QStringLiteral("id"), idx.data(PlasmaWindowModel::Uuid).toString()},
                {QStringLiteral("label"), idx.data(Qt::DisplayRole).toString()},
                {QStringLiteral("appId"), idx.data(PlasmaWindowModel::AppId).toString()},
                {QStringLiteral("kind"), QStringLiteral("window")},
            });
        }
        return candidates;
    }

    bool selectByUuid(const QString &uuid)
    {
        using KWayland::Client::PlasmaWindowModel;
        for (int row = 0; row < rowCount(); ++row) {
            const QModelIndex idx = index(row, 0);
            if (idx.data(PlasmaWindowModel::Uuid).toString() == uuid) {
                clearSelection();
                return setData(idx, Qt::Checked, Qt::CheckStateRole);
            }
        }
        return false;
    }

    QHash<int, QByteArray> roleNames() const override
    {
        QHash<int, QByteArray> ret = sourceModel()->roleNames();
        ret.insert(Qt::CheckStateRole, "checked");
        return ret;
    }

    QVariant data(const QModelIndex &index, int role) const override
    {
        if (!checkIndex(index, CheckIndexOption::IndexIsValid)) {
            return {};
        }

        switch (role) {
        case Qt::CheckStateRole:
            return m_selected.contains(index) ? Qt::Checked : Qt::Unchecked;
        default:
            return QSortFilterProxyModel::data(index, role);
        }
        return {};
    }

    bool hasSelection()
    {
        return !m_selected.isEmpty();
    }

    void clearSelection()
    {
        auto selected = m_selected;
        m_selected.clear();

        for (const auto &index : selected) {
            if (index.isValid())
                Q_EMIT dataChanged(index, index, {Qt::CheckStateRole});
        }
        Q_EMIT hasSelectionChanged();
    }

    /*
        \brief used for finding indexes based on whether they intersect with a given screen geometry. IOW: if the window is visible on that screen
        Mind that the call signature must be kept in sync with OutputsModel! We invoke it on both the output and window model.
    */
    Q_INVOKABLE [[nodiscard]] bool geometryIntersects(const QModelIndex &index, const QRect &geometry) const
    {
        if (!checkIndex(index, CheckIndexOption::IndexIsValid)) {
            qWarning() << "Invalid index for geometry intersection check:" << index;
            return false;
        }
        return data(index, KWayland::Client::PlasmaWindowModel::Geometry).toRect().intersects(geometry);
    }

Q_SIGNALS:
    void hasSelectionChanged();

private:
    QSet<QPersistentModelIndex> m_selected;
};

ScreenChooserDialog::ScreenChooserDialog(const QString &appName, bool multiple, ScreenCastPortal::SourceTypes types)
    : QuickDialog()
{
    Q_ASSERT(types != 0);

    QVariantMap props = {
        {u"title"_s, i18nc("@title:window %1 is an application name (e.g. Falkon)", "Share screen with %1", Utils::applicationName(appName))},
        {u"multiple"_s, multiple},
    };

    // We only let the user create one virtual monitor
    if (types == ScreenCastPortal::Virtual) {
        multiple = false;
    }

    int numberOfMonitors = 0;
    if (types & ScreenCastPortal::Monitor || types & ScreenCastPortal::Virtual) {
        // If the app requests only monitor we still allow the user to create a virtual one
        OutputsModel::Options options = OutputsModel::VirtualIncluded;
        if (types & ScreenCastPortal::Monitor) {
            options |= OutputsModel::WorkspaceIncluded | OutputsModel::RegionIncluded;
        } else {
            options |= OutputsModel::OutputsExcluded;
        }
        m_outputsModel = new OutputsModel(options, this);
        props.insert(u"outputsModel"_s, QVariant::fromValue<QObject *>(m_outputsModel));
        numberOfMonitors += m_outputsModel->rowCount(QModelIndex());
        connect(this, &ScreenChooserDialog::clearSelection, m_outputsModel, &OutputsModel::clearSelection);
    } else {
        props.insert(u"outputsModel"_s, QVariant::fromValue(nullptr));
    }

    int numberOfWindows = 0;
    if (types & ScreenCastPortal::Window) {
        auto model = new KWayland::Client::PlasmaWindowModel(WaylandIntegration::plasmaWindowManagement());
        m_windowsModel = new FilteredWindowModel(this);
        m_windowsModel->setSourceModel(model);
        props.insert(u"windowsModel"_s, QVariant::fromValue<QObject *>(m_windowsModel));
        connect(this, &ScreenChooserDialog::clearSelection, m_windowsModel, &FilteredWindowModel::clearSelection);
        numberOfWindows += m_windowsModel->rowCount(QModelIndex());
    } else {
        props.insert(u"windowsModel"_s, QVariant::fromValue(nullptr));
    }

    const QString applicationName = Utils::applicationName(appName);

    QString mainText;


    // App only asked for monitors
    if (types == ScreenCastPortal::Monitor) {
        if (numberOfMonitors == 1) {
            if (appName.isEmpty()) {
                mainText = i18n("Share this screen with the requesting application?");
            } else {
                mainText = i18n("Share this screen with %1?", applicationName);
            }
        } else {
            if (multiple) {
                if (appName.isEmpty()) {
                    mainText = i18n("Choose screens to share with the requesting application:");
                } else {
                    mainText = i18n("Choose screens to share with %1:", applicationName);
                }
            } else {
                if (appName.isEmpty()) {
                    mainText = i18n("Choose which screen to share with the requesting application:");
                } else {
                    mainText = i18n("Choose which screen to share with %1:", applicationName);
                }
            }
        }
    }
    // App only asked for windows
    else if (types == ScreenCastPortal::Window) {
        if (numberOfWindows == 1) {
            if (appName.isEmpty()) {
                mainText = i18n("Share this window with the requesting application?");
            } else {
                mainText = i18n("Share this window with %1?", applicationName);
            }
        } else {
            if (multiple) {
                if (appName.isEmpty()) {
                    mainText = i18n("Choose windows to share with the requesting application:");
                } else {
                    mainText = i18n("Choose windows to share with %1:", applicationName);
                }
            } else {
                if (appName.isEmpty()) {
                    mainText = i18n("Choose which window to share with the requesting application:");
                } else {
                    mainText = i18n("Choose which window to share with %1:", applicationName);
                }
            }
        }
    }
    else if (types == ScreenCastPortal::Virtual) {
        if (appName.isEmpty()) {
            mainText = i18n("Create a new virtual display to share with the requesting application:");
        } else {
            mainText = i18n("Create a new virtual display to share with %1:", applicationName);
        }
    }
    // Any other combination
    else {
        if (appName.isEmpty()) {
            mainText = i18n("Choose what to share with the requesting application:");
        } else {
            mainText = i18n("Choose what to share with %1:", applicationName);
        }
    }
    props.insert(u"mainText"_s, mainText);

    if (qEnvironmentVariable("XDG_CURRENT_DESKTOP").compare(u"MacqueenDE"_s, Qt::CaseInsensitive) == 0) {
        QVariantMap externalOptions{
            {u"multiple"_s, multiple},
            {u"outputs"_s, m_outputsModel ? m_outputsModel->selectionCandidates() : QVariantList{}},
            {u"windows"_s, m_windowsModel ? m_windowsModel->selectionCandidates() : QVariantList{}},
        };
        const QString optionsJson = QString::fromUtf8(QJsonDocument::fromVariant(externalOptions).toJson(QJsonDocument::Compact));
        if (MacqueenScreenChooserBridge::self()->request(this, mainText, optionsJson)) {
            m_external = true;
            return;
        }
    }

    create(QStringLiteral("ScreenChooserDialog"), props);
    connect(m_theDialog, SIGNAL(clearSelection()), this, SIGNAL(clearSelection()));
}

ScreenChooserDialog::~ScreenChooserDialog()
{
    MacqueenScreenChooserBridge::self()->forget(this);
}

QList<Output> ScreenChooserDialog::selectedOutputs() const
{
    if (!m_outputsModel) {
        return {};
    }
    return m_outputsModel->selectedOutputs();
}

QList<KWayland::Client::PlasmaWindow *> ScreenChooserDialog::selectedWindows() const
{
    if (!m_windowsModel) {
        return {};
    }
    const auto selectedWindowsData = m_windowsModel->selectedWindowsData();
    QList<KWayland::Client::PlasmaWindow *> windows;
    windows.reserve(selectedWindowsData.size());
    auto allWindows = WaylandIntegration::plasmaWindowManagement()->windows();
    for (const auto &windowData : selectedWindowsData) {
        auto it = std::ranges::find(allWindows, windowData[KWayland::Client::PlasmaWindowModel::Uuid], &KWayland::Client::PlasmaWindow::uuid);
        if (it != std::ranges::end(allWindows)) {
            windows.append(*it);
        }
    }
    return windows;
}

QRect ScreenChooserDialog::selectedRegion() const
{
    return m_region;
}

void ScreenChooserDialog::setRegion(const QRect region)
{
    m_region = region;
}

bool ScreenChooserDialog::allowRestore() const
{
    if (m_external) {
        return m_externalAllowRestore;
    }
    return m_theDialog->property("allowRestore").toBool();
}

bool ScreenChooserDialog::selectExternal(const QString &kind, const QString &id, bool allowRestore)
{
    m_externalAllowRestore = allowRestore;
    if (kind == u"output"_s && m_outputsModel) {
        return m_outputsModel->selectByUniqueId(id);
    }
    if (kind == u"window"_s && m_windowsModel) {
        return m_windowsModel->selectByUuid(id);
    }
    return false;
}

void ScreenChooserDialog::accept()
{
    if (std::ranges::contains(selectedOutputs(), Output::OutputType::Region, &Output::outputType)) {
        auto selectionEditor = new SelectionEditor(this);
        connect(selectionEditor, &SelectionEditor::finished, this, [this, selectionEditor](DialogResult result) {
            selectionEditor->deleteLater();
            if (result == DialogResult::Accepted) {
                setRegion(selectionEditor->rect());
                QuickDialog::accept();
            } else if (m_external) {
                QuickDialog::reject();
            } else {
                // if we selected rectangular region, but didn't actually choose a region, start over
                QTimer::singleShot(0, m_theDialog, SLOT(present()));
            }
        });
        return;
    }
    QuickDialog::accept();
}

#include "moc_screenchooserdialog.cpp"
#include "screenchooserdialog.moc"
