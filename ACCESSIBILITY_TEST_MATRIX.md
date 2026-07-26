# CopyClip Lite Accessibility Verification Matrix

Automated coverage verifies real keyboard-event routing with a text first responder, pinned-first order, first/middle/last deletion neighbors, copy-induced selection scrolling, presentation context, and lifecycle policy. The production build also compiles the accessibility focus/actions and the nonanimated Reduce Motion branch. A live AX-tree inspection of the packaged arm64 build 24 on 2026-07-26 confirmed that each visible clip is represented by one selected/unselected row with Copy, Pin, and Delete named actions, without duplicate icon-button entries. Those checks do not prove spoken VoiceOver output or physical animation behavior.

VoiceOver/Reduce Motion manual status as of 2026-07-26: **not executed**. Complete this matrix with VoiceOver enabled before a public release and record the results in release QA notes.

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
