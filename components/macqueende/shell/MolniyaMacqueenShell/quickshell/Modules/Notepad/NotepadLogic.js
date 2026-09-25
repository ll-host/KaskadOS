.pragma library

function lineBounds(text, cursor) {
    const safe = Math.max(0, Math.min(cursor, text.length));
    const start = text.lastIndexOf("\n", safe - 1) + 1;
    const next = text.indexOf("\n", safe);
    return {
        start: start,
        end: next < 0 ? text.length : next,
        beforeCursor: text.substring(start, safe),
        full: text.substring(start, next < 0 ? text.length : next)
    };
}

function incrementOutline(value) {
    const pieces = value.split(".");
    const last = parseInt(pieces[pieces.length - 1], 10);
    pieces[pieces.length - 1] = String(isNaN(last) ? 1 : last + 1);
    return pieces.join(".");
}

function continueList(text, cursor) {
    const bounds = lineBounds(text, cursor);
    if (bounds.beforeCursor !== bounds.full)
        return { handled: false };

    let match = bounds.full.match(/^(\s*)([-+*])\s+\[([ xX])\]\s*(.*)$/);
    if (match) {
        if (match[4].trim().length === 0)
            return { handled: true, start: bounds.start, end: bounds.end, replacement: "", cursor: bounds.start };
        const prefix = match[1] + match[2] + " [ ] ";
        return { handled: true, start: cursor, end: cursor, replacement: "\n" + prefix, cursor: cursor + prefix.length + 1 };
    }

    match = bounds.full.match(/^(\s*)(\d+(?:\.\d+)+)([.)]?)(\s+)(.*)$/);
    if (match) {
        if (match[5].trim().length === 0)
            return { handled: true, start: bounds.start, end: bounds.end, replacement: "", cursor: bounds.start };
        const prefix = match[1] + incrementOutline(match[2]) + match[3] + match[4];
        return { handled: true, start: cursor, end: cursor, replacement: "\n" + prefix, cursor: cursor + prefix.length + 1 };
    }

    match = bounds.full.match(/^(\s*)(\d+)([.)])(\s+)(.*)$/);
    if (match) {
        if (match[5].trim().length === 0)
            return { handled: true, start: bounds.start, end: bounds.end, replacement: "", cursor: bounds.start };
        const prefix = match[1] + String(parseInt(match[2], 10) + 1) + match[3] + match[4];
        return { handled: true, start: cursor, end: cursor, replacement: "\n" + prefix, cursor: cursor + prefix.length + 1 };
    }

    match = bounds.full.match(/^(\s*)([-+*])\s+(.*)$/);
    if (match) {
        if (match[3].trim().length === 0)
            return { handled: true, start: bounds.start, end: bounds.end, replacement: "", cursor: bounds.start };
        const prefix = match[1] + match[2] + " ";
        return { handled: true, start: cursor, end: cursor, replacement: "\n" + prefix, cursor: cursor + prefix.length + 1 };
    }

    return { handled: false };
}

function changeListLevel(text, cursor, outdent) {
    const bounds = lineBounds(text, cursor);
    const line = bounds.full;
    const outline = line.match(/^(\s*)(\d+(?:\.\d+)+)([.)]?)(\s+.*)$/);
    if (outline) {
        const parts = outline[2].split(".");
        if (outdent && parts.length > 1)
            parts.pop();
        else if (!outdent)
            parts.push("1");
        else
            return { handled: false };
        const replacement = outline[1] + parts.join(".") + outline[3] + outline[4];
        return { handled: true, start: bounds.start, end: bounds.end, replacement: replacement,
                 cursor: cursor + replacement.length - line.length };
    }

    if (/^\s*(?:[-+*]|\d+[.)])\s+/.test(line)) {
        if (outdent) {
            const removed = Math.min(4, (line.match(/^\s*/) || [""])[0].length);
            if (removed === 0)
                return { handled: false };
            return { handled: true, start: bounds.start, end: bounds.start + removed, replacement: "",
                     cursor: Math.max(bounds.start, cursor - removed) };
        }
        return { handled: true, start: bounds.start, end: bounds.start, replacement: "    ", cursor: cursor + 4 };
    }
    return { handled: false };
}

function markdownImage(alt, path) {
    const safeAlt = (alt || "Изображение").replace(/[\[\]]/g, "");
    const safePath = String(path || "").replace(/\\/g, "/").replace(/\)/g, "\\)");
    return "![" + safeAlt + "](" + safePath + ")";
}
