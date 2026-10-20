#include "TemplateFileMenu.hpp"
#include "CurrentPlaceSnapshot.hpp"
#include "NativeGuiDispatch.hpp"
#include "StartPageUI.hpp"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>
#include <RobloxModLoader/memory/foreign_call.hpp>
#include <RobloxModLoader/qt/qaction.hpp>
#include <RobloxModLoader/qt/qapplication.hpp>
#include <RobloxModLoader/qt/qlist.hpp>
#include <RobloxModLoader/qt/qmenu.hpp>
#include <RobloxModLoader/qt/qstring.hpp>
#include <RobloxModLoader/qt/qt_module.hpp>
#include <RobloxModLoader/qt/qwidget.hpp>

#import <Foundation/Foundation.h>

// Exported by roblox_modloader.dylib (src/qt/qt_connect.hpp is not public).
namespace rml::qt::detail {
bool connect_function(const void* sender, void* signal_addr, const void* sender_meta, std::function<void(void**)> slot);
}

namespace {
namespace qt = rml::qt;
namespace detail = rml::qt::detail;

constexpr const char* kSaveName = "ctplSaveTemplate";
constexpr const char* kSaveAsName = "ctplSaveTemplateAs";
// An action whose lifecycle tracking could not be connected: hidden, disabled,
// renamed so it is never reused, and never referenced again.
constexpr const char* kRetiredName = "ctplSaveTemplateRetired";
constexpr const char* kSaveLabel = "Save to Template";
constexpr const char* kSaveAsLabel = "Save to Template As…";
constexpr std::int64_t kCheckSeconds = 2;
constexpr int kStatusMilliseconds = 5000;

// Exact Qt 5.15 exports used here beyond the RML SDK wrappers. Members that
// return QString or QList by value are called with the SDK's indirect-return
// convention; nothing is allocated by guessed size.
struct Api {
    void* title = nullptr;               // QString QMenu::title() const
    void* actions = nullptr;             // QList<QAction*> QWidget::actions() const
    void* text = nullptr;                // QString QAction::text() const
    void* object_name = nullptr;         // QString QObject::objectName() const
    void* associated = nullptr;          // QList<QWidget*> QAction::associatedWidgets() const
    void (*set_object_name)(void*, const void*) = nullptr;
    void (*set_parent)(void*, void*) = nullptr;
    void* (*menu_action)(const void*) = nullptr;
    void* (*window)(const void*) = nullptr;
    void* (*active_window)() = nullptr;
    void (*insert_action)(void*, void*, void*) = nullptr;
    void (*remove_action)(void*, void*) = nullptr;
    bool (*is_separator)(const void*) = nullptr;
    void (*set_enabled)(void*, bool) = nullptr;
    void (*set_visible)(void*, bool) = nullptr;
    void (*set_tooltip)(void*, const void*) = nullptr;
    void (*list_dispose)(void*) = nullptr;  // static QListData::dispose(QListData::Data*)
    void (*show_message)(void*, const void*, int) = nullptr;  // optional (status text)
    void* triggered = nullptr;
    const void* action_meta = nullptr;
    void* destroyed = nullptr;
    const void* object_meta = nullptr;
    void* about_to_show = nullptr;
    const void* menu_meta = nullptr;
    bool ready = false;
};
template<class T> void widgets(T& slot, const char* signature) {
    slot = reinterpret_cast<T>(detail::widgets_export_optional(signature));
}
template<class T> void core(T& slot, const char* signature) {
    slot = reinterpret_cast<T>(detail::core_export_optional(signature));
}
Api& api() {
    static Api* const value = new Api();
    static std::once_flag once;
    std::call_once(once, [] {
        auto& a = *value;
        widgets(a.title, "QMenu::title() const");
        widgets(a.actions, "QWidget::actions() const");
        widgets(a.text, "QAction::text() const");
        core(a.object_name, "QObject::objectName() const");
        widgets(a.associated, "QAction::associatedWidgets() const");
        core(a.set_object_name, "QObject::setObjectName(QString const&)");
        core(a.set_parent, "QObject::setParent(QObject*)");
        widgets(a.menu_action, "QMenu::menuAction() const");
        widgets(a.window, "QWidget::window() const");
        widgets(a.active_window, "QApplication::activeWindow()");
        widgets(a.insert_action, "QWidget::insertAction(QAction*, QAction*)");
        widgets(a.remove_action, "QWidget::removeAction(QAction*)");
        widgets(a.is_separator, "QAction::isSeparator() const");
        widgets(a.set_enabled, "QAction::setEnabled(bool)");
        widgets(a.set_visible, "QAction::setVisible(bool)");
        widgets(a.set_tooltip, "QAction::setToolTip(QString const&)");
        core(a.list_dispose, "QListData::dispose(QListData::Data*)");
        widgets(a.show_message, "QStatusBar::showMessage(QString const&, int)");
        widgets(a.triggered, "QAction::triggered(bool)");
        widgets(a.action_meta, "QAction::staticMetaObject");
        core(a.destroyed, "QObject::destroyed(QObject*)");
        core(a.object_meta, "QObject::staticMetaObject");
        widgets(a.about_to_show, "QMenu::aboutToShow()");
        widgets(a.menu_meta, "QMenu::staticMetaObject");
        // The SDK's QMenu::addAction wrapper resolves its own export.
        a.ready = a.title && a.actions && a.text && a.object_name && a.associated && a.set_object_name &&
            a.set_parent && a.menu_action && a.window && a.active_window && a.insert_action && a.remove_action &&
            a.is_separator && a.set_enabled && a.set_visible && a.set_tooltip && a.list_dispose && a.triggered &&
            a.action_meta && a.destroyed && a.object_meta && a.about_to_show && a.menu_meta &&
            detail::widgets_export_optional("QMenu::addAction(QString const&)");
    });
    return *value;
}

// Desired state, written from any thread; read on the GUI thread.
std::atomic<bool> g_started{false};
std::atomic<bool> g_checking{false};
std::mutex g_mutex;
bool g_can_save = false;
std::string g_linked;

// GUI-thread only. A pointer is stored only after its destroyed() connection
// succeeded, and that connection clears it, so none outlives its object.
struct Attached {
    void* menu = nullptr;     // the File menu our pair lives in
    void* save = nullptr;
    void* save_as = nullptr;
};
Attached& attached() {
    static Attached* const value = new Attached();
    return *value;
}

std::string string_of(void* fn, const void* self) {
    qt::QString value;
    rml::memory::call_returning_member<void*>(fn, *static_cast<void**>(value.storage()), self);
    return value.to_utf8();
}
// Copies a returned QList<T*> and releases it as Qt's QListData deref does.
std::vector<void*> list_of(void* fn, const void* self) {
    qt::QList<void*> list;
    rml::memory::call_returning_member<void*>(fn, *list.raw_storage(), self);
    std::vector<void*> values;
    values.reserve(static_cast<std::size_t>(list.size()));
    for (void* value : list) values.push_back(value);
    auto* data = *reinterpret_cast<detail::QListData**>(list.raw_storage());
    if (data) {
        std::atomic_ref<int> ref(data->ref);
        const int count = ref.load();
        // -1: the static shared_null (never freed); 0: unsharable, owned here.
        if (count == 0 || (count != -1 && ref.fetch_sub(1) == 1)) api().list_dispose(data);
    }
    return values;
}
std::string plain(std::string text) {
    std::erase(text, '&');  // mnemonic markers
    return text;
}
void set_name(void* object, const char* name) {
    const qt::QString value(name);
    api().set_object_name(object, value.data());
}

// Click time: the document this choice is for is bound now, because the
// managed poll runs later and the user may switch windows in between. No
// token, no queue. The token is JSON-encoded, never interpolated.
void on_triggered(bool save_as) {
    bool allowed = false;
    {
        std::lock_guard lock(g_mutex);
        allowed = g_can_save;
    }
    if (!g_started.load(std::memory_order_acquire) || !allowed) return;
    const std::string token = ctpl_snapshot_document_token();
    if (token.empty()) return;
    std::string command;
    @autoreleasepool {
        NSString* const document = [[NSString alloc] initWithBytes:token.data() length:token.size()
                                                          encoding:NSUTF8StringEncoding];
        if (!document) return;
        NSDictionary* const value = @{
            @"type": save_as ? @"save_current_template_as" : @"save_current_template",
            @"documentId": document,
        };
        NSData* const data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        if (data) command.assign(static_cast<const char*>(data.bytes), data.length);
    }
    if (!command.empty()) ctpl_post_command(command);
}

void apply_state() {
    auto& a = attached();
    bool can_save = false;
    std::string linked;
    {
        std::lock_guard lock(g_mutex);
        can_save = g_can_save;
        linked = g_linked;
    }
    const bool started = g_started.load(std::memory_order_acquire);
    for (void* action : {a.save, a.save_as}) {
        if (!action) continue;
        api().set_visible(action, started);
        api().set_enabled(action, started && can_save);
    }
    if (a.save) {
        const qt::QString tip(linked.empty() ? std::string("Save this place to its template")
                                             : "Save this place to the template “" + linked + "”");
        api().set_tooltip(a.save, tip.data());
    }
    if (a.save_as) {
        const qt::QString tip("Save this place as a new template");
        api().set_tooltip(a.save_as, tip.data());
    }
}

// Connects destroyed() to clear the given slot. Returns whether it connected;
// callers store the pointer only when it did.
bool track_destroyed(void* object, void* Attached::*slot) {
    return detail::connect_function(object, api().destroyed, api().object_meta, [object, slot](void**) {
        auto& a = attached();
        if (a.*slot == object) a.*slot = nullptr;
    });
}
void retire(void* action) {
    set_name(action, kRetiredName);
    api().set_enabled(action, false);
    api().set_visible(action, false);
}
// One of ours, created by the menu (which owns it). Returned only if both its
// triggered() and destroyed() connections are established; otherwise it is
// retired in place and nothing refers to it.
void* create(void* menu, const char* label, const char* name, bool save_as, void* Attached::*slot) {
    auto* action = static_cast<qt::QMenu*>(menu)->addAction(qt::QString(label));
    if (!action) return nullptr;
    action->setMenuRole(qt::QAction::NoRole);
    set_name(action, name);
    api().set_enabled(action, false);
    const bool wired = detail::connect_function(action, api().triggered, api().action_meta, [save_as](void**) {
        try { on_triggered(save_as); } catch (...) { }
    });
    if (!wired || !track_destroyed(action, slot)) { retire(action); return nullptr; }
    return action;
}

// The menu bar that shows this menu's entry, freshly read; null if none.
void* menu_bar_of(void* menu) {
    void* const action = api().menu_action(menu);
    if (!action) return nullptr;
    for (void* widget : list_of(api().associated, action))
        if (widget && static_cast<qt::QObject*>(widget)->inherits("QMenuBar")) return widget;
    return nullptr;
}
struct Candidate { void* menu; void* window; };
// Top-level File menus on a menu bar. One is used outright; with several, the
// one on the active window, else the only one in a QMainWindow. Anything
// else is ambiguous and returns null (fail closed).
void* choose_file_menu() {
    std::vector<Candidate> candidates;
    for (auto* widget : qt::QApplication::all_widgets()) {
        if (!widget || !widget->inherits("QMenu")) continue;
        if (plain(string_of(api().title, widget)) != "File") continue;
        if (void* const bar = menu_bar_of(widget)) candidates.push_back({widget, api().window(bar)});
    }
    if (candidates.size() == 1) return candidates.front().menu;
    if (candidates.empty()) return nullptr;
    const auto only = [&](auto&& keep) -> void* {
        void* found = nullptr;
        for (const auto& candidate : candidates)
            if (keep(candidate)) {
                if (found) return nullptr;
                found = candidate.menu;
            }
        return found;
    };
    if (void* const active = api().active_window())
        if (void* menu = only([&](const Candidate& c) { return c.window == active; })) return menu;
    return only([](const Candidate& c) {
        return c.window && static_cast<qt::QObject*>(c.window)->inherits("QMainWindow");
    });
}

// Any action of ours, live or retired: never mistaken for a built-in.
bool ours(void* action) { return string_of(api().object_name, action).starts_with("ctplSaveTemplate"); }
// Where our pair belongs: right after the last built-in item whose label
// starts with "Save" (Studio's save group); null means the end of the menu.
void* insertion_point(const std::vector<void*>& actions, void* save, void* save_as) {
    void* before = nullptr;
    for (std::size_t index = 0; index < actions.size(); ++index) {
        void* action = actions[index];
        if (action == save || action == save_as || api().is_separator(action) || ours(action)) continue;
        if (!plain(string_of(api().text, action)).starts_with("Save")) continue;
        before = nullptr;
        for (std::size_t next = index + 1; next < actions.size(); ++next)
            if (actions[next] != save && actions[next] != save_as) { before = actions[next]; break; }
    }
    return before;
}
// Puts our existing pair in place if it is missing from the menu (e.g. a
// removeAction without destruction) or out of order. Only our two actions
// are moved; built-ins are never touched; nothing is created here.
void place_pair(void* menu, void* save, void* save_as) {
    const auto actions = list_of(api().actions, menu);
    void* const before = insertion_point(actions, save, save_as);
    const auto at = [&](void* action) { return std::find(actions.begin(), actions.end(), action); };
    const auto save_at = at(save), save_as_at = at(save_as);
    const bool placed = save_at != actions.end() && save_as_at == save_at + 1 &&
        (before ? save_as_at + 1 != actions.end() && *(save_as_at + 1) == before : save_as_at + 1 == actions.end());
    if (placed) return;
    for (void* action : {save, save_as}) {
        api().remove_action(menu, action);
        api().insert_action(menu, before, action);
    }
}

void attach();
// The menu our pair lives in, with its own lifecycle tracking. Returns false
// (and leaves the previous menu) if tracking cannot be established.
bool adopt_menu(void* menu) {
    auto& a = attached();
    if (a.menu == menu) return true;
    if (!track_destroyed(menu, &Attached::menu)) return false;
    // If Studio refills the File menu as it opens, ours return in the same
    // show rather than at the next periodic check. Best effort only.
    detail::connect_function(menu, api().about_to_show, api().menu_meta, [menu](void**) {
        try { if (attached().menu == menu && g_started.load()) attach(); } catch (...) { }
    });
    a.menu = menu;
    return true;
}

void attach() {
    auto& a = attached();
    if (!api().ready || !qt::QApplication::instance()) return;
    void* const menu = choose_file_menu();
    if (!menu) {
        // Ambiguous or absent: keep a still-valid pair where it is, repaired.
        if (a.menu && a.save && a.save_as) place_pair(a.menu, a.save, a.save_as);
        apply_state();
        return;
    }
    void* const previous = a.menu;
    if (!adopt_menu(menu)) return;
    if (previous && previous != menu && a.save && a.save_as) {
        // Moving windows: the pair leaves the old menu (no copy stays behind)
        // and the new menu becomes its owner, so it outlives the old one.
        for (void* action : {a.save, a.save_as}) {
            api().remove_action(previous, action);
            api().set_parent(action, menu);
        }
    }
    // Reuse ours already in this menu by name: never a second pair.
    if (!a.save || !a.save_as) {
        for (void* action : list_of(api().actions, menu)) {
            const auto name = string_of(api().object_name, action);
            if (name == kSaveName && !a.save && track_destroyed(action, &Attached::save)) a.save = action;
            if (name == kSaveAsName && !a.save_as && track_destroyed(action, &Attached::save_as)) a.save_as = action;
        }
    }
    if (!a.save) a.save = create(menu, kSaveLabel, kSaveName, false, &Attached::save);
    if (!a.save_as) a.save_as = create(menu, kSaveAsLabel, kSaveAsName, true, &Attached::save_as);
    if (a.save && a.save_as) place_pair(menu, a.save, a.save_as);
    apply_state();
}

// The status bar of the active main window, else of the window holding our
// File menu: an existing QStatusBar whose window() is that window.
void show_status(const std::string& text) {
    if (!api().ready || !api().show_message || !qt::QApplication::instance()) return;
    void* target = api().active_window();
    if (!target || !static_cast<qt::QObject*>(target)->inherits("QMainWindow")) {
        target = nullptr;
        if (attached().menu)
            if (void* const bar = menu_bar_of(attached().menu)) target = api().window(bar);
    }
    if (!target) return;
    for (auto* widget : qt::QApplication::all_widgets()) {
        if (!widget || !widget->inherits("QStatusBar") || api().window(widget) != target) continue;
        const qt::QString message(text);
        api().show_message(widget, message.data(), kStatusMilliseconds);
        return;
    }
}

// While started, re-check every few seconds: a new window's menu bar, a
// rebuilt File menu, or a removed/reordered pair is repaired.
void check_later() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kCheckSeconds * static_cast<std::int64_t>(NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (!g_started.load(std::memory_order_acquire)) { g_checking.store(false); return; }
            ctpl::dispatch_gui([] { attach(); });
            check_later();
        });
}
} // namespace

void ctpl_filemenu_start() {
    g_started.store(true, std::memory_order_release);
    ctpl::dispatch_gui([] { attach(); });
    if (!g_checking.exchange(true)) check_later();
}

void ctpl_filemenu_stop() {
    g_started.store(false, std::memory_order_release);
    ctpl::dispatch_gui([] { if (api().ready) apply_state(); });
}

void ctpl_filemenu_set_state(bool can_save, const std::string& linked_template_name) {
    {
        std::lock_guard lock(g_mutex);
        g_can_save = can_save;
        g_linked = linked_template_name;
    }
    ctpl::dispatch_gui([] { if (api().ready) apply_state(); });
}

void ctpl_filemenu_status(const std::string& text) {
    ctpl::dispatch_gui([text] { show_status(text); });
}
