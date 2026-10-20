#include "StartPageUI.hpp"
#include "dotnet/interop_registry.hpp"

#include <algorithm>
#include <cmath>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
#include <dlfcn.h>

#import <Foundation/Foundation.h>

namespace {
using Handle = std::uintptr_t;
using Variant = rml::dotnet::InteropVariant;
using Tag = rml::dotnet::InteropValueTag;
using Clock = std::chrono::steady_clock;
constexpr std::string_view kPrefix = "_RMLCustomTemplates";
constexpr int kEngineCreatorRole = 3;
constexpr int kGap = 16;
constexpr int kMinCardWidth = 220;
constexpr int kPillGap = 8;
constexpr int kAddWidth = 148;
// Used only until Roblox's own text has been measured.
constexpr float kPillText = 15;
constexpr int kCompactAddWidth = 76;
// Text sizing converges on Roblox's rendered line height in a few steps.
constexpr int kTextMatchAttempts = 4;
constexpr int kSectionGap = 32;
constexpr int kSectionHeader = 58;

// Exact blittable layouts mirrored by RML's managed wrappers.
struct Vec2 { float x, y; };
struct Color { float r, g, b; };
struct Dim { float scale; std::int32_t offset; bool operator==(const Dim&) const = default; };
struct Dim2 { Dim x, y; bool operator==(const Dim2&) const = default; };
static_assert(sizeof(Vec2) == 8 && sizeof(Color) == 12 && sizeof(Dim) == 8 && sizeof(Dim2) == 16);
constexpr Color rgb(int r, int g, int b) { return {r / 255.f, g / 255.f, b / 255.f}; }
// Studio's dark Start Page palette; pills match the official unselected and
// selected Foundation pills, the accent matches Studio's primary blue.
constexpr Color kText = rgb(242, 243, 245);
constexpr Color kMuted = rgb(165, 171, 183);
constexpr Color kFaint = rgb(107, 112, 123);
constexpr Color kInk = rgb(18, 18, 21);
constexpr Color kCard = rgb(30, 31, 36);
constexpr Color kThumb = rgb(42, 44, 51);
constexpr Color kPill = rgb(39, 40, 45);
constexpr Color kSelected = rgb(255, 255, 255);
constexpr Color kAccent = rgb(0, 111, 238);
constexpr Color kError = rgb(240, 113, 120);
Dim2 offset(int x, int y) { return {{0, x}, {0, y}}; }
Dim2 size(float xs, int xo, float ys, int yo) { return {{xs, xo}, {ys, yo}}; }

enum class ActionType { Official, Category, CategoryEdit, NewCategory, Import, Open, Edit };
struct Action {
    ActionType type;
    std::string id;
    std::uint64_t generation;
};
struct EventContext {
    std::atomic<bool> enabled{true};
    Action action;
};
enum class BindingGroup { Local, Official, Category, Card };
struct Binding {
    Handle button;
    Handle connection;
    EventContext* context;
    BindingGroup group;
    std::string identity;
};
struct Entry {
    std::string id, name, date, category, thumbnail;
    bool operator==(const Entry&) const = default;
};
struct Category {
    std::string id, name;
    bool operator==(const Category&) const = default;
};
// One official pill's selection look: the only three properties that differ
// between Roblox's selected and unselected pills in the live diagnostic.
struct Look {
    Color fill{}, text{};
    float transparency = 0;
    bool operator==(const Look& other) const {
        const auto near = [](float a, float b, float tolerance) { return a - b < tolerance && b - a < tolerance; };
        const auto color = [&](const Color& a, const Color& b) {
            return near(a.r, b.r, 0.5f / 255) && near(a.g, b.g, 0.5f / 255) && near(a.b, b.b, 0.5f / 255);
        };
        return color(fill, other.fill) && color(text, other.text) && near(transparency, other.transparency, 0.005f);
    }
};
// While a custom category is showing, the official pill React considers
// selected is held in the learned unselected look, property by property.
struct Highlight {
    bool active = false, restore = true;
    std::string pill, pill_id, text_id;
    int repairs = 0;
};
// Roblox's own card, measured from a fresh official card tree and cached so
// custom categories keep the same geometry while the official grid is hidden.
struct CardMetrics {
    bool valid = false;
    int width = 0, height = 0, gap_x = 16, gap_y = 16, left = 0;
    int image_x = 0, image_y = 0, image_w = 0, image_h = 0;
    int title_x = 0, title_y = 0, title_w = 0, title_h = 0;
    float title_text = 0;  // rendered TextBounds.Y of the official title
    bool fill_known = false, image_known = false, title_known = false;
    Color fill{}, image_fill{}, title_color{};
    float fill_transparency = 0, image_transparency = 0;
    std::string key() const {
        return std::to_string(width) + 'x' + std::to_string(height) + ':' + std::to_string(gap_x) + ',' +
            std::to_string(gap_y) + ':' + std::to_string(image_x) + ',' + std::to_string(image_y) + ',' +
            std::to_string(image_w) + ',' + std::to_string(image_h) + ':' + std::to_string(title_x) + ',' +
            std::to_string(title_y) + ',' + std::to_string(title_w) + ',' + std::to_string(title_h) + ':' + std::to_string(left);
    }
};
struct TextStyle {
    std::string font;
    float size = 0;
    bool scaled = false;
    bool valid() const { return !font.empty() && size > 0; }
    std::string key() const {
        return font + ':' + std::to_string(static_cast<int>(std::lround(size * 10))) + (scaled ? ":scaled" : "");
    }
};
struct Mount { Handle game = 0, content = 0, header = 0, controls = 0, pills = 0, page = 0; };
// Hidden: an official Blank/Gameplay/Themed view. All: our section is appended
// inside Roblox's All scroll. Custom: our panel fills the page for a category.
enum class View { Hidden, All, Custom };
// Official All content extent, measured from fresh reflected geometry.
struct Geometry { int left = 0, right = 0, bottom = 0, cell = 0; };

struct State {
    rml::dotnet::InteropTable api{};
    std::once_flag populate_once;
    bool populated = false;
    std::atomic<bool> active{false};
    std::atomic<bool> reset{false};
    std::atomic<std::uint64_t> generation{0};
    std::mutex queue_mutex;
    std::deque<Action> actions;
    // Contexts remain allocated for process lifetime: a native signal already
    // copying a callback can safely observe enabled=false after disconnection.
    std::vector<std::unique_ptr<EventContext>> contexts;
    std::vector<Binding> bindings;
    Mount mount;
    std::vector<Entry> entries;
    std::vector<Category> categories;
    // Empty selection means the official grid owns the page.
    std::string selected;
    // Name of the official pill last clicked (All/Generic/Gameplay/Theme).
    // A new Templates route starts on All.
    std::string official = "All";
    View view = View::Hidden;
    // Our CanvasSize extension of the official scroll, restored on leaving All.
    bool canvas_written = false;
    Handle canvas_owner = 0;
    Dim2 canvas_saved{}, canvas_last{};
    std::string cards_key, frame_key, append_issue;
    int content_height = 0;
    bool categories_dirty = true, cards_dirty = true, visuals_dirty = true, status_error = false;
    bool have_catalog = false, mount_logged = false, error_logged = false;
    bool style_warned = false;
    // Measured from Roblox's pills; constants until the first measurement.
    Look look_on{kSelected, kInk, 0}, look_off{kPill, kText, 0};
    bool looks_valid = false;
    // Last official pill click; React's restyle may lag it briefly.
    Clock::time_point official_clicked{};
    Highlight highlight;
    CardMetrics card;
    // Font roles from the pinned Foundation styles; final sizes are matched
    // against the rendered official labels.
    TextStyle pill_style, title_style, header_style;
    // Style keys applied to the current nodes; cleared when nodes are rebuilt.
    std::string pills_applied, cards_applied, chrome_applied;
    bool apply_warned = false, typography_logged = false;
    // Rendered-height matching state.
    float pill_text_height = 0;
    bool pill_text_pending = false, card_text_pending = false, cards_fallback_copied = false;
    int pill_text_attempts = 0, card_text_attempts = 0;
    std::int64_t revision = 0, select_revision = -1;
    std::string status, local_status, layout_key, heading_text;
    bool local_error = false;
    Clock::time_point local_until{};
};

State& state() {
    static State* const value = new State();
    return *value;
}

// Only returned variants own memory. Input strings/blittables borrow synchronous
// caller storage. Instance handles themselves are borrowed and are never freed.
void free_result(Variant& value) {
    auto& api = state().api;
    if (value.tag == Tag::String && value.as_string)
        api.free_string(value.as_string);
    else if ((value.tag == Tag::InstanceArray || value.tag == Tag::Blittable) && value.as_instance)
        api.free_native_ptr(reinterpret_cast<const void*>(value.as_instance));
    value = {};
}
struct Result {
    Variant value{};
    ~Result() { free_result(value); }
    Result() = default;
    Result(const Result&) = delete;
    Result& operator=(const Result&) = delete;
};

void set(Handle object, const char* property, const Variant& value) {
    if (object)
        state().api.reflection_set_property(object, property, &value);
}
void set_bool(Handle object, const char* property, bool value) {
    Variant v{}; v.tag = Tag::Bool; v.as_bool = value; set(object, property, v);
}
void set_int(Handle object, const char* property, std::int64_t value) {
    Variant v{}; v.tag = Tag::Int64; v.as_int64 = value; set(object, property, v);
}
void set_float(Handle object, const char* property, float value) {
    Variant v{}; v.tag = Tag::Float; v.as_float = value; set(object, property, v);
}
void set_string(Handle object, const char* property, const std::string& value) {
    Variant v{}; v.tag = Tag::String; v.as_string = const_cast<char*>(value.c_str()); set(object, property, v);
}
void set_parent(Handle object, Handle parent) {
    Variant v{}; v.tag = parent ? Tag::Instance : Tag::Null; v.as_instance = parent; set(object, "Parent", v);
}
template<class T> void set_struct(Handle object, const char* property, const T& value) {
    Variant v{}; v.tag = Tag::Blittable; v.as_instance = reinterpret_cast<Handle>(&value); set(object, property, v);
}
bool get_bool(Handle object, const char* property) {
    if (!object) return false;
    Result result;
    state().api.reflection_get_property(object, property, &result.value);
    return result.value.tag == Tag::Bool && result.value.as_bool;
}
// Numbers arrive as Float, Double, or Int64 depending on the property.
double get_number(Handle object, const char* property, double fallback = 0) {
    if (!object) return fallback;
    Result result;
    state().api.reflection_get_property(object, property, &result.value);
    switch (result.value.tag) {
    case Tag::Float: return result.value.as_float;
    case Tag::Double: return result.value.as_double;
    case Tag::Int64: return static_cast<double>(result.value.as_int64);
    default: return fallback;
    }
}
std::string get_string(Handle object, const char* property) {
    if (!object) return {};
    Result result;
    state().api.reflection_get_property(object, property, &result.value);
    return result.value.tag == Tag::String && result.value.as_string ? result.value.as_string : "";
}
template<class T> T get_struct(Handle object, const char* property) {
    T value{};
    if (!object) return value;
    Result result;
    state().api.reflection_get_property(object, property, &result.value);
    if (result.value.tag == Tag::Blittable && result.value.as_instance)
        std::memcpy(&value, reinterpret_cast<const void*>(result.value.as_instance), sizeof(T));
    return value;
}
std::vector<Handle> children(Handle parent) {
    std::vector<Handle> values;
    if (!parent) return values;
    Result result;
    state().api.reflection_invoke(parent, "GetChildren", nullptr, 0, &result.value);
    if (result.value.tag != Tag::InstanceArray || !result.value.as_instance)
        return values;
    const auto* buffer = reinterpret_cast<const std::byte*>(result.value.as_instance);
    std::uint32_t count = 0;
    std::memcpy(&count, buffer, sizeof(count));
    if (count > 100000)
        throw std::runtime_error("Instance child count exceeds the UI traversal bound");
    values.reserve(count);
    // The SDK reserves eight bytes for the count header, though count is u32.
    for (std::uint32_t index = 0; index < count; ++index) {
        Handle handle = 0;
        std::memcpy(&handle, buffer + 8 + index * sizeof(Handle), sizeof(handle));
        if (handle) values.push_back(handle);
    }
    return values;
}
// One fresh traversal per parent; lookups then avoid repeated GetChildren calls.
struct Children {
    std::vector<std::pair<std::string, Handle>> items;
    explicit Children(Handle parent) {
        for (const auto handle : children(parent)) items.emplace_back(get_string(handle, "Name"), handle);
    }
    Handle operator[](std::string_view name) const {
        for (const auto& [key, handle] : items)
            if (key == name) return handle;
        return 0;
    }
};
Handle child(Handle parent, const std::string& name) {
    for (const auto handle : children(parent))
        if (get_string(handle, "Name") == name)
            return handle;
    return 0;
}
std::string debug_id(Handle object) {
    Variant argument{}; argument.tag = Tag::Int64; argument.as_int64 = 32;
    Result result;
    state().api.reflection_invoke(object, "GetDebugId", &argument, 1, &result.value);
    return result.value.tag == Tag::String && result.value.as_string ? result.value.as_string : "";
}
bool gui_class(const std::string& name) {
    return name == "Frame" || name == "ScrollingFrame" || name == "ImageButton" ||
        name == "TextButton" || name == "TextLabel" || name == "ImageLabel" || name == "TextBox" ||
        name == "CanvasGroup" || name == "ViewportFrame" || name == "VideoFrame";
}
bool button_class(const std::string& name) { return name == "ImageButton" || name == "TextButton"; }
bool owned(Handle object) { return get_string(object, "Name").starts_with(kPrefix); }
std::string named(std::string_view suffix) { return std::string(kPrefix).append(suffix); }

void log(const std::string& message, bool error = false) {
    auto& api = state().api;
    if (api.managed_log)
        api.managed_log(error ? 4 : 2, message.c_str(), static_cast<std::int32_t>(message.size()));
}
// Enum properties go only through the helper's validated string adapter, and
// only on our own nodes. If it refuses, the Roblox default (centred text,
// stretched image) stays, which is the established fallback.
void style(Handle object, const char* property, const char* value) {
    auto& ui = state();
    if (object && !ctpl_ui_set_style_enum(object, property, value) && !ui.style_warned) {
        log(std::string("Custom Templates could not set ") + property + "; using the default.");
        ui.style_warned = true;
    }
}

// Roblox's TextLabel defaults. A read returning exactly these means the value
// comes from styling the reflected getter does not see (the live diagnostic
// showed invisible labels reporting them), so it is treated as unknown.
constexpr Color kDefaultFill = rgb(163, 162, 165);
constexpr Color kDefaultText = rgb(27, 42, 53);
bool same_color(const Color& a, const Color& b) {
    const auto near = [](float x, float y) { return x - y < 0.5f / 255 && y - x < 0.5f / 255; };
    return near(a.r, b.r) && near(a.g, b.g) && near(a.b, b.b);
}

// BuilderSans roles from this pinned Studio build's bundled Foundation
// typography. RML cannot safely invoke GetStyled's dynamic Variant return.
// Rendered official TextBounds below determine the final matching text size.
// Applies a Foundation font role to one of our text controls: Font through the
// checked enum adapter, TextSize and TextScaled as plain values. Works across
// TextLabel/TextButton because nothing is copied by descriptor.
bool apply_text(Handle target, const TextStyle& style, float scale = 1) {
    if (!target || !style.valid() || !ctpl_ui_set_style_enum(target, "Font", style.font)) return false;
    set_float(target, "TextSize", std::max(8.f, std::round(style.size * scale)));
    set_bool(target, "TextScaled", style.scaled);
    return true;
}
// Fallback only when styled values are unavailable: the authored native copy
// (same text class only, as the helper requires) ...
bool copy_text_style(Handle target, Handle source) {
    return target && source && ctpl_ui_copy_text_style(target, source);
}
// ... then one correction step toward Roblox's rendered line height. Waiting
// (nothing rendered yet, or no donor) never counts as an attempt.
enum class Fit { Ready, Adjusted, Waiting };
Fit match_text_height(Handle target, float official_height, float scale = 1) {
    const float ours = get_struct<Vec2>(target, "TextBounds").y;
    if (!target || official_height <= 0 || ours <= 0) return Fit::Waiting;
    const float ratio = official_height * scale / ours;
    if (ratio > 0.94f && ratio < 1.06f) return Fit::Ready;
    const float size = static_cast<float>(get_number(target, "TextSize", kPillText));
    set_float(target, "TextSize", std::clamp(std::round(size * ratio), 8.f, 40.f));
    return Fit::Adjusted;
}

void on_click(void* data, const Variant*, std::uint32_t) {
    auto* context = static_cast<EventContext*>(data);
    auto& ui = state();
    if (!context || !context->enabled.load(std::memory_order_acquire) ||
        !ui.active.load(std::memory_order_acquire) ||
        context->action.generation != ui.generation.load(std::memory_order_acquire))
        return;
    try {
        Action action = context->action;
        // This mutex protects plain native queue data only, never an engine call.
        std::lock_guard lock(ui.queue_mutex);
        if (ui.actions.size() < 512)
            ui.actions.push_back(std::move(action));
    } catch (...) { }
}
void disconnect(Binding& binding) {
    binding.context->enabled.store(false, std::memory_order_release);
    if (binding.connection)
        state().api.reflection_event_disconnect(binding.connection);
    binding.connection = 0;
}
void detach_all() {
    auto& ui = state();
    ui.generation.fetch_add(1, std::memory_order_acq_rel);
    for (auto& binding : ui.bindings) disconnect(binding);
    ui.bindings.clear();
}
void detach_group(BindingGroup group) {
    auto& bindings = state().bindings;
    for (auto it = bindings.begin(); it != bindings.end();) {
        if (it->group == group) {
            disconnect(*it);
            it = bindings.erase(it);
        } else ++it;
    }
}
void bind(Handle button, ActionType action, const std::string& id = {},
    BindingGroup group = BindingGroup::Local, std::string identity = {},
    const char* event = "MouseButton1Click") {
    auto& ui = state();
    auto context = std::make_unique<EventContext>();
    context->action = {action, id, ui.generation.load(std::memory_order_acquire)};
    auto* data = context.get();
    ui.contexts.push_back(std::move(context));
    const Handle connection = ui.api.reflection_event_connect(button, event, &on_click, data);
    if (!connection) {
        data->enabled.store(false, std::memory_order_release);
        throw std::runtime_error("Could not connect a native template button");
    }
    ui.bindings.push_back({button, connection, data, group, std::move(identity)});
}

Handle create(const char* class_name, const std::string& name) {
    const Handle object = state().api.object_create_by_name(class_name, kEngineCreatorRole);
    if (!object) throw std::runtime_error("Could not create a template GUI object");
    set_string(object, "Name", name);
    return object;
}
void round(Handle parent, int radius) {
    const auto corner = create("UICorner", "UICorner");
    set_struct(corner, "CornerRadius", Dim{0, radius});
    set_parent(corner, parent);
}
void position(Handle object, int x, int y) { set_struct(object, "Position", offset(x, y)); }
void dimensions(Handle object, int width, int height) { set_struct(object, "Size", offset(width, height)); }
void place(Handle object, int x, int y, int width, int height) { position(object, x, y); dimensions(object, width, height); }
Handle frame(Handle parent, const std::string& name, int z) {
    const auto object = create("Frame", name);
    set_float(object, "BackgroundTransparency", 1);
    set_int(object, "BorderSizePixel", 0);
    set_int(object, "ZIndex", z);
    set_parent(object, parent);
    return object;
}
Handle button(Handle parent, const std::string& name, const std::string& text, Color fill, int radius, int z = 25) {
    const auto object = create("TextButton", name);
    set_string(object, "Text", text);
    set_int(object, "BorderSizePixel", 0);
    set_struct(object, "BackgroundColor3", fill);
    set_struct(object, "TextColor3", kText);
    set_float(object, "TextSize", 14);
    set_bool(object, "AutoButtonColor", true);
    set_int(object, "ZIndex", z);
    set_parent(object, parent);
    round(object, radius);
    return object;
}
Handle label(Handle parent, const char* name, const std::string& text, int font_size, Color color = kText, int z = 24) {
    const auto object = create("TextLabel", name);
    set_string(object, "Text", text);
    set_float(object, "BackgroundTransparency", 1);
    set_int(object, "BorderSizePixel", 0);
    set_float(object, "TextSize", static_cast<float>(font_size));
    set_struct(object, "TextColor3", color);
    set_int(object, "ZIndex", z);
    set_parent(object, parent);
    return object;
}

Mount discover(Handle game) {
    Mount mount; mount.game = game;
    Handle current = child(child(game, "RobloxPluginGuiService"), "StartPage");
    for (const char* name : {"Wrapper", "Children", "Wrapper", "SafetyFAEUpsellContextScope", "Children", "Content"})
        current = child(current, name);
    mount.content = current;
    mount.header = child(current, "Header");
    mount.controls = child(current, "Controls");
    mount.pills = child(mount.controls, "Pills");
    mount.page = child(current, "PageComponent");
    return mount;
}
bool valid(const Mount& mount) { return mount.content && mount.header && mount.controls && mount.pills && mount.page; }

// Roblox's own grid: the first non-owned ScrollingFrame under PageComponent.
Handle official_scroll(Handle page) {
    for (const auto object : children(page))
        if (!owned(object) && get_string(object, "ClassName") == "ScrollingFrame") return object;
    return 0;
}
// One of Roblox's template cards, by the structure in the captured tree:
// Button > Child > Image, and Button > Child > Body > Options > Title.
struct OfficialCard { Handle button = 0, child = 0, image = 0, title = 0; };
std::optional<OfficialCard> official_card(Handle button) {
    if (!button || owned(button) || !button_class(get_string(button, "ClassName"))) return std::nullopt;
    OfficialCard card{button, child(button, "Child")};
    card.image = child(card.child, "Image");
    card.title = child(child(child(card.child, "Body"), "Options"), "Title");
    if (!card.child || !card.image || !card.title || get_string(card.image, "ClassName") != "ImageLabel" ||
        get_string(card.title, "ClassName") != "TextLabel")
        return std::nullopt;
    return card;
}
// A live official title to copy typography from; hidden cards work too.
Handle official_title(Handle scroll) {
    for (const auto object : children(scroll))
        if (const auto card = official_card(object)) return card->title;
    return 0;
}
// Measures Roblox's card (size, image and title placement, grid gaps, left
// inset) from fresh visible cards. Colours are taken only when the reflected
// value is not a Roblox default. Returns whether the cached metrics changed.
bool learn_cards(Handle scroll) {
    auto& ui = state();
    const auto origin = get_struct<Vec2>(scroll, "AbsolutePosition");
    const auto canvas = get_struct<Vec2>(scroll, "CanvasPosition");
    std::vector<std::pair<Vec2, Vec2>> boxes;
    CardMetrics next = ui.card;
    bool first = true;
    for (const auto object : children(scroll)) {
        const auto card = official_card(object);
        if (!card || !get_bool(object, "Visible")) continue;
        const auto at = get_struct<Vec2>(object, "AbsolutePosition");
        const auto extent = get_struct<Vec2>(object, "AbsoluteSize");
        if (extent.x <= 0 || extent.y <= 0) continue;
        boxes.emplace_back(at, extent);
        if (!first) continue;
        const auto image_at = get_struct<Vec2>(card->image, "AbsolutePosition");
        const auto image_size = get_struct<Vec2>(card->image, "AbsoluteSize");
        const auto title_at = get_struct<Vec2>(card->title, "AbsolutePosition");
        const auto title_size = get_struct<Vec2>(card->title, "AbsoluteSize");
        if (image_size.x <= 0 || image_size.y <= 0 || title_size.x <= 0 || title_size.y <= 0) continue;
        first = false;
        const auto whole = [](float value) { return static_cast<int>(std::lround(value)); };
        next.width = whole(extent.x); next.height = whole(extent.y);
        next.image_x = whole(image_at.x - at.x); next.image_y = whole(image_at.y - at.y);
        next.image_w = whole(image_size.x); next.image_h = whole(image_size.y);
        next.title_x = whole(title_at.x - at.x); next.title_y = whole(title_at.y - at.y);
        next.title_w = whole(title_size.x); next.title_h = whole(title_size.y);
        next.title_text = get_struct<Vec2>(card->title, "TextBounds").y;
        // The visible card surface is the button or its Child frame.
        next.fill_known = false;
        for (const auto surface : {card->button, card->child}) {
            const auto fill = get_struct<Color>(surface, "BackgroundColor3");
            const double transparency = get_number(surface, "BackgroundTransparency", -1);
            if (transparency < 0 || same_color(fill, kDefaultFill)) continue;
            if (!next.fill_known || transparency < next.fill_transparency) {
                next.fill = fill; next.fill_transparency = static_cast<float>(transparency); next.fill_known = true;
            }
        }
        const auto image_fill = get_struct<Color>(card->image, "BackgroundColor3");
        const double image_transparency = get_number(card->image, "BackgroundTransparency", -1);
        next.image_known = image_transparency >= 0 && !same_color(image_fill, kDefaultFill);
        next.image_fill = image_fill; next.image_transparency = static_cast<float>(image_transparency);
        const auto title_color = get_struct<Color>(card->title, "TextColor3");
        next.title_known = !same_color(title_color, kDefaultText);
        next.title_color = title_color;
    }
    if (first) return false;
    // Grid gaps: nearest neighbour in the same row / column.
    int gap_x = 0, gap_y = 0;
    float left = boxes.front().first.x;
    for (const auto& [a, a_size] : boxes) {
        left = std::min(left, a.x);
        for (const auto& [b, b_size] : boxes) {
            const float dx = b.x - (a.x + a_size.x), dy = b.y - (a.y + a_size.y);
            if (std::fabs(a.y - b.y) < 2 && dx > 0 && (gap_x == 0 || dx < gap_x)) gap_x = static_cast<int>(std::lround(dx));
            if (std::fabs(a.x - b.x) < 2 && dy > 0 && (gap_y == 0 || dy < gap_y)) gap_y = static_cast<int>(std::lround(dy));
        }
    }
    if (gap_x > 0) next.gap_x = gap_x;
    if (gap_y > 0) next.gap_y = gap_y;
    next.left = static_cast<int>(std::lround(left - origin.x + canvas.x));
    next.valid = next.width >= 80 && next.image_w >= 40 && next.image_h >= 40;
    if (!next.valid) return false;
    const bool changed = !ui.card.valid || next.key() != ui.card.key() ||
        std::fabs(next.title_text - ui.card.title_text) > 0.5f;
    ui.card = next;
    return changed;
}

// Restores the official CanvasSize only on the exact live scroll we extended.
void restore_canvas(Handle scroll) {
    auto& ui = state();
    if (ui.canvas_written && scroll && scroll == ui.canvas_owner) set_struct(scroll, "CanvasSize", ui.canvas_saved);
    ui.canvas_written = false;
    ui.canvas_owner = 0;
}

void end_highlight(Handle pills);
void mount_ui(const Mount& mount, bool new_route) {
    auto& ui = state();
    detach_all();
    end_highlight(mount.pills);
    const auto scroll = official_scroll(mount.page);
    restore_canvas(scroll);
    // Only freshly discovered live nodes are unparented. No Destroy/descendant
    // reflected methods and no raw Instance/shared_ptr layouts are used.
    for (const Handle parent : {mount.header, mount.controls, mount.page, scroll})
        for (const Handle object : children(parent))
            if (owned(object)) set_parent(object, 0);
    ui.mount = mount;
    if (new_route) ui.official = "All";
    ui.view = View::Hidden;
    ui.layout_key.clear();
    ui.heading_text.clear();
    ui.cards_key.clear();
    ui.frame_key.clear();
    ui.pills_applied.clear(); ui.cards_applied.clear(); ui.chrome_applied.clear();
    ui.categories_dirty = ui.cards_dirty = ui.visuals_dirty = true;

    // Controls lays out its own children, so ours share one container that
    // follows Roblox's pills. Inside it we place things ourselves: category
    // pills in a clipped scroller, then Add at the page's right edge.
    const auto actions = frame(mount.controls, named("Actions"), 25);
    set_int(actions, "LayoutOrder", 1000);
    const auto strip = create("ScrollingFrame", "Categories");
    set_float(strip, "BackgroundTransparency", 1);
    set_int(strip, "BorderSizePixel", 0);
    set_int(strip, "ScrollBarThickness", 0);
    set_bool(strip, "ClipsDescendants", true);
    set_struct(strip, "CanvasSize", offset(0, 0));
    set_int(strip, "ZIndex", 25);
    set_parent(strip, actions);
    const auto plus = button(actions, "NewCategory", "+", kPill, 999);
    set_struct(plus, "TextColor3", kMuted);
    bind(plus, ActionType::NewCategory);
    const auto add = button(actions, "Add", "+  Add Template", kAccent, 8);
    bind(add, ActionType::Import);

    // The panel moves between PageComponent (a custom category fills the page)
    // and Roblox's All scroll (our section follows the official cards).
    const auto panel = frame(mount.page, named("Panel"), 20);
    set_struct(panel, "Size", size(1, 0, 1, 0));
    set_bool(panel, "Visible", false);
    // Our own heading: the category name, or "Your templates" inside All.
    // Roblox's Header is never touched.
    const auto heading = label(panel, "Heading", "", 18, kText);
    set_struct(heading, "Size", size(1, -8, 0, 28));
    const auto status = label(panel, "Status", "", 12, kMuted);
    set_struct(status, "Size", size(1, -8, 0, 28));
    set_bool(status, "TextWrapped", true);
    // Left-aligned with the card grid below, like Roblox's own page title.
    style(heading, "TextXAlignment", "Left");
    style(status, "TextXAlignment", "Left");
    const auto cards = create("ScrollingFrame", "Cards");
    position(cards, 0, 36);
    set_struct(cards, "Size", size(1, 0, 1, -36));
    set_float(cards, "BackgroundTransparency", 1);
    set_int(cards, "BorderSizePixel", 0);
    set_struct(cards, "CanvasSize", offset(0, 0));
    set_int(cards, "ScrollBarThickness", 6);
    set_struct(cards, "ScrollBarImageColor3", kFaint);
    set_int(cards, "ZIndex", 21);
    set_parent(cards, panel);
    if (!ui.mount_logged) {
        log("Custom Templates native UI mounted on the Templates page.");
        ui.mount_logged = true;
    }
}

// Layout keys encode measured numbers and colours compactly.
std::string json_number(double value) {
    char text[32];
    std::snprintf(text, sizeof(text), "%.6g", value);
    return text;
}
std::string json_color(const Color& value) {
    return "[" + json_number(value.r * 255) + "," + json_number(value.g * 255) + "," + json_number(value.b * 255) + "]";
}
// Official pills only ever receive a deselect listener; they never get edit
// or context bindings.
void reconcile_pills(Handle pills) {
    auto& ui = state();
    std::vector<std::pair<Handle, std::string>> current;
    for (const auto object : children(pills))
        if (button_class(get_string(object, "ClassName"))) current.emplace_back(object, debug_id(object));
    for (auto it = ui.bindings.begin(); it != ui.bindings.end();) {
        if (it->group == BindingGroup::Official &&
            std::find(current.begin(), current.end(), std::pair{it->button, it->identity}) == current.end()) {
            disconnect(*it);
            it = ui.bindings.erase(it);
        } else ++it;
    }
    // Deselect listener only; the action id is the pill's Name, which says
    // which official view React is about to show.
    for (const auto& [object, identity] : current) {
        const bool bound = std::any_of(ui.bindings.begin(), ui.bindings.end(), [&](const Binding& binding) {
            return binding.group == BindingGroup::Official && binding.button == object && binding.identity == identity;
        });
        if (!bound) bind(object, ActionType::Official, get_string(object, "Name"), BindingGroup::Official, identity);
    }
}

std::string utf8(id value) {
    return [value isKindOfClass:NSString.class] && [value UTF8String] ? [value UTF8String] : "";
}
std::int64_t integer(id value, std::int64_t fallback = 0) {
    return [value isKindOfClass:NSNumber.class] ? [value longLongValue] : fallback;
}
bool has_category(const std::string& id) {
    const auto& categories = state().categories;
    return std::any_of(categories.begin(), categories.end(), [&](const Category& value) { return value.id == id; });
}
void select(std::string id) {
    auto& ui = state();
    if (!id.empty() && !has_category(id)) id.clear();
    if (id == ui.selected) return;
    ui.selected = std::move(id);
    ui.visuals_dirty = true;
}
void receive_catalog(const std::string& json) {
    if (json.empty()) return;
    // Pools are pthread-local, while an engine reflection call can migrate its
    // fiber. This scope performs JSON/native-state work only and ends first.
    @autoreleasepool {
        NSData* const data = [NSData dataWithBytes:json.data() length:json.size()];
        id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![decoded isKindOfClass:NSDictionary.class]) return;
        NSDictionary* const catalog = decoded;
        auto& ui = state();
        const auto revision = integer(catalog[@"revision"]);
        const auto selection = integer(catalog[@"selectRevision"]);
        const auto status = utf8(catalog[@"status"]);
        if (!ui.have_catalog || revision != ui.revision) {
            std::vector<Category> categories;
            id category_values = catalog[@"categories"];
            if ([category_values isKindOfClass:NSArray.class]) {
                for (id value in category_values) {
                    if (![value isKindOfClass:NSDictionary.class]) continue;
                    const auto id = utf8(value[@"id"]);
                    if (!id.empty()) categories.push_back({id, utf8(value[@"name"])});
                }
            }
            std::vector<Entry> entries;
            id templates = catalog[@"templates"];
            if ([templates isKindOfClass:NSArray.class]) {
                for (id value in templates) {
                    if (![value isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary* const entry = value;
                    // Every catalog entry is user-owned; builtins never appear here.
                    if ([entry[@"owned"] isKindOfClass:NSNumber.class] && ![entry[@"owned"] boolValue]) continue;
                    const auto id = utf8(entry[@"id"]);
                    if (!id.empty())
                        entries.push_back({id, utf8(entry[@"name"]), utf8(entry[@"date"]),
                            utf8(entry[@"categoryId"]), utf8(entry[@"thumbnailUri"])});
                }
            }
            if (categories != ui.categories) {
                ui.categories = std::move(categories);
                ui.categories_dirty = true;
                // Names on cards and in the heading depend on categories.
                ui.cards_dirty = true;
            }
            if (entries != ui.entries) {
                ui.entries = std::move(entries);
                ui.cards_dirty = true;
            }
            ui.revision = revision;
            ui.have_catalog = true;
            if (!ui.selected.empty() && !has_category(ui.selected)) select({});
        }
        if (selection > ui.select_revision) {
            const auto requested = utf8(catalog[@"selectedCategoryId"]);
            if (selection > 0 && !requested.empty()) select(requested);
            ui.select_revision = selection;
            ui.local_until = {};
        }
        if (status != ui.status) ui.local_until = {};
        ui.status = status;
        ui.status_error = [catalog[@"statusError"] isKindOfClass:NSNumber.class] && [catalog[@"statusError"] boolValue];
    }
}

void post(const char* type, const std::string& id = {}, const char* id_key = "id") {
    std::string command;
    @autoreleasepool {
        NSString* const command_type = [NSString stringWithUTF8String:type];
        NSMutableDictionary* const value = [NSMutableDictionary dictionaryWithObject:command_type forKey:@"type"];
        if (!id.empty()) {
            NSString* const text = [[NSString alloc] initWithBytes:id.data() length:id.size() encoding:NSUTF8StringEncoding];
            if (text) value[[NSString stringWithUTF8String:id_key]] = text;
        }
        NSData* const data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        if (data) command.assign(static_cast<const char*>(data.bytes), data.length);
    }
    if (!command.empty()) ctpl_post_command(command);
}
void local_status(const std::string& text) {
    auto& ui = state(); ui.local_status = text; ui.local_error = false;
    ui.local_until = Clock::now() + std::chrono::seconds(8);
}
bool known_entry(const std::string& id) {
    const auto& entries = state().entries;
    return std::any_of(entries.begin(), entries.end(), [&](const Entry& entry) { return entry.id == id; });
}
void process_actions() {
    auto& ui = state();
    std::deque<Action> pending;
    { std::lock_guard lock(ui.queue_mutex); pending.swap(ui.actions); }
    for (const auto& action : pending) {
        if (action.generation != ui.generation.load(std::memory_order_acquire)) continue;
        switch (action.type) {
        case ActionType::Official:
            // Clicking the pill React already shows as selected changes
            // nothing in React, so its look is restored by us; any other pill
            // is rewritten by React itself.
            ui.highlight.restore = action.id == ui.highlight.pill;
            ui.official_clicked = Clock::now();
            select({});
            if (!action.id.empty() && action.id != ui.official) { ui.official = action.id; ui.visuals_dirty = true; }
            break;
        case ActionType::Category: select(action.id); break;
        case ActionType::CategoryEdit:
            if (has_category(action.id)) post("category_edit", action.id);
            break;
        case ActionType::NewCategory: post("category_new"); break;
        case ActionType::Import:
            // The dialog preselects the category being viewed, if any.
            post("import", ui.selected, "categoryId");
            break;
        case ActionType::Open:
            if (known_entry(action.id)) { post("open", action.id); local_status("Opening a fresh copy…"); }
            break;
        case ActionType::Edit:
            if (known_entry(action.id)) post("edit", action.id);
            break;
        }
    }
}

const Category* category(const std::string& id) {
    for (const auto& value : state().categories)
        if (value.id == id) return &value;
    return nullptr;
}
std::string monogram(const std::string& name) {
    if (name.empty()) return "?";
    const auto lead = static_cast<unsigned char>(name[0]);
    const std::size_t length = lead < 0x80 ? 1 : lead >> 5 == 0x6 ? 2 : lead >> 4 == 0xE ? 3 : lead >> 3 == 0x1E ? 4 : 1;
    std::string value = name.substr(0, std::min(length, name.size()));
    if (length == 1 && value[0] >= 'a' && value[0] <= 'z') value[0] = static_cast<char>(value[0] - 'a' + 'A');
    return value;
}

void build_pills(Handle strip) {
    auto& ui = state();
    detach_group(BindingGroup::Category);
    for (const auto object : children(strip)) set_parent(object, 0);
    ui.pills_applied.clear();
    ui.pill_text_pending = true;
    ui.pill_text_attempts = 0;
    for (std::size_t index = 0; index < ui.categories.size(); ++index) {
        const auto& value = ui.categories[index];
        const auto pill = button(strip, "Category_" + value.id, value.name.empty() ? "Untitled" : value.name, kPill, 999);
        // Typography is applied by style_controls, then height-matched.
        set_float(pill, "TextSize", kPillText);
        set_int(pill, "LayoutOrder", static_cast<std::int64_t>(index));
        // Left click filters; right click opens the Qt category editor.
        bind(pill, ActionType::Category, value.id, BindingGroup::Category);
        bind(pill, ActionType::CategoryEdit, value.id, BindingGroup::Category, {}, "MouseButton2Click");
    }
    ui.layout_key.clear();
}

void build_cards(Handle scroll) {
    auto& ui = state();
    detach_group(BindingGroup::Card);
    ui.cards_applied.clear();
    ui.cards_fallback_copied = false;
    ui.card_text_pending = true;
    ui.card_text_attempts = 0;
    for (const auto object : children(scroll)) set_parent(object, 0);

    // The empty state always exists; switching categories only toggles it.
    const auto empty = frame(scroll, "Empty", 22);
    set_struct(empty, "Size", size(1, -8, 0, 200));
    set_bool(empty, "Visible", false);
    const auto glyph = label(empty, "Glyph", "+", 30, kMuted, 23);
    set_float(glyph, "BackgroundTransparency", 0);
    set_struct(glyph, "BackgroundColor3", kThumb);
    set_struct(glyph, "AnchorPoint", Vec2{0.5f, 0});
    set_struct(glyph, "Position", size(0.5f, 0, 0, 24));
    dimensions(glyph, 56, 56);
    round(glyph, 999);
    const auto heading = label(empty, "Heading", "", 20, kText, 23);
    position(heading, 0, 92); set_struct(heading, "Size", size(1, 0, 0, 28));
    const auto hint = label(empty, "Hint", "Add a .rbxl or .rbxlx place. Custom Templates keeps its own copy, so your file never changes.", 14, kMuted, 23);
    position(hint, 0, 122); set_struct(hint, "Size", size(1, 0, 0, 22));
    set_bool(hint, "TextWrapped", true);
    const auto add = button(empty, "Add", "+  Add Template", kAccent, 8, 24);
    set_struct(add, "AnchorPoint", Vec2{0.5f, 0});
    set_struct(add, "Position", size(0.5f, 0, 0, 158));
    dimensions(add, 160, 36);
    bind(add, ActionType::Import, {}, BindingGroup::Card);

    for (const auto& entry : ui.entries) {
        // The whole card is the Open copy target; right click edits it.
        const auto card = button(scroll, "Template_" + entry.id, "", kCard, 10, 22);
        bind(card, ActionType::Open, entry.id, BindingGroup::Card);
        bind(card, ActionType::Edit, entry.id, BindingGroup::Card, {}, "MouseButton2Click");

        const auto thumb = create("ImageLabel", "Thumb");
        set_struct(thumb, "BackgroundColor3", kThumb);
        set_int(thumb, "BorderSizePixel", 0);
        set_int(thumb, "ZIndex", 23);
        // Any aspect ratio fills Roblox's square image frame without distortion.
        style(thumb, "ScaleType", "Crop");
        const bool image_set = entry.thumbnail.empty() || ctpl_ui_set_image(thumb, entry.thumbnail);
        if (!image_set) log("Custom Templates could not set the local thumbnail content.", true);
        set_parent(thumb, card);
        round(thumb, 4);
        // Until a capture exists, a monogram stands in; never a fake screenshot.
        const auto placeholder = frame(thumb, "Placeholder", 24);
        set_struct(placeholder, "Size", size(1, 0, 1, 0));
        set_bool(placeholder, "Visible", entry.thumbnail.empty() || !image_set);
        const auto disc = label(placeholder, "Monogram", monogram(entry.name), 28, kText, 25);
        set_float(disc, "BackgroundTransparency", 0.55f);
        set_struct(disc, "BackgroundColor3", kAccent);
        set_struct(disc, "AnchorPoint", Vec2{0.5f, 0.5f});
        set_struct(disc, "Position", size(0.5f, 0, 0.5f, -10));
        dimensions(disc, 56, 56);
        round(disc, 999);
        const auto pending = label(placeholder, "Caption", "No preview yet", 12, kFaint, 25);
        set_struct(pending, "AnchorPoint", Vec2{0.5f, 0.5f});
        set_struct(pending, "Position", size(0.5f, 0, 0.5f, 34));
        dimensions(pending, 160, 16);

        // Diagonal OWNED ribbon: an unrotated clipping corner holding a band
        // rotated 45 degrees, so it reads across the top-right corner.
        const auto ribbon = frame(thumb, "Ribbon", 26);
        set_bool(ribbon, "ClipsDescendants", true);
        const auto band = create("Frame", "Band");
        set_struct(band, "BackgroundColor3", kAccent);
        set_int(band, "BorderSizePixel", 0);
        set_struct(band, "AnchorPoint", Vec2{0.5f, 0.5f});
        position(band, 48, 24);
        dimensions(band, 112, 18);
        set_float(band, "Rotation", 45);
        set_int(band, "ZIndex", 27);
        set_parent(band, ribbon);
        const auto mark = label(band, "Label", "OWNED", 11, kText, 28);
        set_struct(mark, "Size", size(1, 0, 1, 0));

        const auto edit = button(thumb, "Edit", "Edit", kInk, 6, 28);
        set_float(edit, "BackgroundTransparency", 0.25f);
        set_float(edit, "TextSize", 11);
        bind(edit, ActionType::Edit, entry.id, BindingGroup::Card);

        const auto title = label(card, "Title", entry.name.empty() ? "Untitled" : entry.name, 14, kText, 24);
        set_bool(title, "ClipsDescendants", true);
        const auto meta = label(card, "Meta", "", 11, kMuted, 24);
        style(title, "TextXAlignment", "Left");
        style(meta, "TextXAlignment", "Left");
        set_bool(meta, "ClipsDescendants", true);
    }
}

// Card geometry: Roblox's measured card when known (square image, padding,
// title placement, gaps), else a square-image fallback of the same shape.
struct CardLayout {
    int width, height, gap_x, gap_y, image_x, image_y, image_w, image_h, title_x, title_y, title_w, title_h;
};
CardLayout card_layout(int width, int fallback_min) {
    const auto& metrics = state().card;
    if (metrics.valid)
        return {metrics.width, metrics.height, metrics.gap_x, metrics.gap_y, metrics.image_x, metrics.image_y,
            metrics.image_w, metrics.image_h, metrics.title_x, metrics.title_y, metrics.title_w,
            std::max(metrics.title_h, 16)};
    const int columns = std::max(1, (width + kGap) / (fallback_min + kGap));
    const int card_width = std::max(160, (width - (columns - 1) * kGap) / columns);
    const int image = card_width - 16;
    return {card_width, image + 52, kGap, kGap, 8, 8, image, image, 10, image + 16, card_width - 20, 20};
}

// Lays out cards for the view and returns their content height, or -1 when a
// node is missing so the caller rebuilds. All shows every owned entry; a
// custom category shows only its own. Both use the same card geometry.
int layout_cards(Handle scroll, int width, int min_card, View view) {
    auto& ui = state();
    const Children cards(scroll);
    const auto empty = cards["Empty"];
    if (!empty) return -1;
    const bool all = view == View::All;
    const auto layout = card_layout(width, min_card);
    const int columns = std::max(1, (width + layout.gap_x) / (layout.width + layout.gap_x));
    const int ribbon = std::clamp(layout.image_w / 3, 48, 72);
    // The date line is shown only where it fits under Roblox's title area.
    const int meta_h = (ui.title_style.valid() ? static_cast<int>(std::round(ui.title_style.size * 0.85f)) : 11) + 4;
    const int meta_y = layout.title_y + layout.title_h + 2;
    const bool meta_fits = false;  // Match Roblox's single title row.
    const auto& metrics = ui.card;
    int shown = 0;
    for (const auto& entry : ui.entries) {
        // Rediscover only live children; never dereference cached GUI handles.
        const auto card = cards["Template_" + entry.id];
        if (!card) return -1;
        const bool visible = all || entry.category == ui.selected;
        set_bool(card, "Visible", visible);
        if (!visible) continue;
        const Children parts(card);
        const auto thumb = parts["Thumb"], title = parts["Title"], meta = parts["Meta"];
        const Children overlay(thumb);
        const auto band = overlay["Ribbon"], edit = overlay["Edit"];
        if (!thumb || !title || !meta || !band || !edit) return -1;
        place(card, (shown % columns) * (layout.width + layout.gap_x), (shown / columns) * (layout.height + layout.gap_y),
            layout.width, layout.height);
        place(thumb, layout.image_x, layout.image_y, layout.image_w, layout.image_h);
        place(band, layout.image_w - ribbon, 0, ribbon, ribbon);
        place(edit, layout.image_w - 42, layout.image_h - 26, 36, 20);
        place(title, layout.title_x, layout.title_y, layout.title_w, layout.title_h);
        place(meta, layout.title_x, meta_y, layout.title_w, meta_h);
        set_bool(meta, "Visible", meta_fits);
        if (metrics.valid && metrics.fill_known) {
            set_struct(card, "BackgroundColor3", metrics.fill);
            set_float(card, "BackgroundTransparency", metrics.fill_transparency);
        }
        if (metrics.valid && metrics.image_known) {
            set_struct(thumb, "BackgroundColor3", metrics.image_fill);
            set_float(thumb, "BackgroundTransparency", metrics.image_transparency);
        }
        if (metrics.valid && metrics.title_known) set_struct(title, "TextColor3", metrics.title_color);
        std::string detail = entry.date.empty() ? "Opens a fresh copy" : "Updated " + entry.date;
        if (all) {
            const auto* owner = category(entry.category);
            if (owner && !owner->name.empty()) detail = owner->name + "  ·  " + detail;
        }
        set_string(meta, "Text", detail);
        ++shown;
    }
    set_bool(empty, "Visible", !all && shown == 0);
    int height = 0;
    if (shown > 0) {
        const int rows = (shown + columns - 1) / columns;
        height = rows * (layout.height + layout.gap_y) - layout.gap_y;
    } else if (!all) {
        const Children parts(empty);
        const auto* current = category(ui.selected);
        set_string(parts["Heading"], "Text",
            "No templates in " + (current && !current->name.empty() ? current->name : std::string("this category")) + " yet");
        height = 220;
    }
    set_struct(scroll, "CanvasSize", offset(0, all ? height : height + layout.gap_y));
    return height;
}

// Brings our card text to Roblox's rendered title height
// (date line and Edit chip slightly smaller). Rounds where nothing has
// rendered yet are not counted against the attempt budget.
void match_card_text(Handle scroll) {
    auto& ui = state();
    if (!ui.card_text_pending || ui.card.title_text <= 0) return;
    bool waiting = false, adjusted = false;
    const auto note = [&](Fit fit) { waiting |= fit == Fit::Waiting; adjusted |= fit == Fit::Adjusted; };
    for (const auto& entry : ui.entries) {
        const auto card = child(scroll, "Template_" + entry.id);
        if (!card || !get_bool(card, "Visible")) continue;
        const Children parts(card);
        note(match_text_height(parts["Title"], ui.card.title_text));
        note(match_text_height(child(parts["Thumb"], "Edit"), ui.card.title_text, 0.85f));
    }
    if (waiting) return;
    if (!adjusted || ++ui.card_text_attempts >= kTextMatchAttempts) ui.card_text_pending = false;
}

// Pick the font roles used by the bundled Foundation style definitions.
// Donors are rediscovered; no engine object handle is retained in this cache.
void resolve_typography(Handle pills, Handle scroll, Handle header) {
    auto& ui = state();
    for (const auto object : children(pills)) {
        if (button_class(get_string(object, "ClassName")) && child(object, "Text")) {
            ui.pill_style = {"BuilderSansMedium", 15, false};
            break;
        }
    }
    if (official_title(scroll)) ui.title_style = {"BuilderSansBold", 14, false};
    if (child(header, "Title")) ui.header_style = {"BuilderSansBold", 28, false};
}
void warn_apply(bool ok) {
    auto& ui = state();
    if (!ok && !ui.apply_warned) {
        log("Custom Templates could not apply Roblox's font to one of its controls.");
        ui.apply_warned = true;
    }
}
// Category pills, + and Add use Foundation's pill font role.
void style_controls(Handle strip, Handle plus, Handle add) {
    auto& ui = state();
    if (!ui.pill_style.valid() || ui.pill_style.key() == ui.pills_applied) return;
    bool ok = true;
    for (const auto object : children(strip))
        if (get_string(object, "Name").starts_with("Category_")) ok = apply_text(object, ui.pill_style) && ok;
    ok = apply_text(plus, ui.pill_style, 1.25f) && ok;
    ok = apply_text(add, ui.pill_style) && ok;
    warn_apply(ok);
    if (!ok) return;  // retried next tick
    ui.pills_applied = ui.pill_style.key();
    ui.pill_text_pending = true;
    ui.pill_text_attempts = 0;
    ui.layout_key.clear();  // pill widths follow the new text
}
// Section heading takes the page heading's font at section scale; the status
// line the card title's at a smaller size.
void style_chrome(Handle heading, Handle status) {
    auto& ui = state();
    if (!ui.title_style.valid()) return;
    const auto key = ui.title_style.key() + '|' + (ui.header_style.valid() ? ui.header_style.key() : "");
    if (key == ui.chrome_applied) return;
    bool ok = ui.header_style.valid() ? apply_text(heading, ui.header_style, 0.7f) : apply_text(heading, ui.title_style, 1.3f);
    ok = apply_text(status, ui.title_style, 0.85f) && ok;
    warn_apply(ok);
    if (ok) ui.chrome_applied = key;
}
// Every card text, the Edit chip, OWNED and the empty state.
void style_cards(Handle scroll, Handle donor) {
    auto& ui = state();
    if (!ui.title_style.valid()) {
        // Fallback: authored copy from a same-class official title, then height
        // matching in match_card_text.
        if (ui.cards_fallback_copied || !donor) return;
        for (const auto& entry : ui.entries) {
            const Children parts(child(scroll, "Template_" + entry.id));
            copy_text_style(parts["Title"], donor);
            copy_text_style(parts["Meta"], donor);
        }
        ui.cards_fallback_copied = true;
        return;
    }
    const auto& small = ui.pill_style.valid() ? ui.pill_style : ui.title_style;
    const auto key = ui.title_style.key() + '|' + small.key() + '|' + (ui.header_style.valid() ? ui.header_style.key() : "");
    if (key == ui.cards_applied) return;
    bool ok = true;
    for (const auto& entry : ui.entries) {
        const Children parts(child(scroll, "Template_" + entry.id));
        const Children thumb(parts["Thumb"]);
        const Children placeholder(thumb["Placeholder"]);
        ok = apply_text(parts["Title"], ui.title_style) && ok;
        ok = apply_text(parts["Meta"], ui.title_style, 0.85f) && ok;
        ok = apply_text(thumb["Edit"], small, 0.85f) && ok;
        ok = apply_text(child(child(thumb["Ribbon"], "Band"), "Label"), small, 0.7f) && ok;
        ok = apply_text(placeholder["Monogram"], ui.title_style, 1.8f) && ok;
        ok = apply_text(placeholder["Caption"], ui.title_style, 0.8f) && ok;
    }
    const Children empty(child(scroll, "Empty"));
    ok = (ui.header_style.valid() ? apply_text(empty["Heading"], ui.header_style, 0.7f)
                                   : apply_text(empty["Heading"], ui.title_style, 1.3f)) && ok;
    ok = apply_text(empty["Hint"], ui.title_style, 0.9f) && ok;
    ok = apply_text(empty["Add"], small) && ok;
    ok = apply_text(empty["Glyph"], small, 2) && ok;
    warn_apply(ok);
    if (!ok) return;
    ui.cards_applied = key;
    ui.card_text_pending = true;
    ui.card_text_attempts = 0;
    ui.cards_key.clear();
}

// Bounds of Roblox's All content in canvas coordinates, measured from fresh
// visible children. Any layout object, or scaled padding, means the official
// grid is not positioned the way this measurement assumes, so nothing is
// appended.
std::optional<Geometry> measure(Handle scroll, std::string& issue) {
    const auto origin = get_struct<Vec2>(scroll, "AbsolutePosition");
    const auto canvas = get_struct<Vec2>(scroll, "CanvasPosition");
    Dim pad_left{}, pad_top{};
    float left = 0, right = 0, bottom = 0, cell = 0;
    bool any = false;
    for (const auto object : children(scroll)) {
        if (owned(object)) continue;
        const auto cls = get_string(object, "ClassName");
        if (cls.starts_with("UI") && cls.ends_with("Layout")) { issue = "the official grid uses " + cls; return std::nullopt; }
        if (cls == "UIPadding") {
            pad_left = get_struct<Dim>(object, "PaddingLeft");
            pad_top = get_struct<Dim>(object, "PaddingTop");
            if (pad_left.scale != 0 || pad_top.scale != 0) { issue = "the official grid uses scaled padding"; return std::nullopt; }
            continue;
        }
        if (!gui_class(cls) || !get_bool(object, "Visible")) continue;
        const auto at = get_struct<Vec2>(object, "AbsolutePosition");
        const auto extent = get_struct<Vec2>(object, "AbsoluteSize");
        if (extent.x <= 0 || extent.y <= 0) continue;
        const float x = at.x - origin.x + canvas.x, y = at.y - origin.y + canvas.y;
        left = any ? std::min(left, x) : x;
        right = any ? std::max(right, x + extent.x) : x + extent.x;
        bottom = any ? std::max(bottom, y + extent.y) : y + extent.y;
        if (button_class(cls)) cell = cell > 0 ? std::min(cell, extent.x) : extent.x;
        any = true;
    }
    if (!any || right - left < 160) { issue = "no measurable official cards"; return std::nullopt; }
    // Measured positions already include the scroll's padding; our own
    // Position would receive it again.
    Geometry geometry;
    geometry.left = static_cast<int>(left) - pad_left.offset;
    geometry.right = static_cast<int>(right) - pad_left.offset;
    geometry.bottom = static_cast<int>(bottom) - pad_top.offset;
    geometry.cell = static_cast<int>(cell);
    return geometry;
}

// Grows the official CanvasSize only when its extent cannot already hold our
// section. A value we did not write is Roblox's: it becomes the extent that
// restore_canvas puts back.
void extend_canvas(Handle scroll, int needed) {
    auto& ui = state();
    const auto current = get_struct<Dim2>(scroll, "CanvasSize");
    if (ui.canvas_written && (ui.canvas_owner != scroll || current != ui.canvas_last)) ui.canvas_written = false;
    if (!ui.canvas_written) {
        ui.canvas_saved = current;
        ui.canvas_owner = scroll;
        if (get_struct<Vec2>(scroll, "AbsoluteCanvasSize").y >= static_cast<float>(needed)) return;
    }
    const Dim2 desired{ui.canvas_saved.x, {0, needed}};
    if (ui.canvas_written && desired == ui.canvas_last) return;
    set_struct(scroll, "CanvasSize", desired);
    ui.canvas_last = desired;
    ui.canvas_written = true;
}

struct OfficialPill {
    std::string name;
    Handle pill, label;
    Look look;
    bool readable;
    Vec2 at, extent;
};
// Fresh read of Roblox's pills: geometry plus the three look properties.
std::vector<OfficialPill> official_pills(Handle pills) {
    std::vector<OfficialPill> values;
    for (const auto object : children(pills)) {
        if (!button_class(get_string(object, "ClassName"))) continue;
        OfficialPill value{get_string(object, "Name"), object, child(object, "Text"), {}, false,
            get_struct<Vec2>(object, "AbsolutePosition"), get_struct<Vec2>(object, "AbsoluteSize")};
        const double transparency = get_number(object, "BackgroundTransparency", -1);
        if (value.label && transparency >= 0) {
            value.look = {get_struct<Color>(object, "BackgroundColor3"), get_struct<Color>(value.label, "TextColor3"),
                static_cast<float>(transparency)};
            value.readable = true;
        }
        values.push_back(std::move(value));
    }
    return values;
}
// The selected pill is the single pill whose look differs from all others,
// which share one look. Anything less clear-cut (a tween, a hover, a press)
// identifies nothing.
int selected_pill(const std::vector<OfficialPill>& pills) {
    if (pills.size() < 3 || !std::all_of(pills.begin(), pills.end(), [](auto& p) { return p.readable; })) return -1;
    for (std::size_t candidate = 0; candidate < pills.size(); ++candidate) {
        const auto& other = pills[candidate == 0 ? 1 : 0].look;
        bool unique = !(pills[candidate].look == other);
        for (std::size_t index = 0; unique && index < pills.size(); ++index)
            if (index != candidate && !(pills[index].look == other)) unique = false;
        if (unique) return static_cast<int>(candidate);
    }
    return -1;
}
// Writes only the properties that differ, so each one is owned separately:
// React may change just the fill or just the text during a tween or hover.
int write_look(Handle pill, Handle label, const Look& current, const Look& wanted) {
    int writes = 0;
    if (!same_color(current.fill, wanted.fill)) { set_struct(pill, "BackgroundColor3", wanted.fill); ++writes; }
    const float delta = current.transparency - wanted.transparency;
    if (delta > 0.005f || delta < -0.005f) { set_float(pill, "BackgroundTransparency", wanted.transparency); ++writes; }
    if (!same_color(current.text, wanted.text)) { set_struct(label, "TextColor3", wanted.text); ++writes; }
    return writes;
}
// Learns React's selected/unselected looks, only in a steady state: no custom
// category, exactly one outlier, every other pill identical. The outlier is
// also React's selection, which corrects tracking if a click was missed.
void learn_looks(const std::vector<OfficialPill>& pills) {
    auto& ui = state();
    const int index = selected_pill(pills);
    if (index < 0) return;
    const auto& on = pills[static_cast<std::size_t>(index)];
    ui.look_on = on.look;
    ui.look_off = pills[index == 0 ? 1 : 0].look;
    ui.looks_valid = true;
    // Correct tracking from React's steady selection, but never in the moment
    // after a click, before React has restyled the pills.
    if (Clock::now() - ui.official_clicked > std::chrono::milliseconds(1500)) ui.official = on.name;
}
const OfficialPill* find_pill(const std::vector<OfficialPill>& pills, const std::string& name) {
    for (const auto& value : pills)
        if (value.name == name) return &value;
    return nullptr;
}
// Ends ownership. Clicking the pill React already shows as selected changes
// nothing in React, so we put back its learned selected look, but only on the
// exact same live nodes. Clicking another pill lets React restyle both.
void end_highlight(Handle pills) {
    auto& ui = state();
    auto& highlight = ui.highlight;
    if (highlight.active && highlight.restore && pills && ui.looks_valid) {
        const auto current = official_pills(pills);
        if (const auto* pill = find_pill(current, highlight.pill); pill && pill->readable &&
            debug_id(pill->pill) == highlight.pill_id && debug_id(pill->label) == highlight.text_id)
            write_look(pill->pill, pill->label, pill->look, ui.look_on);
    }
    highlight = {};
}
// Two highlighted pills: while a custom category shows, React's selected
// official pill (the tracked one) is held in the learned unselected look.
// Each tick only differing properties are rewritten, so a fill-only or
// text-only React write, a tween frame, or hover/press styling is corrected
// rather than left half-selected. Other pills and all text are untouched.
// Work is bounded per tick (three properties on one pill).
void reconcile_highlight(Handle pills) {
    auto& ui = state();
    auto& highlight = ui.highlight;
    const auto current = official_pills(pills);
    if (ui.selected.empty()) {
        if (highlight.active) end_highlight(pills);
        learn_looks(current);
        return;
    }
    if (!ui.looks_valid) return;
    const auto* owner = find_pill(current, highlight.active ? highlight.pill : ui.official);
    if (!owner || !owner->readable) { highlight = {}; return; }
    const auto pill_id = debug_id(owner->pill), text_id = debug_id(owner->label);
    if (highlight.active && (pill_id != highlight.pill_id || text_id != highlight.text_id)) {
        // React replaced the node: its fresh state is its own; start over.
        highlight = {};
        owner = find_pill(current, ui.official);
        if (!owner || !owner->readable) return;
    }
    if (!highlight.active) {
        highlight.active = true;
        highlight.restore = true;
        highlight.pill = owner->name;
        highlight.pill_id = debug_id(owner->pill);
        highlight.text_id = debug_id(owner->label);
    }
    // At most three property writes per tick, only on the owned pill's exact
    // live nodes, only while a custom category is selected. No lifetime cap:
    // a cap would let a later hover or tween bring the double highlight back.
    highlight.repairs += write_look(owner->pill, owner->label, owner->look, ui.look_off);
}

// Our row starts one official gap after Roblox's last pill and runs to the
// page's right edge. These targets come only from Roblox's geometry, never
// from where Controls happened to put our container, so a parent layout
// cannot feed back into the width. The container's real position is used
// only to translate the targets into its local coordinates.
void layout_controls(const Mount& mount, Handle actions, Handle strip, Handle plus, Handle add) {
    auto& ui = state();
    const auto origin = get_struct<Vec2>(mount.controls, "AbsolutePosition");
    const auto pill_origin = get_struct<Vec2>(mount.pills, "AbsolutePosition");
    const auto pills = official_pills(mount.pills);
    std::vector<std::pair<float, float>> spans;
    float height = 0;
    for (const auto& value : pills) {
        spans.emplace_back(value.at.x, value.at.x + value.extent.x);
        height = std::max(height, value.extent.y);
    }
    std::sort(spans.begin(), spans.end());
    float right = pill_origin.x, gap = 0;
    for (std::size_t index = 0; index < spans.size(); ++index) {
        right = std::max(right, spans[index].second);
        if (index > 0) {
            const float between = spans[index].first - spans[index - 1].second;
            if (between > 0 && (gap <= 0 || between < gap)) gap = between;
        }
    }
    // Roblox's rendered pill line height drives our final size.
    for (const auto& value : pills) {
        const float rendered = value.label ? get_struct<Vec2>(value.label, "TextBounds").y : 0;
        if (rendered > 0) {
            if (std::fabs(rendered - ui.pill_text_height) > 0.5f) { ui.pill_text_height = rendered; ui.pill_text_pending = true; ui.pill_text_attempts = 0; }
            break;
        }
    }
    const int pill_gap = gap > 0 && gap <= 32 ? static_cast<int>(gap + 0.5f) : kPillGap;
    const float pill_text = ui.pill_style.valid() ? ui.pill_style.size : ui.pill_text_height;
    const int pill_height = height > 0 ? static_cast<int>(height + 0.5f) : 32;
    const int pill_y = static_cast<int>(pill_origin.y - origin.y);

    const auto page_at = get_struct<Vec2>(mount.page, "AbsolutePosition");
    const auto page_size = get_struct<Vec2>(mount.page, "AbsoluteSize");
    const int row_left = static_cast<int>(right + 0.5f) + pill_gap;
    const int row_width = std::max(0, static_cast<int>(page_at.x + page_size.x + 0.5f) - row_left);
    const int start = static_cast<int>(get_struct<Vec2>(actions, "AbsolutePosition").x + 0.5f);
    const int base = std::clamp(row_left - start, -row_width, row_width);
    const int add_width = row_width >= kAddWidth + pill_height + 2 * pill_gap + 96 ? kAddWidth : kCompactAddWidth;
    auto look_key = [](const Look& look) { return json_color(look.fill) + json_number(look.transparency) + json_color(look.text); };
    std::string key = std::to_string(start) + ':' + std::to_string(row_left) + ':' + std::to_string(row_width) + ':' +
        std::to_string(pill_y) + ':' + std::to_string(pill_height) + ':' + std::to_string(pill_gap) + ':' +
        json_number(pill_text) + ':' + look_key(ui.look_on) + look_key(ui.look_off) + ':' + ui.selected;
    if (key == ui.layout_key) return;

    place(actions, row_left - static_cast<int>(origin.x + 0.5f), pill_y, row_width, pill_height);
    const Children items(strip);
    int content = 0, selected_left = -1, selected_width = 0;
    bool measured = true, text_waiting = false, text_adjusted = false;
    const bool fallback_text = ui.pill_text_pending;
    for (std::size_t index = 0; index < ui.categories.size(); ++index) {
        const auto& value = ui.categories[index];
        const auto pill = items["Category_" + value.id];
        if (!pill) { ui.categories_dirty = true; return; }
        if (fallback_text) {
            const auto fit = match_text_height(pill, ui.pill_text_height);
            text_waiting |= fit == Fit::Waiting;
            text_adjusted |= fit == Fit::Adjusted;
        }
        // Pills size to their measured text. TextBounds is zero until first
        // render, so an estimate is used and the layout retried next tick.
        const float bounds = get_struct<Vec2>(pill, "TextBounds").x;
        measured = measured && bounds > 0;
        const int width = (bounds > 0 ? static_cast<int>(bounds + 0.5f) : static_cast<int>(value.name.size()) * 8) + 32;
        const bool on = value.id == ui.selected;
        const auto& look = on ? ui.look_on : ui.look_off;
        place(pill, content, 0, width, pill_height);
        set_struct(pill, "BackgroundColor3", look.fill);
        set_float(pill, "BackgroundTransparency", look.transparency);
        set_struct(pill, "TextColor3", look.text);
        if (on) { selected_left = content; selected_width = width; }
        content += width + pill_gap;
    }
    content = std::max(0, content - pill_gap);
    // The strip scrolls when categories outgrow the row; + and Add stay put.
    const int room = std::max(0, row_width - add_width - pill_height - 2 * pill_gap);
    const int visible = std::min(content, room);
    place(strip, base, 0, visible, pill_height);
    set_struct(strip, "CanvasSize", offset(content, 0));
    set_int(strip, "ScrollBarThickness", content > visible ? 2 : 0);
    set_struct(strip, "ScrollBarImageColor3", kFaint);
    if (selected_left >= 0 && content > visible) {
        const auto canvas = get_struct<Vec2>(strip, "CanvasPosition");
        if (selected_left < canvas.x || selected_left + selected_width > canvas.x + visible)
            set_struct(strip, "CanvasPosition", Vec2{static_cast<float>(std::clamp(selected_left + selected_width - visible, 0, content - visible)), 0});
    }
    const int plus_x = base + visible + (visible > 0 ? pill_gap : 0);
    place(plus, plus_x, 0, pill_height, pill_height);
    set_float(plus, "TextSize", 19);
    set_struct(plus, "BackgroundColor3", ui.look_off.fill);
    set_float(plus, "BackgroundTransparency", ui.look_off.transparency);
    const int add_x = std::max(plus_x + pill_height + pill_gap, base + row_width - add_width);
    set_string(add, "Text", add_width == kAddWidth ? "+  Add Template" : "+  Add");
    place(add, add_x, 0, add_width, pill_height);
    // Text sizing settles over a few ticks; widths follow the final size.
    // Fallback sizing settles over a few rendered rounds; unrendered rounds
    // do not count. Widths follow the final size.
    if (fallback_text && !text_waiting && (!text_adjusted || ++ui.pill_text_attempts >= kTextMatchAttempts))
        ui.pill_text_pending = false;
    const bool settling = fallback_text && ui.pill_text_pending;
    ui.layout_key = measured && !settling ? std::move(key) : std::string();
}

void tick(Handle game, const std::string& json) {
    auto& ui = state();
    if (ui.reset.exchange(false, std::memory_order_acq_rel)) {
        detach_all(); ui.mount = {}; ui.have_catalog = false;
        ui.select_revision = -1; ui.selected.clear(); ui.local_until = {};
        ui.official = "All"; ui.canvas_written = false; ui.canvas_owner = 0;
    }
    receive_catalog(json);
    const auto current = discover(game);
    if (!valid(current)) {
        if (ui.mount.content || !ui.bindings.empty()) detach_all();
        ui.mount = {};
        // The extended scroll left with the page; never write to a handle
        // that might later be reused.
        ui.canvas_written = false; ui.canvas_owner = 0;
        ui.highlight = {};
        return;
    }
    if (ui.mount.game != current.game || ui.mount.content != current.content ||
        ui.mount.header != current.header || ui.mount.controls != current.controls || ui.mount.page != current.page)
        mount_ui(current, ui.mount.content != current.content);
    reconcile_pills(current.pills);

    const auto actions = child(current.controls, named("Actions"));
    const Children inner(actions);
    const auto strip = inner["Categories"];
    const auto add = inner["Add"];
    const auto plus = inner["NewCategory"];
    // The panel lives in exactly one of two parents; look in both so moving it
    // never looks like a lost mount.
    const auto scroll = official_scroll(current.page);
    Handle panel = child(current.page, named("Panel"));
    bool embedded = false;
    if (!panel && scroll) { panel = child(scroll, named("Panel")); embedded = panel != 0; }
    const Children parts(panel);
    const auto cards = parts["Cards"], heading_label = parts["Heading"], status = parts["Status"];
    if (!actions || !strip || !plus || !add || !panel || !cards || !heading_label || !status) {
        restore_canvas(scroll);
        detach_all(); ui.mount = {};
        return;
    }
    process_actions();
    if (ui.categories_dirty) { build_pills(strip); ui.categories_dirty = false; }
    resolve_typography(current.pills, scroll, current.header);
    style_controls(strip, plus, add);
    reconcile_highlight(current.pills);
    layout_controls(current, actions, strip, plus, add);

    const bool custom = !ui.selected.empty();
    const auto* shown = category(ui.selected);

    // Roblox's card is measured whenever its grid is on screen, and cached so
    // a custom category keeps the same card while that grid is hidden.
    if (!custom && scroll && learn_cards(scroll)) {
        ui.cards_key.clear();
        ui.frame_key.clear();
        ui.card_text_pending = true;
        ui.card_text_attempts = 0;
    }

    View view = custom ? View::Custom : View::Hidden;
    Geometry geometry;
    if (!custom && ui.official == "All" && !ui.entries.empty() && scroll) {
        std::string issue;
        if (const auto measured = measure(scroll, issue)) {
            geometry = *measured;
            view = View::All;
        } else if (issue != ui.append_issue) {
            log("Custom Templates did not add its section to All: " + issue + ".");
            ui.append_issue = issue;
        }
    }
    if (view != View::All) restore_canvas(scroll);
    if (embedded != (view == View::All)) set_parent(panel, view == View::All ? scroll : current.page);
    if (view != ui.view) { ui.view = view; ui.frame_key.clear(); ui.cards_key.clear(); }
    set_bool(panel, "Visible", view != View::Hidden);
    for (const auto object : children(current.page))
        if (!owned(object) && get_string(object, "ClassName") == "ScrollingFrame")
            set_bool(object, "Visible", !custom);
    if (view == View::Hidden) return;

    const bool local = Clock::now() < ui.local_until;
    const auto& text = local ? ui.local_status : ui.status;
    const bool error = local ? ui.local_error : ui.status_error;
    std::string fallback = "Click a template to open a fresh copy. Right-click to edit.";
    if (view == View::All)
        fallback = std::to_string(ui.entries.size()) + (ui.entries.size() == 1 ? " template" : " templates") +
            "  ·  Click to open a fresh copy. Right-click to edit.";
    const std::string heading = view == View::All ? "Your templates"
        : shown && !shown->name.empty() ? shown->name : "Untitled";
    if (heading != ui.heading_text) { set_string(heading_label, "Text", heading); ui.heading_text = heading; }
    set_string(status, "Text", text.empty() ? fallback : text);
    set_struct(status, "TextColor3", error ? kError : kMuted);
    if (ui.cards_dirty) { build_cards(cards); ui.cards_dirty = false; ui.cards_key.clear(); }
    style_cards(cards, official_title(scroll));
    style_chrome(heading_label, status);
    if (!ui.typography_logged && ui.card.valid && ui.pill_style.valid() && ui.title_style.valid()) {
        log("Custom Templates matched Roblox's card " + std::to_string(ui.card.width) + "x" + std::to_string(ui.card.height) +
            " (image " + std::to_string(ui.card.image_w) + "x" + std::to_string(ui.card.image_h) + "), pill font role " +
            ui.pill_style.font + " " + std::to_string(std::lround(ui.pill_style.size)) + ", title font " +
            ui.title_style.font + " " + std::to_string(std::lround(ui.title_style.size)) + ".");
        ui.typography_logged = true;
    }

    const bool all = view == View::All;
    // A custom category uses Roblox's left inset on both sides of the grid.
    const int inset = ui.card.valid ? std::max(0, ui.card.left) : 0;
    const int width = std::max(180, all ? geometry.right - geometry.left
                                        : static_cast<int>(get_struct<Vec2>(current.page, "AbsoluteSize").x) -
                                          (ui.card.valid ? 2 * inset : 12));
    const int min_card = all && geometry.cell >= 160 ? geometry.cell : kMinCardWidth;
    const auto key = std::to_string(width) + ':' + std::to_string(min_card) + ':' + (all ? "all" : ui.selected) +
        ':' + ui.card.key();
    if (ui.visuals_dirty || key != ui.cards_key) {
        const int height = layout_cards(cards, width, min_card, view);
        if (height < 0) { ui.cards_dirty = true; return; }
        ui.content_height = height;
        // A different category shows different cards: re-run fallback matching.
        if (key != ui.cards_key) { ui.card_text_pending = true; ui.card_text_attempts = 0; }
        ui.cards_key = key;
        ui.visuals_dirty = false;
        ui.frame_key.clear();
    }

    match_card_text(cards);
    if (!all) {
        const auto frame = "custom:" + std::to_string(inset);
        if (ui.frame_key != frame) {
            position(panel, 0, 0); set_struct(panel, "Size", size(1, 0, 1, 0));
            position(heading_label, inset, 0); set_struct(heading_label, "Size", size(1, -2 * inset, 0, 28));
            position(status, inset, 28); set_struct(status, "Size", size(1, -2 * inset, 0, 20));
            position(cards, inset, kSectionHeader); set_struct(cards, "Size", size(1, -inset, 1, -kSectionHeader));
            set_bool(cards, "ScrollingEnabled", true);
            set_int(cards, "ScrollBarThickness", 6);
            ui.frame_key = frame;
        }
        return;
    }
    // Appended below the official cards; Roblox's scroll does the scrolling.
    const int top = geometry.bottom + kSectionGap;
    const int height = kSectionHeader + ui.content_height;
    const auto frame = std::to_string(geometry.left) + ':' + std::to_string(top) + ':' +
        std::to_string(width) + ':' + std::to_string(height);
    if (frame != ui.frame_key) {
        place(panel, geometry.left, top, width, height);
        place(heading_label, 0, 0, width, 28);
        place(status, 0, 28, width, 20);
        place(cards, 0, kSectionHeader, width, ui.content_height);
        set_bool(cards, "ScrollingEnabled", false);
        set_int(cards, "ScrollBarThickness", 0);
        ui.frame_key = frame;
    }
    extend_canvas(scroll, top + height + kSectionGap);
}
} // namespace

bool ctpl_ui_init() {
    auto& ui = state();
    std::call_once(ui.populate_once, [&ui] {
        using Populate = void (*)(rml::dotnet::InteropTable&);
        auto populate = reinterpret_cast<Populate>(dlsym(RTLD_DEFAULT,
            "_ZN3rml6dotnet21RobloxInteropProvider8populateERNS0_12InteropTableE"));
        if (!populate) return;
        ui.api.version = rml::dotnet::RML_INTEROP_VERSION;
        ui.api.size = sizeof(ui.api);
        populate(ui.api);
        ui.populated = ui.api.reflection_invoke && ui.api.reflection_get_property && ui.api.reflection_set_property &&
            ui.api.reflection_event_connect && ui.api.reflection_event_disconnect && ui.api.object_create_by_name &&
            ui.api.free_string && ui.api.free_native_ptr;
    });
    if (!ui.populated) return false;
    ui.generation.fetch_add(1, std::memory_order_acq_rel);
    ui.reset.store(true, std::memory_order_release);
    ui.active.store(true, std::memory_order_release);
    return true;
}

void ctpl_ui_tick(std::uintptr_t game, const std::string& catalog_json) {
    if (!game || !state().active.load(std::memory_order_acquire)) return;
    try {
        tick(game, catalog_json);
        state().error_logged = false;
    } catch (const std::exception& error) {
        if (!state().error_logged) log(std::string("Custom Templates native UI failed: ") + error.what(), true);
        state().error_logged = true;
    } catch (...) {
        if (!state().error_logged) log("Custom Templates native UI failed.", true);
        state().error_logged = true;
    }
}

void ctpl_ui_stop() {
    // Live unload is unsupported: this code and its callback contexts must stay
    // resident until process exit. The helper drains ticks; stop remains inert.
    state().active.store(false, std::memory_order_release);
    state().generation.fetch_add(1, std::memory_order_acq_rel);
}
