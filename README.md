# Greg's Utils

One menu-bar app for macOS that combines three earlier tools:

- **Capture** (formerly CaptureMe): screenshot an area, then annotate it.
- **Clipboard History** (formerly Clipboard Manager): searchable history of everything you copy.
- **Editor** (formerly PlainPad): a plain-text editor with tabs, autosave, and JSON tools.

It lives in the menu bar (wrench icon) and launches at login (turn that off in Settings). A Dock icon and app menus appear only while an editor window is open.

## Build & install

```bash
./build.sh --install
```

This builds `build/GregsUtils.app`, copies it to `/Applications`, and launches it. Run `./build.sh` without the flag to just build.

macOS asks for two permissions, both for **Greg's Utils**:

- **Screen & System Audio Recording**: needed to capture.
- **Accessibility**: needed only to send ⌘V into the app you were in. Without it, choosing a history item still puts it on the clipboard and you press ⌘V yourself.

### Keeping permissions across rebuilds

macOS ties these grants to the app's code signature. Without a certificate, `build.sh` signs ad-hoc, and every rebuild gets a new signature, so the grants stop working (the toggles stay on but point at the old build).

One-time fix: create a self-signed code-signing certificate named **GregsUtils Dev**. In Keychain Access, choose Keychain Access → Certificate Assistant → Create a Certificate… Set Name to `GregsUtils Dev`, Identity Type to Self Signed Root, and Certificate Type to Code Signing. `build.sh` uses it automatically from then on (or set `SIGN_ID` to use another name).

When a permission stops working, reset it, relaunch, and allow it again:

```bash
tccutil reset Accessibility com.gregc.gregsutils
```

```bash
tccutil reset ScreenCapture com.gregc.gregsutils
```

## Global hotkeys

| Key | Action |
| --- | --- |
| **⇧⌘X** | Capture an area |
| **⇧⌘V** | Open / close clipboard history |
| **⌃⌥N** | New note in the editor |

