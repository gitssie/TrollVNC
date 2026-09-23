#ifndef TROLLVNC_CLIPBOARD_TEXT_H
#define TROLLVNC_CLIPBOARD_TEXT_H

/* LibVNCServer includes Extended Clipboard's trailing NUL in the callback length. */
static inline int tvClipboardUTF8TextLength(const char *text, int length) {
    if (!text || length <= 0)
        return 0;
    return length - (text[length - 1] == '\0');
}

#endif
