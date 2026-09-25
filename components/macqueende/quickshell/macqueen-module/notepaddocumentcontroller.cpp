/*
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
    SPDX-License-Identifier: GPL-3.0-or-later
*/

#include "notepaddocumentcontroller.h"

#include <QColor>
#include <QDir>
#include <QFileInfo>
#include <QQuickTextDocument>
#include <QRegularExpression>
#include <QSyntaxHighlighter>
#include <QTextBlock>
#include <QTextCharFormat>
#include <QTextDocument>

#include <algorithm>
#include <limits>

class NotepadHighlighter final : public QSyntaxHighlighter
{
public:
    explicit NotepadHighlighter(NotepadDocumentController *controller, QTextDocument *document)
        : QSyntaxHighlighter(document)
        , m_controller(controller)
    {
    }

protected:
    void highlightBlock(const QString &text) override
    {
        if (m_controller->markdownEnabled()) {
            apply(QStringLiteral(R"(^\s{0,3}#{1,6}\s+.*$)"), QColor(QStringLiteral("#9fe0b4")), QFont::DemiBold);
            apply(QStringLiteral(R"(`[^`]+`)"), QColor(QStringLiteral("#efc66f")));
            apply(QStringLiteral(R"(\*\*[^*]+\*\*|__[^_]+__)"), QColor(QStringLiteral("#d7eee0")), QFont::Bold);
            apply(QStringLiteral(R"((?<!\*)\*[^*]+\*(?!\*)|(?<!_)_[^_]+_(?!_))"), QColor(QStringLiteral("#c7dfd0")), QFont::Normal, true);
            apply(QStringLiteral(R"(!?\[[^\]]*\]\([^)]+\))"), QColor(QStringLiteral("#8ab4f8")));
            apply(QStringLiteral(R"(^\s*(?:[-+*]|\d+(?:\.\d+)*[.)]?)\s+)"), QColor(QStringLiteral("#86b89a")), QFont::DemiBold);
            apply(QStringLiteral(R"(^\s*>\s?.*$)"), QColor(QStringLiteral("#aebbb3")), QFont::Normal, true);
            apply(QStringLiteral(R"(\[[ xX]\])"), QColor(QStringLiteral("#9fe0b4")), QFont::DemiBold);
        }

        const int blockStart = currentBlock().position();
        const int blockEnd = blockStart + text.size();
        for (const QVariant &value : m_controller->bookmarks()) {
            const QVariantMap bookmark = value.toMap();
            const int position = bookmark.value(QStringLiteral("position")).toInt();
            if (position < blockStart || position > blockEnd)
                continue;
            QColor color(bookmark.value(QStringLiteral("color")).toString());
            color.setAlpha(38);
            QTextCharFormat format;
            format.setBackground(color);
            setFormat(0, text.size(), format);
        }

        for (const QVariant &value : m_controller->colorRanges()) {
            const QVariantMap range = value.toMap();
            const int start = range.value(QStringLiteral("start")).toInt();
            const int end = start + range.value(QStringLiteral("length")).toInt();
            const int overlapStart = std::max(start, blockStart);
            const int overlapEnd = std::min(end, blockEnd);
            if (overlapStart >= overlapEnd)
                continue;
            QTextCharFormat format;
            format.setForeground(QColor(range.value(QStringLiteral("color")).toString()));
            setFormat(overlapStart - blockStart, overlapEnd - overlapStart, format);
        }
    }

private:
    void apply(const QString &pattern, const QColor &color, int weight = QFont::Normal, bool italic = false)
    {
        const QRegularExpression expression(pattern);
        auto match = expression.globalMatch(currentBlock().text());
        while (match.hasNext()) {
            const QRegularExpressionMatch current = match.next();
            QTextCharFormat format;
            format.setForeground(color);
            format.setFontWeight(weight);
            format.setFontItalic(italic);
            setFormat(current.capturedStart(), current.capturedLength(), format);
        }
    }

    NotepadDocumentController *m_controller;
};

NotepadDocumentController::NotepadDocumentController(QObject *parent)
    : QObject(parent)
{
}

NotepadDocumentController::~NotepadDocumentController() = default;

QQuickTextDocument *NotepadDocumentController::textDocument() const
{
    return m_quickDocument;
}

