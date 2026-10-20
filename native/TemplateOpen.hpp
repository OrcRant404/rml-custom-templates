#pragma once

// Process-resident, pure-native GUI controller. Ordinary thumbnail working-file
// opens continue to use ctpl_open_file and never pass through this controller.
bool ctpl_template_open_start();
void ctpl_template_open_stop();
bool ctpl_template_open_pending();

// Export supplied by TemplateOpen.mm:
// bool ctpl_open_template(const char* json) noexcept;
// {requestId,id,path}, with a request-named writable working copy. Completion
// is queued as template_opened {requestId,path,stableDocumentId}, or
// template_open_failed {requestId,message}. Acceptance means queued for GUI
// processing; only template_opened confirms an untitled place was created.