Change them in **Settings…** (⌘, from the menu-bar menu, or from the editor's app menu): click a shortcut, then press the new key combination (Esc cancels). A shortcut needs ⌘, ⌃ or ⌥ plus a letter, digit, punctuation key or Space, and one that another app or macOS already uses is refused.

### Settings

Settings has Launch at Login, the three shortcuts, single-click paste, and the clipboard history limit. Changes are held in the window until you click **Save** (or press Return), which applies them all and closes it. **Cancel** (or Esc) throws them away. Closing the window with unsaved changes asks whether to save them. **Restore Defaults** fills in the defaults (it leaves Launch at Login alone); they still need Save.

Save stays disabled until something has changed, and while two shortcuts are set to the same keys (that's allowed mid-edit, so you can swap two).

## Capture

Press the capture hotkey and drag a rectangle. It can span several displays; the parts are stitched into one image at the sharpest covered display's resolution (lower-resolution displays are scaled up, and any gap between misaligned displays is transparent). The capture is copied to the clipboard right away.

Then annotate it. A toolbar appears next to the selection:

| Tool | Key | How |
| --- | --- | --- |
| Pen | P | Draw freehand. |
| Arrow | A | Drag from the tail to the point. |
| Text | T | Click where the text goes and type. Return finishes it, Esc discards it, clicking elsewhere finishes it. |
| Save | ⌘S | Close the capture and save it as a PNG. The Save dialog starts in the last folder you saved to (the Desktop at first). |

Every finished annotation re-copies the image. ⌘Z undoes the last one. Return, Esc, or clicking outside the capture (on any display) closes it.

The final image is also added to clipboard history, so you can paste it again later.

## Clipboard history

| Key | Action |
| --- | --- |
| *type* | Filter (space-separated words must all match) |
| ↑ ↓ / ⌃P ⌃N / Tab ⇧Tab | Move selection |
| Page Up / Page Down | Move a page |
| ⌘↑ / ⌘↓ | First / last item |
| ↩ | Paste the selected item into the previous app |
| ⌘1 … ⌘9 | Paste item 1–9 directly |
| ⌥↩ or ⌘C | Copy to clipboard only (no paste) |
| ⌘N | New item: type text into the history yourself |
| ⌘E | Edit the selected item |
| ⌘O | Open the selected text in a new editor tab |
| ⌘P | Pin / unpin the selected item |
| ⌥⌘↑ / ⌥⌘↓ | Move a pinned item up / down |
| ⌘⌫ | Delete the selected item from history |
| Esc | Clear search, then close |

Clicking a row pastes it. To make that a double-click instead, turn off **Paste with a single click** in Settings. You can also right-click a row for Paste, Copy, Open in Editor, New Item, Edit, Pin, Move Up/Down, and Delete. Clicking outside the panel closes it.

### Adding and editing items

⌘N (new) and ⌘E (edit) turn the preview pane under the list into an editor. **⌘↩ saves**, **Esc cancels**. Clicking another row, or clicking outside the panel, also saves. New items go to the top of the history. Edited items keep their place (and their pin).

Blank text is never saved: a new item is simply dropped, and an edited item keeps its old text (delete it with ⌘⌫ instead). Screenshots can't be edited. If an edit makes an item identical to another one, the other copy is removed.

Pinned items stay at the top in the order you pinned them, so their ⌘1–9 shortcuts don't change. They don't count toward the item limit, and Clear History keeps them.

Text you copy is recorded automatically. Images are recorded only when they come from Capture; they show a thumbnail and preview.

History keeps up to 200 unpinned items by default. Change that in **Settings… → Keep up to … items** (10 to 10,000). If a lower limit would delete items, Save asks first. The menu-bar menu has Pause Clipboard Recording and Clear Clipboard History.

**Privacy**: history is stored in `~/Library/Application Support/ClipboardManager/` (`history.json` plus an `Images` folder), readable only by you. Copies marked concealed or transient (as password managers do) are skipped.

## Editor

Open it from the menu-bar menu (Open Editor or New Note), with the New Note hotkey, or by opening the app again from Finder or Spotlight.

- Documents autosave about 0.3s after you stop typing, to `~/Library/Application Support/PlainPad/Documents/`. Tabs from the standalone PlainPad app carry over.
- Closing the last editor window just hides it. Every tab comes back the next time you open the editor.
- **⌘Q** closes the editor windows; the menu-bar tools keep running. **⌥⌘Q** (or Quit in the menu-bar menu) quits everything.
- Closing a tab (⌘W, middle-click, or ×) deletes its saved text, after confirming if it has text.
- Drag tabs to reorder, or out of the tab bar to give a tab its own window. Ctrl-Tab / Ctrl-Shift-Tab and ⌘1–⌘9 switch tabs.
- Drop text files on the window to open copies of them in new tabs.
- View → Zoom In (⌘+), Zoom Out (⌘−), Actual Size (⌘0).
- ⌘S ("Save a Copy…") exports the tab to a .txt (or .json) file.

### JSON

A tab whose text starts with `{` or `[` and ends with `}` or `]` switches to JSON mode: a monospaced font, no spelling squiggles, and a bar showing whether the JSON is valid.

- **Beautify** (⌥⇧⌘F) re-indents with 2 spaces, keeping key order, numbers and escapes as written.
- **Validate** (⌥⇧⌘J) selects the character where the problem is.
- **Collapse / expand**: the ▾ / ▸ in the gutter, ⌥⌘← / ⌥⌘→ at the cursor, ⌥⇧⌘← / ⌥⇧⌘→ for all.

## Layout

- `Sources/main.swift`, `AppDelegate.swift`: entry point, menu-bar menu, hotkeys, wiring between the tools.
- `Sources/HotKey.swift`: global hotkeys (Carbon `RegisterEventHotKey`), one handler for all of them.
- `Sources/Settings.swift`: settings and their defaults, the Settings window, and the shortcut recorder.
- `Sources/Capture/`: screen capture and the annotation overlay.
- `Sources/Clipboard/`: pasteboard watcher and history store, the history panel, and ⌘V synthesis.
- `Sources/Editor/`: the editor (`Editor.swift`) and its menus and window/Dock handling (`EditorApp.swift`).
- `Tools/make_icon.swift`: draws the app icon at build time.
