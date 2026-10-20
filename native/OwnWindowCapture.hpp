#pragma once

#include <cstdint>
#include <functional>
#include <string>

// Call only on the Qt/process main thread with a freshly verified QWidget
// winId (NSView* on Cocoa). No engine/CLR API is called by this module.
// True means an asynchronous completion was scheduled, including validation
// failures. Completion runs once on main. False means the call could not be
// scheduled (wrong thread or missing callback), and no callback is made.
// Deferred work owns its argument copies; caller-local arguments may expire
// as soon as this function returns.
// The helper/code image must remain resident until all callbacks have finished.
bool ctpl_capture_owned_view(std::uintptr_t native_view_id, const std::string& output_path,
    std::function<void(bool, std::string)> completion);
