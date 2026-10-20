#pragma once

#include <cstdint>
#include <string>

// Initialization/stop never enter Roblox. Tick is called only by the native
// engine job after its external nonblocking tick gate has been acquired.
// Process-exit-only lifecycle: live unload is unsupported. Both this code and
// its callback state must remain resident until Studio exits.
bool ctpl_ui_init();
void ctpl_ui_tick(std::uintptr_t game, const std::string& catalog_json);
void ctpl_ui_stop();

// Supplied by CustomTemplatesUI.mm. This only queues JSON for the normal managed
// worker; it must never synchronously enter CLR from an engine callback.
void ctpl_post_command(const std::string& json);
bool ctpl_try_post_command(const std::string& json) noexcept;

// Engine-context only. Content properties are not supported by the general
// interop value marshaler; use their native string conversion when available.
bool ctpl_ui_set_image(std::uintptr_t image, const std::string& uri);
// Engine-context only, for our freshly created UI controls. Uses the SDK's
// checked string conversion instead of an integer enum value in interop.
// Font accepts only BuilderSans, BuilderSansMedium, BuilderSansBold, and
// BuilderSansExtraBold, which Studio's Foundation typography uses.
bool ctpl_ui_set_style_enum(std::uintptr_t object, const std::string& property, const std::string& value);
// Pure mapping of the pinned SDK's four BuilderSans Enum.Font values; returns
// an empty string for any unsupported value. Does not enter the engine.
std::string ctpl_ui_font_name(std::int64_t enum_value);
// Engine-context only, for our freshly created text controls. Copies authored
// FontFace, TextSize, and TextScaled values through native descriptors. This
// does not resolve styling overrides; use GetStyled for computed typography.
// Each property must resolve to the same descriptor on both text objects;
// callers should use an official TextLabel donor for their own TextLabels.
// Returns false without changing anything when that compatibility check fails.
bool ctpl_ui_copy_text_style(std::uintptr_t target, std::uintptr_t source);
