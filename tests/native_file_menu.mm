// Runs the real TemplateFileMenu.mm against Studio's own Qt 5.15 frameworks
// on the offscreen platform (nothing is shown). Test-only objects (the app,
// menu bars, a main window, a decoy menu) are constructed here with generous
// buffers; the production file constructs nothing itself.
#include "../native/TemplateFileMenu.mm"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <dlfcn.h>
#include <stdexcept>
#include <unordered_map>
#import <CoreFoundation/CoreFoundation.h>

// The runner generates this table from the actual Studio Qt framework
// exports. Only export lookup is replaced; the production File menu module,
// SDK wrappers, and SDK connect_function implementation are compiled directly.
namespace {
const std::unordered_map<std::string, std::string>& test_symbols() {
    static const std::unordered_map<std::string, std::string> table{
#include "qt_symbols.inc"
    };
    return table;
}
void* test_export(const char* signature) {
    const auto it = test_symbols().find(signature);
    return it == test_symbols().end() ? nullptr : dlsym(RTLD_DEFAULT, it->second.c_str());
}
void* test_export(std::initializer_list<const char*> signatures) {
    for (const auto* signature : signatures)
        if (void* result = test_export(signature)) return result;
    return nullptr;
}
}
namespace rml::qt::detail {
void* core_export(const char* s) { return test_export(s); }
void* widgets_export(const char* s) { return test_export(s); }
void* gui_export(const char* s) { return test_export(s); }
void* core_export_optional(const char* s) { return test_export(s); }
void* widgets_export_optional(const char* s) { return test_export(s); }
void* gui_export_optional(const char* s) { return test_export(s); }
void* core_export(std::initializer_list<const char*> s) { return test_export(s); }
void* widgets_export(std::initializer_list<const char*> s) { return test_export(s); }
void* gui_export(std::initializer_list<const char*> s) { return test_export(s); }
}

std::vector<std::string> posted;
void ctpl_post_command(const std::string& json) { posted.push_back(json); }
std::string g_token;  // what CurrentPlaceSnapshot would report at click time
std::string ctpl_snapshot_document_token() { return g_token; }
bool ctpl_snapshot_document_matches(const std::string& token, std::uintptr_t*) { return !token.empty() && token == g_token; }

template<class F> F sym(const char* signature) {
    void* const result = detail::widgets_export_optional(signature);
    if (!result) throw std::runtime_error(std::string("Missing Studio Qt export: ") + signature);
    return reinterpret_cast<F>(result);
}
void pump() { for (int i = 0; i < 5; ++i) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false); }
std::vector<std::string> labels(void* menu) {
    std::vector<std::string> out;
    for (void* a : list_of(api().actions, menu)) {
        if (string_of(api().object_name, a) == kRetiredName) continue;
        out.push_back(api().is_separator(a) ? "---" : string_of(api().text, a));
    }
    return out;
}
int ours_in(void* menu) {
    int n = 0;
    for (void* a : list_of(api().actions, menu)) {
        const auto name = string_of(api().object_name, a);
        n += name == kSaveName || name == kSaveAsName;
    }
    return n;
}
void fill_file(void* file) {
    auto* menu = static_cast<qt::QMenu*>(file);
    for (const char* label : {"New", "Open…", "&Save", "Save &As…"}) (void)menu->addAction(qt::QString(label));
    menu->addSeparator();
    (void)menu->addAction(qt::QString("Close"));
}
// Parses one queued command and returns {type, documentId}.
std::pair<std::string, std::string> fields(const std::string& json) {
    @autoreleasepool {
        NSDictionary* value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json.data() length:json.size()] options:0 error:nil];
        assert([value isKindOfClass:NSDictionary.class] && value.count == 2);
        return {[value[@"type"] UTF8String], [value[@"documentId"] UTF8String]};
    }
}

