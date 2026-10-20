// Run the real StartPageUI against a bounded fake engine. Rendering differs
// from authored TextSize, as it does on the styled Studio Templates page.
// Dynamic GetStyled calls abort: RML cannot safely marshal that return type.
#include "../native/StartPageUI.mm"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <map>
#include <array>
#include <tuple>

std::vector<std::string> posted, logs;
constexpr Color rgb_c(int r, int g, int b) { return {r / 255.f, g / 255.f, b / 255.f}; }
void ctpl_post_command(const std::string& json) { posted.push_back(json); }
std::vector<std::tuple<std::uintptr_t, std::string, std::string>> enum_writes;
bool unrendered = false;
bool ctpl_ui_set_image(std::uintptr_t, const std::string&) { return true; }
struct Obj;
bool apply_enum(Obj* o, const std::string& p, const std::string& v);
bool ctpl_ui_set_style_enum(std::uintptr_t o, const std::string& p, const std::string& v) {
    enum_writes.emplace_back(o, p, v); return apply_enum(reinterpret_cast<Obj*>(o), p, v); }

struct Obj { std::string name, cls; Obj* parent = nullptr; std::vector<Obj*> kids;
    std::map<std::string, std::vector<std::byte>> blit; std::map<std::string, std::string> str; std::map<std::string, bool> flag; std::map<std::string, double> num; int writes = 0; };
