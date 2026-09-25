import QtQuick
import QtQuick.Controls
import QtTest
import Macqueen.Ipc

TestCase {
    name: "NotepadDocument"
    when: windowShown

    TextArea {
        id: editor
        text: "Первая строка\nВторая строка"
    }

    NotepadDocumentController {
        id: controller
        textDocument: editor.textDocument
        markdownEnabled: true
    }

    SignalSpy {
        id: annotationsSpy
        target: controller
        signalName: "annotationsChanged"
    }

    function init() {
        editor.text = "Первая строка\nВторая строка";
        controller.setAnnotations({ version: 1, colors: [], bookmarks: [] });
        annotationsSpy.clear();
    }

    function test_plainTypingDoesNotCreateMetadata() {
        editor.insert(0, "Обычный текст ");
        compare(annotationsSpy.count, 0);
        compare(controller.colorRanges.length, 0);
        compare(controller.bookmarks.length, 0);
    }

    function test_colorMetadataTracksInsertion() {
        controller.applyTextColor(0, 6, "#ff0000");
        compare(controller.colorRanges.length, 1);
        editor.insert(0, "Новая ");
        tryCompare(controller, "colorRanges", [{ start: 6, length: 6, color: "#ffff0000" }]);
    }

    function test_bookmarkToggleAndNavigation() {
        controller.toggleBookmark(16, "#00ff00");
        compare(controller.bookmarks.length, 1);
        compare(controller.bookmarks[0].position, 14);
        compare(controller.nextBookmark(0), 14);
        verify(controller.hasBookmarkAt(20));
        controller.toggleBookmark(20, "#00ff00");
        compare(controller.bookmarks.length, 0);
    }

    function test_annotationsRoundTrip() {
        controller.setAnnotations({
            version: 1,
            colors: [{ start: 2, length: 4, color: "#ff336699" }],
            bookmarks: [{ position: 0, color: "#ffaa5500", label: "Начало" }]
        });
        const data = controller.annotations();
        compare(data.version, 1);
        compare(data.colors.length, 1);
        compare(data.bookmarks.length, 1);
        compare(data.bookmarks[0].label, "Начало");
    }

    function test_clearingLastColorLeavesEmptyMetadata() {
        controller.applyTextColor(0, 6, "#ff0000");
        compare(controller.colorRanges.length, 1);
        controller.clearTextColor(0, 6);
        compare(controller.colorRanges.length, 0);
        compare(controller.annotations().colors.length, 0);
    }

    function test_staleMetadataIsClampedAndDeduplicated() {
        controller.setAnnotations({
            version: 1,
            colors: [{ start: 999, length: 100, color: "#ff0000" }],
            bookmarks: [
                { position: 999, color: "#00ff00", label: "Старая" },
                { position: 1000, color: "#0000ff", label: "Дубликат" }
            ]
        });
        compare(controller.colorRanges.length, 0);
        compare(controller.bookmarks.length, 1);
        compare(controller.bookmarks[0].position, 14);
    }
}
