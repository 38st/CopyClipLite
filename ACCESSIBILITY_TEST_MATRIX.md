# CopyClip Lite Accessibility Verification Matrix

Automated coverage verifies the selection-order model, deletion neighbor behavior, presentation context, reduced-motion scroll branch, and accessibility labels/actions at compile time. Complete this manual matrix with VoiceOver enabled before a public release.

| Workflow | Expected result |
|---|---|
| Open from the global shortcut | Search is focused; the first visible clip is the accessibility-focused selected row |
| Press Down/Up with search focused | VoiceOver moves to and announces the adjacent visually displayed row, including preview, metadata, and selected state |
| Cross Pinned/History boundary | Announcement order matches the pinned-first visual order |
| Press Return | The selected clip is used and its row announces the copied state |
| Invoke Copy clip action | Clip is copied without moving accessibility focus away from the row |
| Invoke Pin/Unpin action | Action name reflects the current pin state and the moved row remains selected/visible |
| Invoke Delete action | Focus moves to the next row, or the previous row when the last row is removed |
| Type in Search | Normal text editing remains available; unmodified P/Delete edit text rather than acting on clips |
| Press Command-P / Command-Delete | Selected clip is changed without inserting/removing search characters |
| Enable Reduce Motion | Reordering and selection scrolling occur without animated motion |
| Empty and no-results states | VoiceOver announces the specific empty-state explanation |
| Menu-bar panel | “Open main window” is discoverable |
| Main window | No self-referential “Open main window” control is exposed |

Record the macOS version, VoiceOver verbosity settings, keyboard layout, and any failed row/action in release QA notes.