std::uintptr_t H(Obj* o) { return reinterpret_cast<std::uintptr_t>(o); }
Obj* O(std::uintptr_t h) { return reinterpret_cast<Obj*>(h); }
int writes_canvas = 0;
void reparent(Obj* o, Obj* p) {
    if (o->parent) { auto& k = o->parent->kids; k.erase(std::remove(k.begin(), k.end(), o), k.end()); }
    o->parent = p; if (p) p->kids.push_back(o);
}
Obj* mk(const char* cls, const char* name, Obj* parent) { auto* o = new Obj{name, cls, nullptr, {}, {}, {}, {}, {}, 0}; reparent(o, parent); o->flag["Visible"] = true; return o; }
template<class T> void put(Obj* o, const char* k, T v) { o->blit[k].resize(sizeof(T)); std::memcpy(o->blit[k].data(), &v, sizeof(T)); }
template<class T> T take(Obj* o, const char* k) { T v{}; if (o->blit.count(k)) std::memcpy(&v, o->blit[k].data(), sizeof(T)); return v; }
std::size_t blit_size(const std::string& k) {
    if (k == "Position" || k == "Size" || k == "CanvasSize") return 16;
    if (k.find("Color") != std::string::npos) return 12;
    if (k == "CornerRadius" || k.starts_with("Padding")) return 8;
    return 8; // Vector2s
}
void get_prop(std::uintptr_t h, const char* k, Variant* out) {
    auto* o = O(h); std::string key = k; *out = {};
    if (key == "Name") { out->tag = Tag::String; out->as_string = strdup(o->name.c_str()); return; }
    if (key == "ClassName") { out->tag = Tag::String; out->as_string = strdup(o->cls.c_str()); return; }
    if (o->num.count(key)) { out->tag = Tag::Double; out->as_double = o->num[key]; return; }
    if (o->flag.count(key)) { out->tag = Tag::Bool; out->as_bool = o->flag[key]; return; }
    if (o->str.count(key)) { out->tag = Tag::String; out->as_string = strdup(o->str[key].c_str()); return; }
    if (key == "TextBounds" && !o->blit.count(key) && o->num.count("TextSize")) {
        // Rendering: a BuilderSans font renders at its size, anything else 1.5x.
        const float size = unrendered ? 0.f : static_cast<float>(o->num["TextSize"]);
        const float factor = o->str["Font"].starts_with("BuilderSans") ? 1.0f : 1.5f;
        Vec2 bounds{size * 0.5f * static_cast<float>(o->str["Text"].size()), size * factor};
        auto* p = malloc(sizeof(bounds)); std::memcpy(p, &bounds, sizeof(bounds));
        out->tag = Tag::Blittable; out->as_instance = reinterpret_cast<std::uintptr_t>(p); return;
    }
    if (o->blit.count(key)) { auto* p = malloc(o->blit[key].size()); std::memcpy(p, o->blit[key].data(), o->blit[key].size());
        out->tag = Tag::Blittable; out->as_instance = reinterpret_cast<std::uintptr_t>(p); }
}
void set_prop(std::uintptr_t h, const char* k, const Variant* v) {
    auto* o = O(h); std::string key = k;
    if (key != "Parent") ++o->writes;
    if (key == "Parent") { reparent(o, v->tag == Tag::Instance ? O(v->as_instance) : nullptr); return; }
    if (key == "Name") { o->name = v->as_string; return; }
    if (key == "CanvasSize" && o->name == "PageComponent") ++writes_canvas;
    if (v->tag == Tag::Float) o->num[key] = v->as_float;
    else if (v->tag == Tag::Int64) o->num[key] = static_cast<double>(v->as_int64);
    else if (v->tag == Tag::Bool) o->flag[key] = v->as_bool;
    else if (v->tag == Tag::String) o->str[key] = v->as_string;
    else if (v->tag == Tag::Blittable) { auto n = blit_size(key); o->blit[key].resize(n); std::memcpy(o->blit[key].data(), reinterpret_cast<void*>(v->as_instance), n); }
}
void invoke(std::uintptr_t h, const char* fn, const Variant*, std::uint32_t, Variant* out) {
    auto* o = O(h); std::string f = fn; *out = {};
    if (f == "GetChildren") {
        auto* buf = static_cast<std::byte*>(calloc(1, 8 + o->kids.size() * 8)); std::uint32_t n = o->kids.size();
        std::memcpy(buf, &n, 4); for (std::size_t i = 0; i < n; ++i) { std::uintptr_t c = H(o->kids[i]); std::memcpy(buf + 8 + i * 8, &c, 8); }
        out->tag = Tag::InstanceArray; out->as_instance = reinterpret_cast<std::uintptr_t>(buf);
    } else if (f == "GetStyled") {
        std::cerr << "GetStyled has an unsupported dynamic Variant return; do not invoke it through RML interop\n";
        std::abort();
    } else if (f == "GetDebugId") { out->tag = Tag::String; out->as_string = strdup(std::to_string(h).c_str()); }
    else { std::cerr << "unexpected reflected call: " << f << "\n"; std::abort(); } // Clone etc. are forbidden
}
std::uintptr_t connect(std::uintptr_t, const char*, rml::dotnet::ManagedEventCallback, void*) { static std::uintptr_t n = 1; return n++; }
void disconnect_event(std::uintptr_t) {}
std::uintptr_t create_obj(const char* cls, int) { return H(mk(cls, "", nullptr)); }
void free_str(const char* s) { free(const_cast<char*>(s)); }
void free_ptr(const void* p) { free(const_cast<void*>(p)); }
void log_fn(std::int32_t, const char* s, std::int32_t n) { logs.emplace_back(s, n); }


bool apply_enum(Obj* o, const std::string& p, const std::string& v) {
    if (p != "Font") return true;  // alignment/scale: recorded only
    if (o->cls != "TextLabel" && o->cls != "TextButton") return false;
    if (v != "BuilderSans" && v != "BuilderSansMedium" && v != "BuilderSansBold" && v != "BuilderSansExtraBold") return false;
    o->str["Font"] = v; return true;
}
int authored_copies = 0;
// Authored property copying supports only the same text class.
bool ctpl_ui_copy_text_style(std::uintptr_t target, std::uintptr_t source) {
    auto* t = O(target); auto* s = O(source);
    if (!t || !s || t->cls != s->cls) return false;
    t->str["FontFace"] = s->str["FontFace"]; t->num["TextSize"] = s->num["TextSize"]; ++authored_copies; return true;
}
std::string ctpl_ui_font_name(std::int64_t) { return {}; }
Obj* find(Obj* p, const char* name) { for (auto* k : p->kids) if (k->name == name) return k; return nullptr; }
Look look_of(Obj* p, Obj* t) { return Look{take<Color>(p, "BackgroundColor3"), take<Color>(t, "TextColor3"), static_cast<float>(p->num["BackgroundTransparency"])}; }
void authored_text(Obj* object, const std::string& text, Vec2 rendered) {
    object->str["FontFace"] = "authored-default";
    object->str["Text"] = text;
    object->num["TextSize"] = 8;
    put(object, "TextBounds", rendered);
}

