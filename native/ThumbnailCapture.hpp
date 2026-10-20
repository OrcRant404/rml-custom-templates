#pragma once

#include <string>

// These entry points only enqueue Qt work. All QWidget access and capture run
// later on Studio's Qt GUI thread via the AppKit main queue.
bool ctpl_capture_request(std::string json);
void ctpl_capture_cancel();

// Writes a read-only description of the current Qt widget tree on the GUI
// thread. Intended for locating the exact Studio viewport widget by name.
bool ctpl_capture_dump_widgets(std::string output_path);

#include <cstdint>
#include <functional>
// Explicit current-document mode. GUI-thread only; the caller supplies a fresh
// Studio QWidget identity and a value-only document validator. This captures
// the existing visible QEngineWidget without opening or saving another place.
// The validator runs before capture and after completion. True schedules one
// completion on GUI; false schedules none. Existing CTPL-path capture is intact.
bool ctpl_capture_current_viewport(std::uintptr_t window, const std::string& output_path,
    std::function<bool()> document_matches, std::function<void(bool,std::string)> completion);
