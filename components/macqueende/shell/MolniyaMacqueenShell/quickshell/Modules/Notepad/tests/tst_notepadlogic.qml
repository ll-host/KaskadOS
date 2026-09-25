import QtQuick
import QtTest
import "../NotepadLogic.js" as NotepadLogic

TestCase {
    name: "NotepadLogic"

    function apply(text, cursor, edit) {
        return text.substring(0, edit.start) + edit.replacement + text.substring(edit.end);
    }

    function test_numberedList() {
        const text = "1. Первый";
        const edit = NotepadLogic.continueList(text, text.length);
        verify(edit.handled);
        compare(apply(text, text.length, edit), "1. Первый\n2. ");
    }

    function test_deepOutline() {
        const text = "1.1.1.9 Раздел";
        const edit = NotepadLogic.continueList(text, text.length);
        verify(edit.handled);
        compare(apply(text, text.length, edit), "1.1.1.9 Раздел\n1.1.1.10 ");
    }

    function test_checkboxResetsState() {
        const text = "- [x] Готово";
        const edit = NotepadLogic.continueList(text, text.length);
        compare(apply(text, text.length, edit), "- [x] Готово\n- [ ] ");
    }

    function test_emptyItemEndsList() {
        const text = "1. Первый\n2. ";
        const edit = NotepadLogic.continueList(text, text.length);
        compare(apply(text, text.length, edit), "1. Первый\n");
        compare(edit.cursor, "1. Первый\n".length);
    }

    function test_outlineLevels() {
        const text = "1.4 Раздел";
        const deeper = NotepadLogic.changeListLevel(text, 4, false);
        compare(apply(text, 4, deeper), "1.4.1 Раздел");
        const shallowerText = "1.4.1 Раздел";
        const shallower = NotepadLogic.changeListLevel(shallowerText, 6, true);
        compare(apply(shallowerText, 6, shallower), "1.4 Раздел");
    }

    function test_markdownImage() {
        compare(NotepadLogic.markdownImage("Снимок", "note.assets/image.png"),
                "![Снимок](note.assets/image.png)");
    }
}