int main() {
    const char* const studio = getenv("ROBLOX_STUDIO_APP");
    if (!studio) throw std::runtime_error("Run this harness with scripts/test-file-menu.");
    const std::string version = sym<const char* (*)()>("qVersion")();
    if (!version.starts_with("5.15.")) throw std::runtime_error("Unsupported Studio Qt version: " + version);
    const std::string plugins = std::string(studio) + "/Contents/Plugins/Qt5";
    setenv("QT_QPA_PLATFORM", "offscreen", 1);
    setenv("QT_PLUGIN_PATH", plugins.c_str(), 1);
    static int argc = 1; static char name[] = "harness"; static char* argv[] = {name, nullptr};
    alignas(16) static unsigned char app[1024];
    sym<void (*)(void*, int&, char**, int)>("QApplication::QApplication(int&, char**, int)")(app, argc, argv, 0x050F09);
    assert(api().ready);
    auto new_bar = sym<void (*)(void*, void*)>("QMenuBar::QMenuBar(QWidget*)");
    auto add_menu = sym<void* (*)(void*, const void*)>("QMenuBar::addMenu(QString const&)");
    auto is_enabled = sym<bool (*)(const void*)>("QAction::isEnabled() const");
    auto is_visible = sym<bool (*)(const void*)>("QAction::isVisible() const");
    auto activate = reinterpret_cast<void (*)(void*, int)>(qt::QAction::activate_address());

    alignas(16) static unsigned char bar_storage[1024], decoy_storage[1024];
    new_bar(bar_storage, nullptr);
    void* bar = bar_storage;
    void* file = add_menu(bar, qt::QString("&File").data());
    (void)add_menu(bar, qt::QString("Edit").data());
    fill_file(file);
    sym<void (*)(void*, const void*, void*)>("QMenu::QMenu(QString const&, QWidget*)")(decoy_storage, qt::QString("File").data(), nullptr);
    void* decoy = decoy_storage;
    (void)static_cast<qt::QMenu*>(decoy)->addAction(qt::QString("Save"));

    // 1. Attach next to the save group, in the menu bar's File only.
    ctpl_filemenu_start(); pump();
    const std::vector<std::string> expected{"New", "Open…", "&Save", "Save &As…", "Save to Template", "Save to Template As…", "---", "Close"};
    assert(labels(file) == expected && ours_in(decoy) == 0 && attached().menu == file);
    void* save = attached().save; void* save_as = attached().save_as;
    assert(!is_enabled(save) && !is_enabled(save_as) && is_visible(save));

    // 2. Click-time identity: no token -> nothing queued, even when enabled.
    ctpl_filemenu_set_state(true, "Obby Course"); pump();
    assert(is_enabled(save) && is_enabled(save_as));
    auto tooltip = sym<void*>("QAction::toolTip() const");
    assert(string_of(tooltip, save) == "Save this place to the template “Obby Course”");
    assert(string_of(tooltip, save_as) == "Save this place as a new template");
    g_token.clear();
    activate(save, 0); activate(save_as, 0); pump();
    assert(posted.empty());
    // A token with JSON-special characters is encoded, not interpolated.
    g_token = "doc:42 \"Obby\" \\ path/é";
    activate(save, 0); activate(save_as, 0); pump();
    assert(posted.size() == 2);
    assert(fields(posted[0]) == std::make_pair(std::string("save_current_template"), g_token));
    assert(fields(posted[1]) == std::make_pair(std::string("save_current_template_as"), g_token));
    // The user switched windows: the next click binds the new document; a
    // stale earlier token is never reused, and losing the document stops it.
    posted.clear();
    g_token = "doc:43";
    activate(save, 0); pump();
    assert(posted.size() == 1 && fields(posted[0]).second == "doc:43");
    g_token.clear(); activate(save, 0); pump();
    assert(posted.size() == 1);
    posted.clear();
    // Disabled state queues nothing even with a token.
    g_token = "doc:43"; ctpl_filemenu_set_state(false, ""); pump();
    assert(!is_enabled(save) && !is_enabled(save_as));
    assert(string_of(tooltip, save) == "Save this place to its template");
    activate(save, 0); activate(save_as, 0); pump(); assert(posted.empty());
    ctpl_filemenu_set_state(true, "Obby Course"); pump();

    // 3. Repeated start/attach never adds a second pair.
    ctpl_filemenu_start(); pump(); attach(); attach();
    assert(ours_in(file) == 2 && labels(file) == expected);

    // 4. removeAction without destruction: same objects, put back once.
    auto remove = sym<void (*)(void*, void*)>("QWidget::removeAction(QAction*)");
    auto insert = sym<void (*)(void*, void*, void*)>("QWidget::insertAction(QAction*, QAction*)");
    remove(file, save); remove(file, save_as);
    assert(ours_in(file) == 0 && attached().save == save && attached().save_as == save_as);
    attach();
    assert(labels(file) == expected && attached().save == save && attached().save_as == save_as);
    // Reordered (As before New, Save at the end): repaired, built-ins untouched.
    remove(file, save_as); insert(file, list_of(api().actions, file).front(), save_as);
    remove(file, save); insert(file, nullptr, save);
    attach();
    assert(labels(file) == expected && ours_in(file) == 2);

    // 5. Studio refills its File menu: ours are destroyed (pointers cleared by
    //    destroyed()), then come back exactly once in the right place.
    sym<void (*)(void*)>("QMenu::clear()")(file);
    assert(attached().save == nullptr && attached().save_as == nullptr && attached().menu == file);
    fill_file(file);
    // Exercise the actual aboutToShow connection, not only periodic attach.
    reinterpret_cast<void (*)(void*)>(api().about_to_show)(file);
    assert(labels(file) == expected && ours_in(file) == 2 && is_enabled(attached().save));

    // 6. Lifecycle tracking cannot be connected: nothing is retained; the new
    //    actions are retired (hidden, disabled, never reused). Once tracking
    //    works again a proper pair appears, still exactly one.
    sym<void (*)(void*)>("QMenu::clear()")(file);
    fill_file(file);
    void* const destroyed_signal = api().destroyed;
    api().destroyed = nullptr;
    attach();
    assert(attached().save == nullptr && attached().save_as == nullptr && ours_in(file) == 0);
    for (void* a : list_of(api().actions, file))
        if (string_of(api().object_name, a) == kRetiredName) assert(!is_visible(a) && !is_enabled(a));
    api().destroyed = destroyed_signal;
    attach();
    assert(labels(file) == expected && ours_in(file) == 2);
    posted.clear(); activate(attached().save, 0); pump();
    assert(posted.size() == 1);

    // 7. Stop hides and disables only ours; built-ins untouched.
    ctpl_filemenu_stop(); pump();
    assert(!is_visible(attached().save) && !is_enabled(attached().save_as));
    posted.clear(); activate(attached().save, 0); pump(); assert(posted.empty());
    ctpl_filemenu_start(); pump();
    assert(is_visible(attached().save) && is_enabled(attached().save));

    // 8. The menu bar goes away: no stale pointers; a new one gets the pair.
    sym<void (*)(void*)>("QMenuBar::~QMenuBar()")(bar);
    assert(attached().menu == nullptr && attached().save == nullptr && attached().save_as == nullptr);
    attach();
    assert(attached().menu == nullptr && ours_in(decoy) == 0);
    alignas(16) static unsigned char bar2_storage[1024], bar3_storage[1024], bar4_storage[1024], main_storage[1024];
    new_bar(bar2_storage, nullptr);
    void* file2 = add_menu(bar2_storage, qt::QString("File").data());
    fill_file(file2);
    attach();
    assert(attached().menu == file2 && labels(file2) == expected);

    // 9. Two plain menu bars, no active window, no main window: ambiguous.
    //    Nothing attaches to the new one; the existing pair stays put.
    new_bar(bar3_storage, nullptr);
    void* file3 = add_menu(bar3_storage, qt::QString("File").data());
    fill_file(file3);
    attach();
    assert(attached().menu == file2 && ours_in(file2) == 2 && ours_in(file3) == 0);
    // A QMainWindow's menu bar is the unambiguous choice: the pair moves there
    // (no copy left behind) and is owned by the new menu.
    sym<void (*)(void*, void*, int)>("QMainWindow::QMainWindow(QWidget*, QFlags<Qt::WindowType>)")(main_storage, nullptr, 0);
    new_bar(bar4_storage, nullptr);
    void* file4 = add_menu(bar4_storage, qt::QString("File").data());
    fill_file(file4);
    sym<void (*)(void*, void*)>("QMainWindow::setMenuBar(QMenuBar*)")(main_storage, bar4_storage);
    void* const moved = attached().save;
    attach();
    assert(attached().menu == file4 && attached().save == moved && labels(file4) == expected);
    assert(ours_in(file2) == 0 && ours_in(file3) == 0);
    // The old menu bar's destruction no longer affects the moved pair.
    sym<void (*)(void*)>("QMenuBar::~QMenuBar()")(bar2_storage);
    assert(attached().save == moved && attached().save_as && attached().menu == file4);

    // 10. Status text never creates a bar; it updates an existing one.
    const auto status_count = [] {
        int count = 0;
        for (auto* widget : qt::QApplication::all_widgets()) count += widget->inherits("QStatusBar");
        return count;
    };
    assert(status_count() == 0);
    ctpl_filemenu_status("No status bar yet"); pump();
    assert(status_count() == 0);
    void* status_bar = sym<void* (*)(const void*)>("QMainWindow::statusBar() const")(main_storage);  // test creates it
    ctpl_filemenu_status("Saved template Obby Course"); pump();
    assert(string_of(detail::widgets_export_optional("QStatusBar::currentMessage() const"), status_bar) == "Saved template Obby Course");
    std::cout << "10 File menu groups passed on Studio Qt " << version << " (offscreen)" << std::endl;
    // The module has process-exit-only timers. Menu destruction/migration is
    // exercised above; final QApplication teardown and leak checks are outside
    // this harness. No Studio process is opened or changed.
    std::_Exit(0);
}