int main() {
    auto& api = state().api;
    api.reflection_get_property = get_prop; api.reflection_set_property = set_prop; api.reflection_invoke = invoke;
    api.reflection_event_connect = connect; api.reflection_event_disconnect = disconnect_event;
    api.object_create_by_name = create_obj; api.free_string = free_str; api.free_native_ptr = free_ptr; api.managed_log = log_fn;
    state().populated = true;
    auto* game = mk("DataModel", "Game", nullptr);
    Obj* at = mk("Folder", "RobloxPluginGuiService", game); at = mk("PluginGui", "StartPage", at);
    for (const char* n : {"Wrapper", "Children", "Wrapper", "SafetyFAEUpsellContextScope", "Children", "Content"}) at = mk("Frame", n, at);
    auto* header = mk("Frame", "Header", at);
    auto* page_title = mk("TextLabel", "Title", header); authored_text(page_title, "Templates", Vec2{140, 28});
    auto* controls = mk("Frame", "Controls", at); put(controls, "AbsolutePosition", Vec2{280, 160});
    auto* pills = mk("Frame", "Pills", controls); put(pills, "AbsolutePosition", Vec2{280, 160});
    const Look on{rgb_c(255, 255, 255), rgb_c(32, 34, 39), 0}, off{rgb_c(208, 217, 251), rgb_c(247, 247, 248), 0.88f};
    std::vector<std::pair<Obj*, Obj*>> official;
    float px = 280;
    for (const char* n : {"All", "Generic", "Gameplay", "Theme"}) {
        auto* p = mk("ImageButton", n, pills); put(p, "AbsolutePosition", Vec2{px, 160}); put(p, "AbsoluteSize", Vec2{60, 32});
        auto* t = mk("TextLabel", "Text", p); authored_text(t, n, Vec2{30, 15});
        put(t, "TextBounds", Vec2{30, 15});  // rendered 15 while authored TextSize is 8
        official.emplace_back(p, t); px += 72;
    }
    auto react_select = [&](const std::string& name) {
        for (auto [p, t] : official) {
            const auto& look = p->name == name ? on : off;
            put(p, "BackgroundColor3", look.fill); p->num["BackgroundTransparency"] = look.transparency; put(t, "TextColor3", look.text);
        }
    };
    react_select("All");
    auto* outer = mk("Frame", "PageComponent", at); put(outer, "AbsoluteSize", Vec2{1200, 800});
    auto* scroll = mk("ScrollingFrame", "PageComponent", outer);
    put(scroll, "AbsolutePosition", Vec2{300, 200}); put(scroll, "CanvasPosition", Vec2{0, 0});
    put(scroll, "CanvasSize", Dim2{{0, 0}, {0, 600}}); put(scroll, "AbsoluteCanvasSize", Vec2{1000, 600});
    std::vector<Obj*> official_titles;
    for (auto [x, y] : {std::pair{320.f, 200.f}, {570.f, 200.f}, {820.f, 200.f}, {320.f, 472.f}}) {
        auto* b = mk("TextButton", "1", scroll); put(b, "AbsolutePosition", Vec2{x, y}); put(b, "AbsoluteSize", Vec2{230, 252});
        put(b, "BackgroundColor3", rgb_c(163, 162, 165)); b->num["BackgroundTransparency"] = 0;
        auto* c = mk("Frame", "Child", b); put(c, "BackgroundColor3", rgb_c(30, 31, 36)); c->num["BackgroundTransparency"] = 0;
        auto* img = mk("ImageLabel", "Image", c); put(img, "AbsolutePosition", Vec2{x + 7, y + 7}); put(img, "AbsoluteSize", Vec2{200, 200});
        put(img, "BackgroundColor3", rgb_c(163, 162, 165)); img->num["BackgroundTransparency"] = 0;
        auto* title = mk("TextLabel", "Title", mk("Frame", "Options", mk("Frame", "Body", c)));
        put(title, "AbsolutePosition", Vec2{x + 7, y + 214}); put(title, "AbsoluteSize", Vec2{216, 20});
        authored_text(title, "Official template", Vec2{90, 16});
        put(title, "TextColor3", rgb_c(27, 42, 53));
        official_titles.push_back(title);
    }
    const std::string catalog = R"({"revision":1,"selectRevision":0,"categories":[{"id":"p","name":"Personal"},{"id":"s","name":"Scene Tests"}],
        "templates":[{"id":"a","name":"Alpha","date":"Oct 18 2026","categoryId":"p","thumbnailUri":"","owned":true},
                     {"id":"b","name":"Beta","date":"Oct 18 2026","categoryId":"s","thumbnailUri":"","owned":true}]})";
    assert(ctpl_ui_init());
    auto tick = [&] { ctpl_ui_tick(H(game), catalog); assert(!state().error_logged); };
    auto click = [&](ActionType type, const char* id) { EventContext c; c.action = {type, id, state().generation.load()}; on_click(&c, nullptr, 0); };
    auto box = [](Obj* o) { auto p = take<Dim2>(o, "Position"), z = take<Dim2>(o, "Size");
        return std::array<int, 4>{p.x.offset, p.y.offset, z.x.offset, z.y.offset}; };


    // First render may be late. Zero bounds must not spend the correction
    // budget, and later rendering must still resolve the actual line heights.
    unrendered = true;
    for (int i = 0; i < 12; ++i) tick();
    assert(state().pill_text_pending && state().pill_text_attempts == 0);
    assert(state().card_text_pending && state().card_text_attempts == 0);
    unrendered = false;
    for (int i = 0; i < 6; ++i) tick();
    auto* actions = find(controls, "_RMLCustomTemplatesActions");
    auto* strip = find(actions, "Categories");
    auto* panel = find(scroll, "_RMLCustomTemplatesPanel");
    assert(panel && state().view == View::All && state().card.valid);
    auto* cards = find(panel, "Cards");
    auto* personal = find(strip, "Category_p");
    auto* alpha = find(cards, "Template_a");
    auto* beta = find(cards, "Template_b");
    auto* alpha_title = find(alpha, "Title");
    auto* beta_title = find(beta, "Title");
    auto* thumb = find(alpha, "Thumb");

    // The same checked Font adapter handles TextButtons and TextLabels.
    // Authored official size 8 must not replace rendered pill/title sizes.
    assert(personal->cls == "TextButton" && personal->str["Font"] == "BuilderSansMedium");
    assert(alpha_title->cls == "TextLabel" && alpha_title->str["Font"] == "BuilderSansBold");
    assert(personal->num["TextSize"] == 15 && alpha_title->num["TextSize"] == 16);
    assert(official[0].second->num["TextSize"] == 8 && official_titles[0]->num["TextSize"] == 8);
    for (auto* text : {find(actions, "Add"), find(actions, "NewCategory"), find(thumb, "Edit"),
                       find(find(find(thumb, "Ribbon"), "Band"), "Label"), find(panel, "Heading"), find(panel, "Status")})
        assert(text->str["Font"].starts_with("BuilderSans"));
    bool button_font = false, label_font = false;
    for (const auto& [handle, property, value] : enum_writes) {
        if (property != "Font") continue;
        assert(value == "BuilderSans" || value == "BuilderSansMedium" || value == "BuilderSansBold" || value == "BuilderSansExtraBold");
        button_font |= O(handle)->cls == "TextButton";
        label_font |= O(handle)->cls == "TextLabel";
    }
    assert(button_font && label_font && authored_copies == 0);
    assert(!state().pill_text_pending && !state().card_text_pending);

    // All and custom views share the official square preview, card extent,
    // title placement, and measured horizontal gap, including the inset.
    const std::array<int, 4> official_card_box{0, 0, 230, 252};
    assert(box(alpha) == official_card_box);
    assert((box(beta) == std::array<int, 4>{250, 0, 230, 252}));
    assert((box(thumb) == std::array<int, 4>{7, 7, 200, 200}));
    assert((box(alpha_title) == std::array<int, 4>{7, 214, 216, 20}));
    assert(!find(alpha, "Meta")->flag["Visible"]);
    assert(same_color(take<Color>(alpha, "BackgroundColor3"), rgb_c(30, 31, 36)));
    assert(take<Dim2>(scroll, "CanvasSize").y.offset > 600 && writes_canvas > 0);

    // A card hidden during one category's matching must be checked when it
    // appears in another category. Do not rely on one global completed flag.
    click(ActionType::Category, "p");
    for (int i = 0; i < 3; ++i) tick();
    assert(alpha->flag["Visible"] && !beta->flag["Visible"]);
    assert(take<Dim2>(scroll, "CanvasSize").y.offset == 600);
    beta_title->num["TextSize"] = 8;
    for (int i = 0; i < 3; ++i) tick();
    assert(beta_title->num["TextSize"] == 8);
    click(ActionType::Category, "s");
    for (int i = 0; i < 3; ++i) tick();
    assert(state().view == View::Custom && !scroll->flag["Visible"]);
    assert(beta->flag["Visible"] && !alpha->flag["Visible"] && beta_title->num["TextSize"] == 16);
    assert(box(beta) == official_card_box && take<Dim2>(cards, "Position").x.offset == 20);
    assert((box(find(beta, "Thumb")) == std::array<int, 4>{7, 7, 200, 200}));

    // React can write only a fill, only text, or an intermediate tween. Keep
    // one official pill unselected without changing its siblings or text.
    auto [all, all_text] = official[0];
    assert(look_of(all, all_text) == off);
    for (int i = 0; i < 750; ++i) {
        if (i % 3 == 0) put(all, "BackgroundColor3", on.fill);
        else if (i % 3 == 1) put(all_text, "TextColor3", on.text);
        else {
            put(all, "BackgroundColor3", rgb_c(80, 90, 100));
            all->num["BackgroundTransparency"] = 0.44;
            put(all_text, "TextColor3", rgb_c(110, 120, 130));
        }
        const int before = all->writes + all_text->writes;
        tick();
        const int delta = all->writes + all_text->writes - before;
        assert(delta > 0 && delta <= 3);
        assert(look_of(all, all_text) == off && state().highlight.pill == "All");
    }
    assert(state().highlight.repairs > 700);
    for (std::size_t i = 1; i < official.size(); ++i) assert(official[i].first->writes == 0 && official[i].second->writes == 0);
    for (auto* title : official_titles) assert(title->writes == 0 && title->str["Text"] == "Official template");
    assert(page_title->writes == 0 && page_title->str["Text"] == "Templates");
    for (auto [pill, text] : official) assert(text->str["Text"] == pill->name);

    // A different official pill lets React take ownership; the unchanged
    // selected pill must instead get its original selected appearance back.
    const int all_before = all->writes + all_text->writes;
    click(ActionType::Official, "Theme"); tick();
    assert(all->writes + all_text->writes == all_before && !state().highlight.active && state().official == "Theme");
    react_select("Theme"); tick();
    click(ActionType::Category, "p"); tick();
    auto [theme, theme_text] = official[3];
    assert(look_of(theme, theme_text) == off && state().highlight.pill == "Theme");
    click(ActionType::Official, "Theme"); tick();
    assert(look_of(theme, theme_text) == on && !state().highlight.active);
    int selected_count = 0;
    for (auto [pill, text] : official) selected_count += look_of(pill, text) == on;
    assert(selected_count == 1);
    std::cout << "7 native UI parity checks passed (font roles, rendered sizes, render waits, category retry, geometry, partial highlights, release)\n";
}
