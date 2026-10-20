#pragma once

#include <string>

// "Save to Template" and "Save to Template As…" in Studio's own File menu, placed
// after its last built-in Save item. Qt work runs only on Studio's GUI thread
// (the AppKit main queue). A menu choice reads ctpl_snapshot_document_token()
// at click time and, only when it is non-empty, queues JSON through
// ctpl_post_command (the token is JSON-encoded, never interpolated):
//   {"type":"save_current_template","documentId":"<token>"}
//   {"type":"save_current_template_as","documentId":"<token>"}
// The exporter revalidates documentId before any snapshot. Nothing here saves
// or reports success.
//
// When several File menus exist, the one on the active window's menu bar is
// used, else the only one in a QMainWindow; anything ambiguous attaches nowhere.
// Process-exit-only lifecycle: Qt owns the actions; stop hides and disables
// them, start shows them again.

// Any thread. Attaches now if a suitable File menu exists, and keeps checking
// so a rebuilt menu, a new window, or a removed/reordered pair is repaired.
// Repeated calls are safe and never add a second pair.
void ctpl_filemenu_start();
// Any thread. Hides and disables only our two actions.
void ctpl_filemenu_stop();
// Any thread. Enables both actions (the snapshot observer owns this state);
// the linked template's name, when known, becomes Save to Template's tooltip.
// Both start disabled until this says otherwise.
void ctpl_filemenu_set_state(bool can_save, const std::string& linked_template_name);
// Any thread. Shows text for about five seconds in an existing status bar of
// the active Studio main window (else the attached File menu's window).
// Never creates a status bar; no-op if none exists.
void ctpl_filemenu_status(const std::string& text);
