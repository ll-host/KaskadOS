/*
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
    SPDX-License-Identifier: GPL-3.0-or-later
*/

#pragma once

#include <QColor>
#include <QObject>
#include <QQmlEngine>
#include <QQuickTextDocument>
#include <QVariantList>
#include <QVariantMap>

class QSyntaxHighlighter;
class QTextDocument;

class NotepadDocumentController : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(NotepadDocumentController)

    Q_PROPERTY(QQuickTextDocument *textDocument READ textDocument WRITE setTextDocument NOTIFY textDocumentChanged)
    Q_PROPERTY(bool markdownEnabled READ markdownEnabled WRITE setMarkdownEnabled NOTIFY markdownEnabledChanged)
    Q_PROPERTY(QVariantList colorRanges READ colorRanges NOTIFY annotationsChanged)
    Q_PROPERTY(QVariantList bookmarks READ bookmarks NOTIFY annotationsChanged)

public:
    explicit NotepadDocumentController(QObject *parent = nullptr);
    ~NotepadDocumentController() override;

    QQuickTextDocument *textDocument() const;
    void setTextDocument(QQuickTextDocument *document);

    bool markdownEnabled() const;
    void setMarkdownEnabled(bool enabled);

    QVariantList colorRanges() const;
    QVariantList bookmarks() const;

    Q_INVOKABLE void setAnnotations(const QVariantMap &annotations);
    Q_INVOKABLE QVariantMap annotations() const;
    Q_INVOKABLE void applyTextColor(int start, int end, const QColor &color);
    Q_INVOKABLE void clearTextColor(int start, int end);
    Q_INVOKABLE bool hasBookmarkAt(int position) const;
    Q_INVOKABLE void toggleBookmark(int position, const QColor &color);
    Q_INVOKABLE int nextBookmark(int position, bool backwards = false) const;
    Q_INVOKABLE QString relativeImagePath(const QString &documentPath, const QString &imagePath) const;

Q_SIGNALS:
    void textDocumentChanged();
    void markdownEnabledChanged();
    void annotationsChanged();

private:
    struct ColorRange {
        int start = 0;
        int length = 0;
        QColor color;
    };
    struct Bookmark {
        int position = 0;
        QColor color;
        QString label;
    };

    void handleContentsChange(int position, int removed, int added);
    void rehighlight();
    int blockPosition(int position) const;
    void normalizeRanges();
    void normalizeBookmarks();

    QQuickTextDocument *m_quickDocument = nullptr;
    QTextDocument *m_document = nullptr;
    QSyntaxHighlighter *m_highlighter = nullptr;
    bool m_markdownEnabled = false;
    QList<ColorRange> m_colorRanges;
    QList<Bookmark> m_bookmarks;
};
