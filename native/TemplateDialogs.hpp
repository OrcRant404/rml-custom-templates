#pragma once

#include <string>

// Qt template/category management dialog. All Qt work runs on Studio's GUI
// thread via the AppKit main queue; these entry points only
// resolve symbols or copy JSON and never touch the engine or CLR.
//
// Input JSON:
//   {mode:"create"|"edit"|"category_new"|"category_edit", id?, name?, categoryId?,
//    thumbnailPath?, sourcePath?, protected?, currentPlace?, requestId?, sourceLabel?, categories:[{id,name}]}
// Output, queued through ctpl_post_command after the dialog has closed:
//   {type:"save_template", id?, name, categoryId, path?, captureThumbnail}
//   {type:"save_category", id?, name}
//   {type:"save_current_snapshot", requestId, name, categoryId, captureThumbnail, thumbnailPath?}
//   {type:"remove", id}            edit mode, after a Qt confirmation
//   {type:"remove_category", id}   category_edit when !protected, after confirmation
//   {type:"dialog_cancelled"}
//
// Process-exit-only lifecycle: widgets and their slots stay resident.

// Checks QApplication and resolves every Qt symbol used; constructs nothing.
bool ctpl_dialogs_available();
// Any thread. A newer request replaces the dialog's contents.
void ctpl_dialogs_show(const std::string& json);
void ctpl_dialogs_notice(const std::string& message);
// Any thread. Schedules a hide; later show requests are ignored.
void ctpl_dialogs_stop();
