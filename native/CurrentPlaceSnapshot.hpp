#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// Process-exit-only native lifecycle. Start only populates the supported native
// interop table; stop cancels pending requests without touching engine objects.
bool ctpl_snapshot_start();
void ctpl_snapshot_stop();
// Native WaitingHybridScripts context only, with no mutex or autoreleasepool
// held by the caller. Observe ALL DataModel types so Play sessions fail closed.
void ctpl_snapshot_tick(std::uintptr_t model);

// GUI/main-thread only. Empty means there is no unambiguous, fresh Edit place
// with its visible 3D viewport. The token binds the engine GetDebugId to this
// Studio window and its click-time file path/title. Never enters the engine.
std::string ctpl_snapshot_document_token();
// GUI/main-thread only; re-discovers Qt widgets and checks the token. The
// optional output is a freshly discovered QWidget pointer, borrowed only for
// the current GUI task. The thumbnail helper repeats this check on completion.
bool ctpl_snapshot_document_matches(const std::string& token, std::uintptr_t* window = nullptr);

// GUI/main-thread only; copied values for exact-path template-open completion.
// This applies the same fresh, single Edit/no Play/window guard as saving.
struct CtplOpenDocumentContext {
    std::string stable_document_id, source_path;
    std::uintptr_t window = 0;
};
std::optional<CtplOpenDocumentContext> ctpl_snapshot_open_document_context();
// GUI/main-thread only. Includes prior observed identities, so an open request
// cannot bind to a document which already existed when the request began.
std::vector<std::string> ctpl_snapshot_known_document_ids();

// Exported C entry point implemented in the .mm file:
// bool ctpl_snapshot_current(const char* json) noexcept;
// {requestId,documentId,path,thumbnailPath}; paths must be exact private staging
// saves/<requestId>/place.rbxl and saves/<requestId>/thumbnail.png. Completion is
// queued JSON current_place_snapshot/current_place_snapshot_failed; no CLR call.
// Success documentId echoes the click guard, stableDocumentId is pid:GetDebugId
// for the session template link, and thumbnailPath is omitted on capture failure.
