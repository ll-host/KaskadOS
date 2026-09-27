/*
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "macqueenipc.h"

#include "config-kwin.h"
#include "core/backendoutput.h"
#include "core/output.h"
#include "core/outputbackend.h"
#include "core/outputconfiguration.h"
#include "cursor.h"
#include "input.h"
#include "keyboard_input.h"
#include "keyboard_layout.h"
#include "main.h"
#include "input_event.h"
#include "screenedge.h"
#include "scripting/scriptingutils.h"
#include "virtualdesktops.h"
#include "window.h"
#include "workspace.h"
#include "xkb.h"
#include "wayland_server.h"

#include <QDBusConnection>
#include <QFile>
#include <QAction>
#include <QHash>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QKeySequence>
#include <KGlobalAccel>
#include <KConfigGroup>
#include <QRegularExpression>
#include <QTextStream>
#include <algorithm>
#include <cmath>
#include <linux/input-event-codes.h>

namespace KWin
{

namespace
{

QString windowId(const Window *window)
{
    return window ? window->internalId().toString(QUuid::WithoutBraces) : QString();
}

Qt::Key physicalLatinKey(quint32 code)
{
    static const QHash<quint32, Qt::Key> keys{
        {KEY_A, Qt::Key_A}, {KEY_B, Qt::Key_B}, {KEY_C, Qt::Key_C},
        {KEY_D, Qt::Key_D}, {KEY_E, Qt::Key_E}, {KEY_F, Qt::Key_F},
        {KEY_G, Qt::Key_G}, {KEY_H, Qt::Key_H}, {KEY_I, Qt::Key_I},
        {KEY_J, Qt::Key_J}, {KEY_K, Qt::Key_K}, {KEY_L, Qt::Key_L},
        {KEY_M, Qt::Key_M}, {KEY_N, Qt::Key_N}, {KEY_O, Qt::Key_O},
        {KEY_P, Qt::Key_P}, {KEY_Q, Qt::Key_Q}, {KEY_R, Qt::Key_R},
        {KEY_S, Qt::Key_S}, {KEY_T, Qt::Key_T}, {KEY_U, Qt::Key_U},
        {KEY_V, Qt::Key_V}, {KEY_W, Qt::Key_W}, {KEY_X, Qt::Key_X},
        {KEY_Y, Qt::Key_Y}, {KEY_Z, Qt::Key_Z},
    };
    return keys.value(code, Qt::Key_unknown);
}

enum class MicrophoneShortcutKind {
    Invalid,
    Keyboard,
    Modifiers,
    Mouse,
};

struct ParsedMicrophoneShortcut
{
    MicrophoneShortcutKind kind = MicrophoneShortcutKind::Invalid;
    Qt::KeyboardModifiers modifiers;
    Qt::Key key = Qt::Key_unknown;
    quint32 mouseButton = 0;
    QString normalized;
};

QString modifierName(const QString &token)
{
    if (token.compare(QStringLiteral("Super"), Qt::CaseInsensitive) == 0
        || token.compare(QStringLiteral("Meta"), Qt::CaseInsensitive) == 0) {
        return QStringLiteral("Super");
    }
    if (token.compare(QStringLiteral("Alt"), Qt::CaseInsensitive) == 0) {
        return QStringLiteral("Alt");
    }
    if (token.compare(QStringLiteral("Ctrl"), Qt::CaseInsensitive) == 0
        || token.compare(QStringLiteral("Control"), Qt::CaseInsensitive) == 0) {
        return QStringLiteral("Ctrl");
    }
    if (token.compare(QStringLiteral("Shift"), Qt::CaseInsensitive) == 0) {
        return QStringLiteral("Shift");
    }
    return {};
}

Qt::KeyboardModifier modifierValue(const QString &name)
{
    if (name == QStringLiteral("Super")) {
        return Qt::MetaModifier;
    }
    if (name == QStringLiteral("Alt")) {
        return Qt::AltModifier;
    }
    if (name == QStringLiteral("Ctrl")) {
        return Qt::ControlModifier;
    }
    return Qt::ShiftModifier;
}

QStringList modifierNames(Qt::KeyboardModifiers modifiers)
{
    QStringList names;
    if (modifiers.testFlag(Qt::MetaModifier)) {
        names.append(QStringLiteral("Super"));
    }
    if (modifiers.testFlag(Qt::AltModifier)) {
        names.append(QStringLiteral("Alt"));
    }
    if (modifiers.testFlag(Qt::ControlModifier)) {
        names.append(QStringLiteral("Ctrl"));
    }
    if (modifiers.testFlag(Qt::ShiftModifier)) {
        names.append(QStringLiteral("Shift"));
    }
    return names;
}

Qt::KeyboardModifiers rawModifiers(const QSet<quint32> &pressedKeys)
{
    Qt::KeyboardModifiers modifiers;
    if (pressedKeys.contains(KEY_LEFTMETA) || pressedKeys.contains(KEY_RIGHTMETA)) {
        modifiers |= Qt::MetaModifier;
    }
    if (pressedKeys.contains(KEY_LEFTALT) || pressedKeys.contains(KEY_RIGHTALT)) {
        modifiers |= Qt::AltModifier;
    }
    if (pressedKeys.contains(KEY_LEFTCTRL) || pressedKeys.contains(KEY_RIGHTCTRL)) {
        modifiers |= Qt::ControlModifier;
    }
    if (pressedKeys.contains(KEY_LEFTSHIFT) || pressedKeys.contains(KEY_RIGHTSHIFT)) {
        modifiers |= Qt::ShiftModifier;
    }
    return modifiers;
}

QString mouseButtonName(quint32 nativeButton)
{
    if (nativeButton < BTN_MIDDLE || nativeButton > BTN_TASK) {
        return {};
    }
    return QStringLiteral("Mouse %1").arg(nativeButton - BTN_LEFT + 1);
}

ParsedMicrophoneShortcut parseMicrophoneShortcut(const QString &shortcut)
{
    ParsedMicrophoneShortcut parsed;
    QString portable = shortcut.trimmed();
    portable.replace(QStringLiteral("Meta"), QStringLiteral("Super"), Qt::CaseInsensitive);
    if (portable.isEmpty()) {
        return parsed;
    }

    QStringList parts = portable.split(QLatin1Char('+'), Qt::SkipEmptyParts);
    for (QString &part : parts) {
        part = part.trimmed();
    }

    Qt::KeyboardModifiers explicitModifiers;
    int modifierCount = 0;
    for (const QString &part : parts) {
        const QString name = modifierName(part);
        if (name.isEmpty()) {
            break;
        }
        const Qt::KeyboardModifier value = modifierValue(name);
        if (explicitModifiers.testFlag(value)) {
            return parsed;
        }
        explicitModifiers |= value;
        ++modifierCount;
    }

    if (modifierCount == parts.size()) {
        parsed.kind = MicrophoneShortcutKind::Modifiers;
        parsed.modifiers = explicitModifiers;
        parsed.normalized = modifierNames(explicitModifiers).join(QLatin1Char('+'));
        return parsed;
    }

    if (modifierCount == parts.size() - 1) {
        static const QRegularExpression mousePattern(QStringLiteral("^Mouse\\s+([3-8])$"), QRegularExpression::CaseInsensitiveOption);
        const QRegularExpressionMatch match = mousePattern.match(parts.constLast());
        if (match.hasMatch()) {
            const int number = match.captured(1).toInt();
            parsed.kind = MicrophoneShortcutKind::Mouse;
            parsed.modifiers = explicitModifiers;
            parsed.mouseButton = BTN_LEFT + number - 1;
            QStringList normalized = modifierNames(explicitModifiers);
            normalized.append(QStringLiteral("Mouse %1").arg(number));
            parsed.normalized = normalized.join(QLatin1Char('+'));
            return parsed;
        }
    }

    portable.replace(QStringLiteral("Super"), QStringLiteral("Meta"), Qt::CaseInsensitive);
    const QKeySequence sequence = QKeySequence::fromString(portable, QKeySequence::PortableText);
    if (sequence.isEmpty() || sequence.count() != 1
        || sequence[0].key() == Qt::Key_unknown
        || (sequence[0].key() >= Qt::Key_Shift && sequence[0].key() <= Qt::Key_Meta)) {
        return parsed;
    }
    parsed.kind = MicrophoneShortcutKind::Keyboard;
    parsed.modifiers = sequence[0].keyboardModifiers();
    parsed.key = sequence[0].key();
    parsed.normalized = sequence.toString(QKeySequence::PortableText);
    parsed.normalized.replace(QStringLiteral("Meta"), QStringLiteral("Super"));
    return parsed;
}

QVariantMap geometryData(const RectF &geometry)
{
    return {
        {QStringLiteral("x"), geometry.x()},
        {QStringLiteral("y"), geometry.y()},
        {QStringLiteral("width"), geometry.width()},
        {QStringLiteral("height"), geometry.height()},
    };
}

}

MacqueenIpc::MacqueenIpc(Workspace *workspace)
    : QObject(workspace)
    , m_workspace(workspace)
{
    KConfigGroup microphoneConfig(kwinApp()->config(), QStringLiteral("MacqueenMicrophone"));
    m_microphoneShortcut = microphoneConfig.readEntry("Shortcut", QStringLiteral("V"));
    m_screenshotAction = new QAction(this);
    m_screenshotAction->setObjectName(QStringLiteral("MacqueenInteractiveScreenshot"));
    m_screenshotAction->setText(QStringLiteral("Flameshot Screenshot"));
    KGlobalAccel::self()->setGlobalShortcut(
        m_screenshotAction,
        {
            QKeySequence(Qt::META | Qt::SHIFT | Qt::Key_S),
            QKeySequence(Qt::META | Qt::SHIFT | 0x042B), // Ы on the physical S key
        });
    auto screenshotShortcuts = KGlobalAccel::self()->shortcut(m_screenshotAction);
    const QKeySequence latinDefault(Qt::META | Qt::SHIFT | Qt::Key_S);
    const QKeySequence russianDefault(Qt::META | Qt::SHIFT | 0x042B);
    if (screenshotShortcuts.contains(latinDefault) && !screenshotShortcuts.contains(russianDefault)) {
        screenshotShortcuts.append(russianDefault);
        KGlobalAccel::self()->setShortcut(m_screenshotAction, screenshotShortcuts, KGlobalAccel::NoAutoloading);
    }
    connect(m_screenshotAction, &QAction::triggered, this, &MacqueenIpc::requestScreenshot);

    m_toggleHoveredBorderAction = new QAction(this);
    m_toggleHoveredBorderAction->setObjectName(QStringLiteral("MacqueenToggleHoveredWindowBorder"));
    m_toggleHoveredBorderAction->setText(QStringLiteral("Toggle Border of Window Under Pointer"));
    KGlobalAccel::self()->setGlobalShortcut(
        m_toggleHoveredBorderAction,
        {QKeySequence(Qt::META | Qt::SHIFT | Qt::Key_B)});
    connect(m_toggleHoveredBorderAction, &QAction::triggered, this, &MacqueenIpc::toggleHoveredWindowBorder);
    // This signal is emitted by an input spy before the normal filter chain.
    // Tracking physical scan codes here makes the default shortcut independent
    // of the active keyboard layout and of filters which consume modifier keys.
    connect(input(), &InputRedirection::keyStateChanged, this, &MacqueenIpc::handleRawKeyState);
    input()->installInputEventSpy(this);

    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.registerObject(QStringLiteral("/org/macqueen/Compositor1"),
                       this,
                       QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals);
    bus.registerService(m_serviceName);

    for (Window *window : m_workspace->windows()) {
        watchWindow(window);
    }

    connect(m_workspace, &Workspace::windowAdded, this, [this](Window *window) {
        watchWindow(window);
        if (window->isClient()) {
            Q_EMIT windowAdded(windowId(window));
        }
    });
    connect(m_workspace, &Workspace::windowRemoved, this, [this](Window *window) {
        if (window->isClient()) {
            Q_EMIT windowRemoved(windowId(window));
        }
    });
    connect(m_workspace, &Workspace::windowActivated, this, [this](Window *window) {
        Q_EMIT activeWindowChanged(windowId(window));
    });
    connect(m_workspace, &Workspace::outputsChanged, this, &MacqueenIpc::outputsChanged);
    m_workspace->screenEdges()->reserve(ElectricTopLeft, this, "overviewBorderActivated");
    if (input() && input()->keyboard() && input()->keyboard()->keyboardLayout()) {
        connect(input()->keyboard()->keyboardLayout(),
                &KeyboardLayout::layoutsReconfigured,
                this,
                &MacqueenIpc::keyboardLayoutsChanged);
        connect(input()->keyboard()->keyboardLayout(),
                &KeyboardLayout::layoutChanged,
                this,
                &MacqueenIpc::keyboardLayoutsChanged);
    }
    connect(m_workspace, &Workspace::currentDesktopChanged, this, [this]() {
        Q_EMIT workspacesChanged();
    });

    VirtualDesktopManager *desktops = VirtualDesktopManager::self();
    connect(desktops, &VirtualDesktopManager::countChanged, this, [this]() {
        Q_EMIT workspacesChanged();
    });
    connect(desktops, &VirtualDesktopManager::desktopMoved, this, [this]() {
        Q_EMIT workspacesChanged();
    });
    for (VirtualDesktop *desktop : desktops->desktops()) {
        connect(desktop, &VirtualDesktop::nameChanged, this, &MacqueenIpc::workspacesChanged);
    }
    connect(desktops, &VirtualDesktopManager::desktopAdded, this, [this](VirtualDesktop *desktop) {
        connect(desktop, &VirtualDesktop::nameChanged, this, &MacqueenIpc::workspacesChanged);
    });
}

MacqueenIpc::~MacqueenIpc()
{
    // MacqueenIpc is owned by Workspace and QObject destroys its children only
    // after Workspace's C++ members, including ScreenEdges, have already been
    // torn down. Calling screenEdges() here therefore dereferences a destroyed
    // manager during compositor shutdown. The reservation does not need an
    // explicit unreserve because both objects share the same lifetime.
    QDBusConnection::sessionBus().unregisterService(m_serviceName);
}

uint MacqueenIpc::protocolVersion() const
{
    return 13;
}

QString MacqueenIpc::compositorVersion() const
{
    return QString::fromLatin1(MACQUEEN_VERSION_STRING);
}

QVariantMap MacqueenIpc::activeWindow() const
{
    return windowData(m_workspace->activeWindow());
}

QVariantList MacqueenIpc::windows() const
{
    QVariantList result;
    for (const Window *window : m_workspace->windows()) {
        if (window->isClient()) {
            result.append(windowData(window));
        }
    }
    return result;
}

QVariantList MacqueenIpc::outputs() const
{
    QVariantList result;
    for (const BackendOutput *output : kwinApp()->outputBackend()->outputs()) {
        QVariantList modes;
        int currentModeId = -1;
        const auto outputModes = output->modes();
        const auto currentMode = output->currentMode();
        for (int index = 0; index < outputModes.size(); ++index) {
            const auto &mode = outputModes.at(index);
            if (mode == currentMode) {
                currentModeId = index;
            }
            modes.append(QVariantMap{
                {QStringLiteral("id"), index},
                {QStringLiteral("width"), mode->size().width()},
                {QStringLiteral("height"), mode->size().height()},
                {QStringLiteral("refresh"), mode->refreshRate()},
                {QStringLiteral("preferred"), mode->flags().testFlag(OutputModeline::Flag::Preferred)},
            });
        }

        QVariantMap currentModeData;
        if (currentMode) {
            currentModeData = {
                {QStringLiteral("id"), currentModeId},
                {QStringLiteral("width"), currentMode->size().width()},
                {QStringLiteral("height"), currentMode->size().height()},
                {QStringLiteral("refresh"), currentMode->refreshRate()},
            };
        }

        result.append(QVariantMap{
            {QStringLiteral("id"), output->uuid()},
            {QStringLiteral("name"), output->name()},
            {QStringLiteral("enabled"), output->isEnabled()},
            {QStringLiteral("manufacturer"), output->manufacturer()},
            {QStringLiteral("make"), output->manufacturer()},
            {QStringLiteral("model"), output->model()},
            {QStringLiteral("serialNumber"), output->serialNumber()},
            {QStringLiteral("x"), output->position().x()},
            {QStringLiteral("y"), output->position().y()},
            {QStringLiteral("width"), output->modeSize().width()},
            {QStringLiteral("height"), output->modeSize().height()},
            {QStringLiteral("scale"), output->scaleSetting()},
            {QStringLiteral("refreshRate"), output->refreshRate()},
            {QStringLiteral("transform"), static_cast<int>(output->manualTransform().kind())},
            {QStringLiteral("adaptiveSyncSupported"), output->capabilities().testFlag(BackendOutput::Capability::Vrr)},
            {QStringLiteral("adaptiveSync"), output->vrrPolicy() == VrrPolicy::Never ? 0 : 1},
            {QStringLiteral("modes"), modes},
            {QStringLiteral("currentMode"), currentModeData},
        });
    }
    return result;
}

bool MacqueenIpc::applyOutputConfiguration(const QVariantList &outputs)
{
    const QList<BackendOutput *> availableOutputs = kwinApp()->outputBackend()->outputs();
    if (outputs.isEmpty() || availableOutputs.isEmpty()) {
        return false;
    }

    QHash<QString, BackendOutput *> outputsByName;
    for (BackendOutput *output : availableOutputs) {
        outputsByName.insert(output->name(), output);
    }

    QHash<BackendOutput *, bool> requestedEnabled;
    OutputConfiguration configuration;
    configuration.source = OutputConfiguration::Source::User;

    for (const QVariant &value : outputs) {
        const QVariantMap data = dbusToVariant(value).toMap();
        const QString name = data.value(QStringLiteral("name")).toString();
        BackendOutput *output = outputsByName.value(name, nullptr);
        if (!output) {
            return false;
        }

        const auto changes = configuration.changeSet(output);
        if (data.contains(QStringLiteral("enabled"))) {
            const bool enabled = data.value(QStringLiteral("enabled")).toBool();
            changes->enabled = enabled;
            requestedEnabled.insert(output, enabled);
        }

        if (data.contains(QStringLiteral("modeId"))) {
            bool ok = false;
            const int modeId = data.value(QStringLiteral("modeId")).toInt(&ok);
            const auto modes = output->modes();
            if (!ok || modeId < 0 || modeId >= modes.size()) {
                return false;
            }
            changes->currentMode = modes.at(modeId)->modeline();
            changes->desiredMode = modes.at(modeId)->modeline();
        }

        if (data.contains(QStringLiteral("position"))) {
            const QVariantMap position = dbusToVariant(data.value(QStringLiteral("position"))).toMap();
            const int x = position.value(QStringLiteral("x")).toInt();
            const int y = position.value(QStringLiteral("y")).toInt();
            if (x < 0 || y < 0 || x > 1000000 || y > 1000000) {
                return false;
            }
            changes->pos = QPoint(x, y);
        }

        if (data.contains(QStringLiteral("scale"))) {
            const double scale = data.value(QStringLiteral("scale")).toDouble();
            if (scale < 0.25 || scale > 4.0) {
                return false;
            }
            const double roundedScale = std::round(scale * 120.0) / 120.0;
            changes->scale = roundedScale;
            changes->scaleSetting = roundedScale;
        }

        if (data.contains(QStringLiteral("transform"))) {
            bool ok = false;
            const int transform = data.value(QStringLiteral("transform")).toInt(&ok);
            if (!ok || transform < OutputTransform::Normal || transform > OutputTransform::FlipX270) {
                return false;
            }
            const OutputTransform outputTransform(static_cast<OutputTransform::Kind>(transform));
            changes->transform = outputTransform;
            changes->manualTransform = outputTransform;
        }

        if (data.contains(QStringLiteral("adaptiveSync")) && output->capabilities().testFlag(BackendOutput::Capability::Vrr)) {
            changes->vrrPolicy = data.value(QStringLiteral("adaptiveSync")).toInt() == 0
                ? VrrPolicy::Never
                : VrrPolicy::Always;
        }
    }

    const bool anyOutputEnabled = std::any_of(availableOutputs.cbegin(), availableOutputs.cend(), [&requestedEnabled](BackendOutput *output) {
        return requestedEnabled.value(output, output->isEnabled());
    });
    if (!anyOutputEnabled) {
        return false;
    }

    return m_workspace->applyOutputConfiguration(configuration) == OutputConfigurationError::None;
}

bool MacqueenIpc::applyOutputConfigurationJson(const QString &outputsJson)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(outputsJson.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isArray()) {
        return false;
    }
    return applyOutputConfiguration(document.toVariant().toList());
}

QString MacqueenIpc::outputAtCursor() const
{
    Cursor *cursor = Cursors::self()->mouse();
    const LogicalOutput *output = cursor ? m_workspace->outputAt(cursor->pos()) : m_workspace->activeOutput();
    return output ? output->name() : QString();
}

QVariantList MacqueenIpc::workspaces() const
{
    QVariantList result;
    VirtualDesktopManager *manager = VirtualDesktopManager::self();
    const VirtualDesktop *current = manager->currentDesktop();
    for (const VirtualDesktop *desktop : manager->desktops()) {
        result.append(QVariantMap{
            {QStringLiteral("id"), desktop->id()},
            {QStringLiteral("name"), desktop->name()},
            {QStringLiteral("position"), desktop->x11DesktopNumber()},
            {QStringLiteral("current"), desktop == current},
        });
    }
    return result;
}

QVariantList MacqueenIpc::keyboardLayouts() const
{
    QVariantList result;
    if (!input() || !input()->keyboard()) {
        return result;
    }

    Xkb *xkb = input()->keyboard()->xkb();
    const uint current = xkb->currentLayout();
    for (uint index = 0; index < xkb->numberOfLayouts(); ++index) {
        QString code = xkb->layoutShortName(index);
        // xkbcommon uses "us" when no layout is explicitly configured, while
        // the corresponding rule name remains empty.
        if (code.isEmpty()) {
            code = QStringLiteral("us");
        }
        result.append(QVariantMap{
            {QStringLiteral("code"), code},
            {QStringLiteral("name"), xkb->layoutName(index)},
            {QStringLiteral("index"), index},
            {QStringLiteral("active"), index == current},
        });
    }
    return result;
}

QVariantList MacqueenIpc::availableKeyboardLayouts() const
{
    QFile file(QStringLiteral("/usr/share/X11/xkb/rules/evdev.lst"));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        file.setFileName(QStringLiteral("/usr/share/X11/xkb/rules/base.lst"));
        if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            return {};
        }
    }

    QVariantList result;
    QTextStream stream(&file);
    bool inLayouts = false;
    const QRegularExpression entry(QStringLiteral("^\\s*(\\S+)\\s+(.+?)\\s*$"));
    while (!stream.atEnd()) {
        const QString line = stream.readLine();
        if (line.startsWith(QLatin1Char('!'))) {
            inLayouts = line.trimmed() == QStringLiteral("! layout");
            continue;
        }
        if (!inLayouts || line.trimmed().isEmpty()) {
            continue;
        }
        const QRegularExpressionMatch match = entry.match(line);
        if (match.hasMatch()) {
            result.append(QVariantMap{
                {QStringLiteral("code"), match.captured(1)},
                {QStringLiteral("name"), match.captured(2)},
            });
        }
    }
    return result;
}

uint MacqueenIpc::currentKeyboardLayout() const
{
    return input() && input()->keyboard() ? input()->keyboard()->xkb()->currentLayout() : 0;
}

bool MacqueenIpc::setKeyboardLayouts(const QStringList &layouts)
{
    static const QRegularExpression validLayout(QStringLiteral("^[A-Za-z0-9_()+-]+$"));
    if (layouts.isEmpty()) {
        return false;
    }
    for (const QString &layout : layouts) {
        if (!validLayout.match(layout).hasMatch()) {
            return false;
        }
    }

    KConfigGroup group(kwinApp()->kxkbConfig(), QStringLiteral("Layout"));
    group.writeEntry(QStringLiteral("Use"), true, KConfig::Notify);
    group.writeEntry(QStringLiteral("LayoutList"), layouts.join(QLatin1Char(',')), KConfig::Notify);
    group.writeEntry(QStringLiteral("VariantList"), QStringList(layouts.size(), QString()).join(QLatin1Char(',')), KConfig::Notify);
    group.sync();

    // Apply the new keymap immediately. KConfig notifications are not guaranteed
    // to be delivered back to the process that wrote the configuration.
    input()->keyboard()->xkb()->reconfigure();
    input()->keyboard()->keyboardLayout()->resetLayout();
    return true;
}

bool MacqueenIpc::setCurrentKeyboardLayout(uint index)
{
    if (!input() || !input()->keyboard() || index >= input()->keyboard()->xkb()->numberOfLayouts()) {
        return false;
    }
    input()->keyboard()->keyboardLayout()->switchToLayout(index);
    return true;
}

QString MacqueenIpc::keyboardLayoutShortcut() const
{
    if (!input() || !input()->keyboard() || !input()->keyboard()->keyboardLayout()) {
        return {};
    }
    return input()->keyboard()->keyboardLayout()->switchShortcut();
}

bool MacqueenIpc::setKeyboardLayoutShortcut(const QString &shortcut)
{
    if (!input() || !input()->keyboard() || !input()->keyboard()->keyboardLayout()) {
        return false;
    }
    const bool changed = input()->keyboard()->keyboardLayout()->setSwitchShortcut(shortcut);
    if (changed) {
        Q_EMIT keyboardLayoutShortcutChanged(keyboardLayoutShortcut());
    }
    return changed;
}

bool MacqueenIpc::resetKeyboardLayoutShortcut()
{
    if (!input() || !input()->keyboard() || !input()->keyboard()->keyboardLayout()) {
        return false;
    }
    input()->keyboard()->keyboardLayout()->resetSwitchShortcut();
    Q_EMIT keyboardLayoutShortcutChanged(keyboardLayoutShortcut());
    return true;
}

bool MacqueenIpc::activateWorkspace(const QString &id)
{
    VirtualDesktopManager *manager = VirtualDesktopManager::self();
    VirtualDesktop *desktop = manager->desktopForId(id);
    return desktop && (desktop == manager->currentDesktop() || manager->setCurrent(desktop));
}

QString MacqueenIpc::createWorkspace(uint position, const QString &name)
{
    VirtualDesktopManager *manager = VirtualDesktopManager::self();
    const uint insertionIndex = position == 0 ? manager->count() : position - 1;
    VirtualDesktop *desktop = manager->createVirtualDesktop(insertionIndex, name);
    return desktop ? desktop->id() : QString();
}

bool MacqueenIpc::removeWorkspace(const QString &id)
{
    VirtualDesktopManager *manager = VirtualDesktopManager::self();
    VirtualDesktop *desktop = manager->desktopForId(id);
    if (!desktop || manager->count() <= 1) {
        return false;
    }
    manager->removeVirtualDesktop(desktop);
    return true;
}

bool MacqueenIpc::renameWorkspace(const QString &id, const QString &name)
{
    VirtualDesktop *desktop = VirtualDesktopManager::self()->desktopForId(id);
    if (!desktop || name.trimmed().isEmpty()) {
        return false;
    }
    desktop->setName(name.trimmed());
    return true;
}

bool MacqueenIpc::activateWindow(const QString &id)
{
    Window *window = m_workspace->findWindow(QUuid::fromString(id));
    if (!window || !window->isClient()) {
        return false;
    }
    m_workspace->activateWindow(window, true);
    return true;
}

bool MacqueenIpc::closeWindow(const QString &id)
{
    Window *window = m_workspace->findWindow(QUuid::fromString(id));
    if (!window || !window->isClient() || !window->isCloseable()) {
        return false;
    }
    window->closeWindow();
    return true;
}

bool MacqueenIpc::setWindowMinimized(const QString &id, bool minimized)
{
    Window *window = m_workspace->findWindow(QUuid::fromString(id));
    if (!window || !window->isClient() || (minimized && !window->isMinimizable())) {
        return false;
    }
    window->setMinimized(minimized);
    return true;
}

bool MacqueenIpc::setWindowFullscreen(const QString &id, bool fullscreen)
{
    Window *window = m_workspace->findWindow(QUuid::fromString(id));
    if (!window || !window->isClient() || (fullscreen && !window->isFullScreenable())) {
        return false;
    }
    window->setFullScreen(fullscreen);
    return true;
}

bool MacqueenIpc::moveWindowToWorkspace(const QString &windowId, const QString &workspaceId)
{
    Window *window = m_workspace->findWindow(QUuid::fromString(windowId));
    VirtualDesktop *desktop = VirtualDesktopManager::self()->desktopForId(workspaceId);
    if (!window || !window->isClient() || !desktop) {
        return false;
    }
    window->setDesktops({desktop});
    return true;
}

void MacqueenIpc::requestOverview(const QString &reason)
{
    Q_EMIT overviewRequested(reason);
}

QString MacqueenIpc::screenshotShortcut() const
{
    const auto shortcuts = KGlobalAccel::self()->shortcut(m_screenshotAction);
    if (shortcuts.isEmpty()) {
        return {};
    }
    QString text = shortcuts.constFirst().toString(QKeySequence::PortableText);
    return text.replace(QStringLiteral("Meta"), QStringLiteral("Super"));
}

bool MacqueenIpc::setScreenshotShortcut(const QString &shortcut)
{
    QString portable = shortcut.trimmed();
    portable.replace(QStringLiteral("Super"), QStringLiteral("Meta"), Qt::CaseInsensitive);
    const QKeySequence sequence = QKeySequence::fromString(portable, QKeySequence::PortableText);
    if (!portable.isEmpty() && sequence.isEmpty()) {
        return false;
    }
    QList<QKeySequence> sequences;
    if (!sequence.isEmpty()) {
        sequences.append(sequence);
        if (sequence == QKeySequence(Qt::META | Qt::SHIFT | Qt::Key_S)) {
            sequences.append(QKeySequence(Qt::META | Qt::SHIFT | 0x042B));
        }
    }
    KGlobalAccel::self()->setShortcut(m_screenshotAction, sequences, KGlobalAccel::NoAutoloading);
    Q_EMIT screenshotShortcutChanged(screenshotShortcut());
    return true;
}

QString MacqueenIpc::microphoneShortcut() const
{
    return m_microphoneShortcut;
}

bool MacqueenIpc::setMicrophoneShortcut(const QString &shortcut)
{
    const ParsedMicrophoneShortcut parsed = parseMicrophoneShortcut(shortcut);
    if (parsed.kind == MicrophoneShortcutKind::Invalid) {
        return false;
    }
    if (m_microphoneShortcut == parsed.normalized) {
        return true;
    }
    if (m_microphonePressedKey != 0 || m_microphonePressedMouseButton != 0 || m_microphoneModifierShortcutPressed) {
        m_microphonePressedKey = 0;
        m_microphonePressedMouseButton = 0;
        m_microphoneModifierShortcutPressed = false;
        Q_EMIT microphoneShortcutKeyChanged(false);
    }
    m_microphoneShortcut = parsed.normalized;
    KConfigGroup group(kwinApp()->config(), QStringLiteral("MacqueenMicrophone"));
    group.writeEntry("Shortcut", parsed.normalized);
    group.sync();
    Q_EMIT microphoneShortcutChanged(parsed.normalized);
    return true;
}

void MacqueenIpc::setShortcutCaptureActive(bool active)
{
    if (m_shortcutCaptureActive == active) {
        return;
    }
    m_shortcutCaptureActive = active;
    // Block every KGlobalAccel action while the editor is listening. Otherwise
    // an existing compositor shortcut (for example a layout switch involving
    // Alt+Shift) consumes part of the new combination before Quickshell sees it.
    m_workspace->disableGlobalShortcutsForClient(active);
    m_screenshotAction->setEnabled(!active);
    if (active && (m_microphonePressedKey != 0 || m_microphonePressedMouseButton != 0 || m_microphoneModifierShortcutPressed)) {
        m_microphonePressedKey = 0;
        m_microphonePressedMouseButton = 0;
        m_microphoneModifierShortcutPressed = false;
        Q_EMIT microphoneShortcutKeyChanged(false);
    }
    if (active) {
        m_pressedRawKeys.clear();
        m_captureModifierKeys.clear();
        m_captureSawNonModifier = false;
    } else {
        m_captureModifierKeys.clear();
        m_captureSawNonModifier = false;
    }
}

QStringList MacqueenIpc::pressedShortcutModifiers() const
{
    QStringList modifiers;
    if (m_pressedRawKeys.contains(KEY_LEFTMETA) || m_pressedRawKeys.contains(KEY_RIGHTMETA)) {
        modifiers.append(QStringLiteral("Super"));
    }
    if (m_pressedRawKeys.contains(KEY_LEFTALT) || m_pressedRawKeys.contains(KEY_RIGHTALT)) {
        modifiers.append(QStringLiteral("Alt"));
    }
    if (m_pressedRawKeys.contains(KEY_LEFTCTRL) || m_pressedRawKeys.contains(KEY_RIGHTCTRL)) {
        modifiers.append(QStringLiteral("Ctrl"));
    }
    if (m_pressedRawKeys.contains(KEY_LEFTSHIFT) || m_pressedRawKeys.contains(KEY_RIGHTSHIFT)) {
        modifiers.append(QStringLiteral("Shift"));
    }
    return modifiers;
}

QVariantMap MacqueenIpc::screenshotShortcutDebug() const
{
    QVariantList pressedKeys;
    for (quint32 key : m_pressedRawKeys) {
        pressedKeys.append(key);
    }
    std::sort(pressedKeys.begin(), pressedKeys.end(), [](const QVariant &left, const QVariant &right) {
        return left.toUInt() < right.toUInt();
    });

    return {
        {QStringLiteral("configuredShortcut"), screenshotShortcut()},
        {QStringLiteral("lastKeyCode"), m_lastRawKeyCode},
        {QStringLiteral("lastKeyState"), m_lastRawKeyState == KeyboardKeyState::Pressed ? QStringLiteral("pressed") : QStringLiteral("released")},
        {QStringLiteral("pressedKeyCodes"), pressedKeys},
        {QStringLiteral("recentEvents"), m_recentRawKeyEvents},
        {QStringLiteral("triggerCount"), m_screenshotShortcutTriggerCount},
        {QStringLiteral("captureActive"), m_shortcutCaptureActive},
        {QStringLiteral("shortcutsInhibited"), waylandServer()->isKeyboardShortcutsInhibited()},
    };
}

void MacqueenIpc::requestScreenshot()
{
    Q_EMIT screenshotRequested();
}

bool MacqueenIpc::toggleHoveredWindowBorder()
{
    const QPointF cursorPosition = Cursors::self()->mouse()->pos();
    auto it = m_workspace->stackingOrder().constEnd();
    while (it != m_workspace->stackingOrder().constBegin()) {
        Window *window = *(--it);
        if (!window->isClient()
            || !window->isShown()
            || window->isDesktop()
            || !window->frameGeometry().contains(cursorPosition)) {
            continue;
        }
        if (!window->userCanSetNoBorder()) {
            return false;
        }
        window->setNoBorder(!window->noBorder());
        return true;
    }
    return false;
}

void MacqueenIpc::pointerButton(PointerButtonEvent *event)
{
    const QString buttonName = mouseButtonName(event->nativeButton);
    if (m_shortcutCaptureActive && event->state == PointerButtonState::Pressed && !buttonName.isEmpty()) {
        m_captureSawNonModifier = true;
        QStringList shortcut = modifierNames(rawModifiers(m_pressedRawKeys));
        shortcut.append(buttonName);
        Q_EMIT shortcutCaptured(shortcut.join(QLatin1Char('+')));
        return;
    }

    const ParsedMicrophoneShortcut microphoneShortcut = parseMicrophoneShortcut(m_microphoneShortcut);
    if (microphoneShortcut.kind != MicrophoneShortcutKind::Mouse) {
        return;
    }

    if (m_microphonePressedMouseButton != 0
        && event->state == PointerButtonState::Released
        && event->nativeButton == m_microphonePressedMouseButton) {
        m_microphonePressedMouseButton = 0;
        Q_EMIT microphoneShortcutKeyChanged(false);
        return;
    }

    if (!m_shortcutCaptureActive
        && m_microphonePressedMouseButton == 0
        && event->state == PointerButtonState::Pressed
        && event->nativeButton == microphoneShortcut.mouseButton
        && rawModifiers(m_pressedRawKeys) == microphoneShortcut.modifiers
        && !waylandServer()->isKeyboardShortcutsInhibited()) {
        m_microphonePressedMouseButton = event->nativeButton;
        Q_EMIT microphoneShortcutKeyChanged(true);
    }
}

void MacqueenIpc::handleRawKeyState(quint32 keyCode, KeyboardKeyState state)
{
    const bool modifierKey = keyCode == KEY_LEFTSHIFT || keyCode == KEY_RIGHTSHIFT
        || keyCode == KEY_LEFTMETA || keyCode == KEY_RIGHTMETA
        || keyCode == KEY_LEFTCTRL || keyCode == KEY_RIGHTCTRL
        || keyCode == KEY_LEFTALT || keyCode == KEY_RIGHTALT;

    m_lastRawKeyCode = keyCode;
    m_lastRawKeyState = state;
    if (state == KeyboardKeyState::Pressed) {
        m_pressedRawKeys.insert(keyCode);
        if (m_shortcutCaptureActive && modifierKey) {
            m_captureModifierKeys.insert(keyCode);
        }
    } else if (state == KeyboardKeyState::Released) {
        m_pressedRawKeys.remove(keyCode);
    }

    const QString event = QStringLiteral("%1:%2")
                              .arg(keyCode)
                              .arg(state == KeyboardKeyState::Pressed ? QStringLiteral("down") : QStringLiteral("up"));
    m_recentRawKeyEvents.append(event);
    while (m_recentRawKeyEvents.size() > 16) {
        m_recentRawKeyEvents.removeFirst();
    }

    const ParsedMicrophoneShortcut microphoneShortcut = parseMicrophoneShortcut(m_microphoneShortcut);
    const Qt::KeyboardModifiers activeModifiers = rawModifiers(m_pressedRawKeys);

    if (microphoneShortcut.kind == MicrophoneShortcutKind::Mouse
        && m_microphonePressedMouseButton != 0
        && activeModifiers != microphoneShortcut.modifiers) {
        m_microphonePressedMouseButton = 0;
        Q_EMIT microphoneShortcutKeyChanged(false);
    }

    if (microphoneShortcut.kind == MicrophoneShortcutKind::Modifiers) {
        if (m_microphoneModifierShortcutPressed && activeModifiers != microphoneShortcut.modifiers) {
            m_microphoneModifierShortcutPressed = false;
            Q_EMIT microphoneShortcutKeyChanged(false);
        } else if (!m_shortcutCaptureActive
                   && !m_microphoneModifierShortcutPressed
                   && state == KeyboardKeyState::Pressed
                   && activeModifiers == microphoneShortcut.modifiers
                   && !waylandServer()->isKeyboardShortcutsInhibited()) {
            m_microphoneModifierShortcutPressed = true;
            Q_EMIT microphoneShortcutKeyChanged(true);
        }
    }

    if (microphoneShortcut.kind == MicrophoneShortcutKind::Keyboard
        && m_microphonePressedKey != 0
        && state == KeyboardKeyState::Released
        && (keyCode == m_microphonePressedKey || modifierKey)) {
        if (keyCode == m_microphonePressedKey || activeModifiers != microphoneShortcut.modifiers) {
            m_microphonePressedKey = 0;
            Q_EMIT microphoneShortcutKeyChanged(false);
        }
    }
    if (microphoneShortcut.kind == MicrophoneShortcutKind::Keyboard
        && !m_shortcutCaptureActive && m_microphonePressedKey == 0
        && state == KeyboardKeyState::Pressed && !modifierKey
        && !waylandServer()->isKeyboardShortcutsInhibited()) {
        const Qt::Key actualKey = input()->keyboard()->xkb()->toQtKey(
            input()->keyboard()->xkb()->toKeysym(keyCode), keyCode);
        const Qt::Key latinKey = physicalLatinKey(keyCode);
        if ((actualKey == microphoneShortcut.key || latinKey == microphoneShortcut.key)
            && activeModifiers == microphoneShortcut.modifiers) {
            m_microphonePressedKey = keyCode;
            Q_EMIT microphoneShortcutKeyChanged(true);
        }
    }

    if (m_shortcutCaptureActive && state == KeyboardKeyState::Pressed) {
        if (!modifierKey) {
            m_captureSawNonModifier = true;
            Xkb *xkb = input()->keyboard()->xkb();
            const Qt::Key key = xkb->toQtKey(xkb->toKeysym(keyCode), keyCode);
            if (key != Qt::Key_unknown) {
                Qt::KeyboardModifiers modifiers;
                const QStringList physicalModifiers = pressedShortcutModifiers();
                if (physicalModifiers.contains(QStringLiteral("Super"))) {
                    modifiers |= Qt::MetaModifier;
                }
                if (physicalModifiers.contains(QStringLiteral("Alt"))) {
                    modifiers |= Qt::AltModifier;
                }
                if (physicalModifiers.contains(QStringLiteral("Ctrl"))) {
                    modifiers |= Qt::ControlModifier;
                }
                if (physicalModifiers.contains(QStringLiteral("Shift"))) {
                    modifiers |= Qt::ShiftModifier;
                }
                QString shortcut = QKeySequence(QKeyCombination(modifiers, key)).toString(QKeySequence::PortableText);
                shortcut.replace(QStringLiteral("Meta"), QStringLiteral("Super"));
                if (!shortcut.isEmpty()) {
                    Q_EMIT shortcutCaptured(shortcut);
                }
            }
        }
    } else if (m_shortcutCaptureActive
               && state == KeyboardKeyState::Released
               && modifierKey
               && !m_captureSawNonModifier
               && m_pressedRawKeys.isEmpty()) {
        QStringList modifiers;
        if (m_captureModifierKeys.contains(KEY_LEFTMETA) || m_captureModifierKeys.contains(KEY_RIGHTMETA)) {
            modifiers.append(QStringLiteral("Super"));
        }
        if (m_captureModifierKeys.contains(KEY_LEFTALT) || m_captureModifierKeys.contains(KEY_RIGHTALT)) {
            modifiers.append(QStringLiteral("Alt"));
        }
        if (m_captureModifierKeys.contains(KEY_LEFTCTRL) || m_captureModifierKeys.contains(KEY_RIGHTCTRL)) {
            modifiers.append(QStringLiteral("Ctrl"));
        }
        if (m_captureModifierKeys.contains(KEY_LEFTSHIFT) || m_captureModifierKeys.contains(KEY_RIGHTSHIFT)) {
            modifiers.append(QStringLiteral("Shift"));
        }
        if (!modifiers.isEmpty()) {
            Q_EMIT shortcutCaptured(modifiers.join(QLatin1Char('+')));
        }
        m_captureModifierKeys.clear();
    }

    if (m_shortcutCaptureActive
        || state != KeyboardKeyState::Pressed
        || keyCode != KEY_S
        || waylandServer()->isKeyboardShortcutsInhibited()) {
        return;
    }

    QString portable = screenshotShortcut();
    portable.replace(QStringLiteral("Super"), QStringLiteral("Meta"), Qt::CaseInsensitive);
    const QKeySequence sequence = QKeySequence::fromString(portable, QKeySequence::PortableText);
    if (sequence.isEmpty() || sequence[0] != QKeyCombination(Qt::META | Qt::SHIFT, Qt::Key_S)) {
        return;
    }

    const bool shiftPressed = m_pressedRawKeys.contains(KEY_LEFTSHIFT) || m_pressedRawKeys.contains(KEY_RIGHTSHIFT);
    const bool metaPressed = m_pressedRawKeys.contains(KEY_LEFTMETA) || m_pressedRawKeys.contains(KEY_RIGHTMETA);
    const bool controlPressed = m_pressedRawKeys.contains(KEY_LEFTCTRL) || m_pressedRawKeys.contains(KEY_RIGHTCTRL);
    const bool altPressed = m_pressedRawKeys.contains(KEY_LEFTALT) || m_pressedRawKeys.contains(KEY_RIGHTALT);
    if (shiftPressed && metaPressed && !controlPressed && !altPressed) {
        ++m_screenshotShortcutTriggerCount;
        requestScreenshot();
    }
}

bool MacqueenIpc::overviewBorderActivated(ElectricBorder border)
{
    if (border != ElectricTopLeft) {
        return false;
    }
    requestOverview(QStringLiteral("screen-edge"));
    return true;
}

void MacqueenIpc::watchWindow(Window *window)
{
    if (!window->isClient()) {
        return;
    }

    const auto changed = [this, window](const QStringList &fields) {
        Q_EMIT windowChanged(windowId(window), fields);
    };
    connect(window, &Window::captionChanged, this, [changed]() {
        changed({QStringLiteral("title")});
    });
    connect(window, &Window::frameGeometryChanged, this, [changed]() {
        changed({QStringLiteral("geometry")});
    });
    connect(window, &Window::minimizedChanged, this, [changed]() {
        changed({QStringLiteral("minimized")});
    });
    connect(window, &Window::fullScreenChanged, this, [changed]() {
        changed({QStringLiteral("fullscreen")});
    });
    connect(window, &Window::maximizedChanged, this, [changed]() {
        changed({QStringLiteral("maximized")});
    });
    connect(window, &Window::desktopsChanged, this, [changed]() {
        changed({QStringLiteral("workspaces")});
    });
    connect(window, &Window::outputChanged, this, [changed]() {
        changed({QStringLiteral("output")});
    });
    connect(window, &Window::windowClassChanged, this, [changed]() {
        changed({QStringLiteral("appId")});
    });
}

QVariantMap MacqueenIpc::windowData(const Window *window) const
{
    if (!window || !window->isClient()) {
        return {};
    }

    return {
        {QStringLiteral("id"), windowId(window)},
        {QStringLiteral("appId"), window->desktopFileName().isEmpty() ? window->resourceClass() : window->desktopFileName()},
        {QStringLiteral("title"), window->captionNormal()},
        {QStringLiteral("geometry"), geometryData(window->frameGeometry())},
        {QStringLiteral("workspaces"), window->desktopIds()},
        {QStringLiteral("active"), window->isActive()},
        {QStringLiteral("minimized"), window->isMinimized()},
        {QStringLiteral("fullscreen"), window->isFullScreen()},
        {QStringLiteral("maximized"), window->maximizeMode() == MaximizeFull},
        {QStringLiteral("keepAbove"), window->keepAbove()},
        {QStringLiteral("skipTaskbar"), window->skipTaskbar()},
        {QStringLiteral("closeable"), window->isCloseable()},
        {QStringLiteral("minimizable"), window->isMinimizable()},
        {QStringLiteral("fullscreenable"), window->isFullScreenable()},
        {QStringLiteral("output"), window->output() ? window->output()->name() : QString()},
        {QStringLiteral("pid"), window->pid()},
    };
}

} // namespace KWin