void NotepadDocumentController::setTextDocument(QQuickTextDocument *document)
{
    if (m_quickDocument == document)
        return;
    if (m_document)
        disconnect(m_document, nullptr, this, nullptr);
    delete m_highlighter;
    m_highlighter = nullptr;
    m_quickDocument = document;
    m_document = document ? document->textDocument() : nullptr;
    if (m_document) {
        m_highlighter = new NotepadHighlighter(this, m_document);
        connect(m_document, &QTextDocument::contentsChange,
                this, &NotepadDocumentController::handleContentsChange);
        connect(m_document, &QObject::destroyed, this, [this] {
            m_document = nullptr;
            m_quickDocument = nullptr;
            m_highlighter = nullptr;
        });
    }
    Q_EMIT textDocumentChanged();
}

bool NotepadDocumentController::markdownEnabled() const
{
    return m_markdownEnabled;
}

void NotepadDocumentController::setMarkdownEnabled(bool enabled)
{
    if (m_markdownEnabled == enabled)
        return;
    m_markdownEnabled = enabled;
    rehighlight();
    Q_EMIT markdownEnabledChanged();
}

QVariantList NotepadDocumentController::colorRanges() const
{
    QVariantList result;
    for (const ColorRange &range : m_colorRanges) {
        result.append(QVariantMap{{QStringLiteral("start"), range.start},
                                  {QStringLiteral("length"), range.length},
                                  {QStringLiteral("color"), range.color.name(QColor::HexArgb)}});
    }
    return result;
}

QVariantList NotepadDocumentController::bookmarks() const
{
    QVariantList result;
    for (const Bookmark &bookmark : m_bookmarks) {
        result.append(QVariantMap{{QStringLiteral("position"), bookmark.position},
                                  {QStringLiteral("color"), bookmark.color.name(QColor::HexArgb)},
                                  {QStringLiteral("label"), bookmark.label}});
    }
    return result;
}

void NotepadDocumentController::setAnnotations(const QVariantMap &annotations)
{
    m_colorRanges.clear();
    for (const QVariant &value : annotations.value(QStringLiteral("colors")).toList()) {
        const QVariantMap map = value.toMap();
        const QColor color(map.value(QStringLiteral("color")).toString());
        const int length = map.value(QStringLiteral("length")).toInt();
        if (color.isValid() && length > 0)
            m_colorRanges.append({std::max(0, map.value(QStringLiteral("start")).toInt()), length, color});
    }
    m_bookmarks.clear();
    for (const QVariant &value : annotations.value(QStringLiteral("bookmarks")).toList()) {
        const QVariantMap map = value.toMap();
        const QColor color(map.value(QStringLiteral("color")).toString());
        if (color.isValid())
            m_bookmarks.append({std::max(0, map.value(QStringLiteral("position")).toInt()), color,
                                map.value(QStringLiteral("label")).toString()});
    }
    normalizeRanges();
    normalizeBookmarks();
    rehighlight();
    Q_EMIT annotationsChanged();
}

QVariantMap NotepadDocumentController::annotations() const
{
    return {{QStringLiteral("version"), 1},
            {QStringLiteral("colors"), colorRanges()},
            {QStringLiteral("bookmarks"), bookmarks()}};
}

void NotepadDocumentController::applyTextColor(int start, int end, const QColor &color)
{
    if (!color.isValid() || start < 0 || end <= start)
        return;
    clearTextColor(start, end);
    m_colorRanges.append({start, end - start, color});
    normalizeRanges();
    rehighlight();
    Q_EMIT annotationsChanged();
}

void NotepadDocumentController::clearTextColor(int start, int end)
{
    if (start < 0 || end <= start)
        return;
    QList<ColorRange> next;
    for (const ColorRange &range : std::as_const(m_colorRanges)) {
        const int rangeEnd = range.start + range.length;
        if (rangeEnd <= start || range.start >= end) {
            next.append(range);
            continue;
        }
        if (range.start < start)
            next.append({range.start, start - range.start, range.color});
        if (rangeEnd > end)
            next.append({end, rangeEnd - end, range.color});
    }
    m_colorRanges = next;
    rehighlight();
    Q_EMIT annotationsChanged();
}

int NotepadDocumentController::blockPosition(int position) const
{
    if (!m_document)
        return std::max(0, position);
    return m_document->findBlock(std::clamp(position, 0, std::max(0, m_document->characterCount() - 1))).position();
}

bool NotepadDocumentController::hasBookmarkAt(int position) const
{
    const int start = blockPosition(position);
    return std::any_of(m_bookmarks.cbegin(), m_bookmarks.cend(), [start](const Bookmark &bookmark) {
        return bookmark.position == start;
    });
}

void NotepadDocumentController::toggleBookmark(int position, const QColor &color)
{
    if (!m_document || !color.isValid())
        return;
    const QTextBlock block = m_document->findBlock(position);
    const int start = block.position();
    const auto iterator = std::find_if(m_bookmarks.begin(), m_bookmarks.end(), [start](const Bookmark &bookmark) {
        return bookmark.position == start;
    });
    if (iterator != m_bookmarks.end()) {
        m_bookmarks.erase(iterator);
    } else {
        QString label = block.text().trimmed();
        if (label.isEmpty())
            label = tr("Пустая строка");
        if (label.size() > 80)
            label = label.left(77) + QStringLiteral("…");
        m_bookmarks.append({start, color, label});
    }
    normalizeBookmarks();
    rehighlight();
    Q_EMIT annotationsChanged();
}

int NotepadDocumentController::nextBookmark(int position, bool backwards) const
{
    if (m_bookmarks.isEmpty())
        return -1;
    if (backwards) {
        for (auto it = m_bookmarks.crbegin(); it != m_bookmarks.crend(); ++it) {
            if (it->position < position)
                return it->position;
        }
        return m_bookmarks.constLast().position;
    }
    for (const Bookmark &bookmark : m_bookmarks) {
        if (bookmark.position > position)
            return bookmark.position;
    }
    return m_bookmarks.constFirst().position;
}

QString NotepadDocumentController::relativeImagePath(const QString &documentPath, const QString &imagePath) const
{
    if (documentPath.isEmpty() || imagePath.isEmpty())
        return imagePath;
    return QDir(QFileInfo(documentPath).absolutePath()).relativeFilePath(imagePath);
}

void NotepadDocumentController::handleContentsChange(int position, int removed, int added)
{
    if (m_colorRanges.isEmpty() && m_bookmarks.isEmpty())
        return;

    auto mapPosition = [position, removed, added](int value, bool endBoundary) {
        if (removed == 0) {
            if (value > position || (value == position && !endBoundary))
                return value + added;
            return value;
        }
        const int removedEnd = position + removed;
        if (value <= position)
            return value;
        if (value >= removedEnd)
            return value - removed + added;
        return position + (endBoundary ? added : 0);
    };

    for (ColorRange &range : m_colorRanges) {
        const int oldEnd = range.start + range.length;
        const int newStart = mapPosition(range.start, false);
        const int newEnd = mapPosition(oldEnd, true);
        range.start = std::max(0, newStart);
        range.length = std::max(0, newEnd - newStart);
    }
    for (Bookmark &bookmark : m_bookmarks)
        bookmark.position = blockPosition(mapPosition(bookmark.position, false));
    normalizeRanges();
    normalizeBookmarks();
    Q_EMIT annotationsChanged();
}

void NotepadDocumentController::normalizeRanges()
{
    const int documentEnd = m_document ? std::max(0, m_document->characterCount() - 1) : std::numeric_limits<int>::max();
    for (ColorRange &range : m_colorRanges) {
        const qint64 oldEnd = qint64(range.start) + qint64(range.length);
        range.start = std::clamp(range.start, 0, documentEnd);
        range.length = std::max(0, int(std::clamp(oldEnd, qint64(0), qint64(documentEnd))) - range.start);
    }
    m_colorRanges.removeIf([](const ColorRange &range) { return range.length <= 0; });
    std::sort(m_colorRanges.begin(), m_colorRanges.end(), [](const ColorRange &left, const ColorRange &right) {
        return left.start < right.start;
    });
}

void NotepadDocumentController::normalizeBookmarks()
{
    for (Bookmark &bookmark : m_bookmarks)
        bookmark.position = blockPosition(bookmark.position);
    std::sort(m_bookmarks.begin(), m_bookmarks.end(), [](const Bookmark &left, const Bookmark &right) {
        return left.position < right.position;
    });
    auto duplicate = std::unique(m_bookmarks.begin(), m_bookmarks.end(), [](const Bookmark &left, const Bookmark &right) {
        return left.position == right.position;
    });
    m_bookmarks.erase(duplicate, m_bookmarks.end());
}

void NotepadDocumentController::rehighlight()
{
    if (m_highlighter)
        m_highlighter->rehighlight();
}
