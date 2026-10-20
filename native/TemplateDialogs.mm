#include "TemplateDialogs.hpp"
#include "StartPageUI.hpp"
#include "NativeGuiDispatch.hpp"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#include <RobloxModLoader/memory/foreign_call.hpp>
#include <RobloxModLoader/qt/qapplication.hpp>
#include <RobloxModLoader/qt/qcheckbox.hpp>
#include <RobloxModLoader/qt/qdialog.hpp>
#include <RobloxModLoader/qt/qfiledialog.hpp>
#include <RobloxModLoader/qt/qlabel.hpp>
#include <RobloxModLoader/qt/qmessagebox.hpp>
#include <RobloxModLoader/qt/qpixmap.hpp>
#include <RobloxModLoader/qt/qpushbutton.hpp>
#include <RobloxModLoader/qt/qstring.hpp>
#include <RobloxModLoader/qt/qt_module.hpp>

#import <Foundation/Foundation.h>

// Exported by roblox_modloader.dylib (src/qt/qt_connect.hpp is not public).
namespace rml::qt::detail {
bool connect_function(const void* sender, void* signal_addr, const void* sender_meta, std::function<void(void**)> slot);
}

namespace {
namespace qt = rml::qt;
namespace detail = rml::qt::detail;

// Exact Qt 5.15 exports that the RML SDK does not wrap. Every one is resolved
// by demangled signature before the dialog is ever constructed.
struct Api {
    void* (*line_edit_ctor)(void*, void*) = nullptr;
    void (*line_edit_set_text)(void*, const void*) = nullptr;
    void* line_edit_text = nullptr; // QString QLineEdit::text() const, indirect return
    void (*line_edit_placeholder)(void*, const void*) = nullptr;
    void (*line_edit_max_length)(void*, int) = nullptr;
    void (*line_edit_select_all)(void*) = nullptr;
    void (*line_edit_read_only)(void*, bool) = nullptr;
    void (*set_focus)(void*, int) = nullptr;
    void (*hide)(void*) = nullptr;
    void (*raise)(void*) = nullptr;
    void (*activate)(void*) = nullptr;
    void (*set_object_name)(void*, const void*) = nullptr;
    void (*accept)(void*) = nullptr;
    void (*reject)(void*) = nullptr;
    void* rejected = nullptr;
    const void* dialog_meta = nullptr;
    void (*set_pixmap)(void*, const void*) = nullptr;
    void (*word_wrap)(void*, bool) = nullptr;
    void (*text_format)(void*, int) = nullptr;
    void* (*message_add_button)(void*, const void*, int) = nullptr;
    void* (*message_clicked)(const void*) = nullptr;
    void (*message_informative)(void*, const void*) = nullptr;
    void (*message_default)(void*, void*) = nullptr;
    void (*button_default)(void*, bool) = nullptr;
    void (*button_auto_default)(void*, bool) = nullptr;
    bool ready = false;
};
template<class T> void widget(T& slot, const char* signature) {
    slot = reinterpret_cast<T>(detail::widgets_export_optional(signature));
}
Api& api() {
    static Api* const value = new Api();
    static std::once_flag once;
    std::call_once(once, [] {
        auto& a = *value;
        widget(a.line_edit_ctor, "QLineEdit::QLineEdit(QWidget*)");
        widget(a.line_edit_set_text, "QLineEdit::setText(QString const&)");
        a.line_edit_text = detail::widgets_export_optional("QLineEdit::text() const");
        widget(a.line_edit_placeholder, "QLineEdit::setPlaceholderText(QString const&)");
        widget(a.line_edit_max_length, "QLineEdit::setMaxLength(int)");
        widget(a.line_edit_select_all, "QLineEdit::selectAll()");
        widget(a.line_edit_read_only, "QLineEdit::setReadOnly(bool)");
        widget(a.set_focus, "QWidget::setFocus(Qt::FocusReason)");
        widget(a.hide, "QWidget::hide()");
        widget(a.raise, "QWidget::raise()");
        widget(a.activate, "QWidget::activateWindow()");
        a.set_object_name = reinterpret_cast<void (*)(void*, const void*)>(
            detail::core_export_optional("QObject::setObjectName(QString const&)"));
        widget(a.accept, "QDialog::accept()");
        widget(a.reject, "QDialog::reject()");
        a.rejected = detail::widgets_export_optional("QDialog::rejected()");
        a.dialog_meta = detail::widgets_export_optional("QDialog::staticMetaObject");
        widget(a.set_pixmap, "QLabel::setPixmap(QPixmap const&)");
        widget(a.word_wrap, "QLabel::setWordWrap(bool)");
        widget(a.text_format, "QLabel::setTextFormat(Qt::TextFormat)");
        widget(a.message_add_button, "QMessageBox::addButton(QString const&, QMessageBox::ButtonRole)");
        widget(a.message_clicked, "QMessageBox::clickedButton() const");
        widget(a.message_informative, "QMessageBox::setInformativeText(QString const&)");
        widget(a.message_default, "QMessageBox::setDefaultButton(QPushButton*)");
        widget(a.button_default, "QPushButton::setDefault(bool)");
        widget(a.button_auto_default, "QPushButton::setAutoDefault(bool)");
        // SDK wrappers used below resolve these themselves; require them too so
        // availability means the whole dialog can be built.
        const bool sdk = detail::widgets_export_optional("QDialog::QDialog(QWidget*, QFlags<Qt::WindowType>)") &&
            detail::widgets_export_optional("QLabel::QLabel(QString const&, QWidget*, QFlags<Qt::WindowType>)") &&
            detail::widgets_export_optional("QPushButton::QPushButton(QString const&, QWidget*)") &&
            detail::widgets_export_optional("QCheckBox::QCheckBox(QString const&, QWidget*)") &&
            detail::widgets_export_optional("QMessageBox::QMessageBox(QWidget*)") &&
            detail::widgets_export_optional("QAbstractButton::clicked(bool)") &&
            detail::widgets_export_optional("QFileDialog::getOpenFileName(QWidget*, QString const&, QString const&, QString const&, QString*, QFlags<QFileDialog::Option>)");
        a.ready = sdk && a.line_edit_ctor && a.line_edit_set_text && a.line_edit_text && a.line_edit_placeholder &&
            a.line_edit_max_length && a.line_edit_select_all && a.line_edit_read_only && a.set_focus && a.hide && a.raise && a.activate &&
            a.set_object_name && a.accept && a.reject && a.rejected &&
            a.dialog_meta && a.set_pixmap && a.word_wrap && a.text_format && a.message_add_button &&
            a.message_clicked && a.message_informative && a.message_default && a.button_default && a.button_auto_default;
    });
    return *value;
}

constexpr int kWidth = 520;
constexpr int kPad = 24;
constexpr int kField = kWidth - 2 * kPad;
constexpr int kOtherFocusReason = 7;
constexpr int kPlainText = 0;
constexpr int kRejectRole = 1;
constexpr int kDestructiveRole = 2;
// Matches TemplateCatalog.ValidateName (UTF-16 units, as QLineEdit counts).
constexpr int kNameLength = 120;
// Matches TemplateCatalog.MaximumThumbnailBytes and the capture size bound.
constexpr long long kThumbnailBytes = 8LL * 1024 * 1024;
constexpr std::uint32_t kThumbnailPixels = 4096;

constexpr const char* kStyle = R"(
QDialog { background: #1E1F24; }
QLabel { color: #E8EAED; font-size: 13px; background: transparent; }
QLabel#ctplTitle { color: #FFFFFF; font-size: 18px; font-weight: 600; }
QLabel#ctplSubtitle, QLabel#ctplHint, QLabel#ctplNote { color: #A5ABB7; font-size: 12px; }
QLabel#ctplCaption { color: #A5ABB7; font-size: 11px; font-weight: 600; }
QLabel#ctplFile { background: #2A2C33; border: 1px solid #3A3D46; border-radius: 6px; padding: 0 10px; }
QLabel#ctplPreview { background: #2A2C33; border: 1px solid #3A3D46; border-radius: 8px; color: #6B707B; font-size: 11px; }
QLabel#ctplError { color: #F07178; font-size: 12px; }
QLineEdit { background: #2A2C33; color: #F2F3F5; border: 1px solid #3A3D46; border-radius: 6px; padding: 0 10px; font-size: 13px; selection-background-color: #006FEE; }
QLineEdit:focus { border-color: #006FEE; }
QPushButton { background: #2E3038; color: #F2F3F5; border: 1px solid #3A3D46; border-radius: 6px; padding: 0 14px; font-size: 13px; min-height: 30px; }
QPushButton:hover { background: #383B44; }
QPushButton:pressed { background: #24262C; }
QPushButton#ctplPicker { text-align: left; padding-left: 10px; }
QPushButton#ctplPrimary { background: #006FEE; border-color: #006FEE; color: #FFFFFF; font-weight: 600; }
QPushButton#ctplPrimary:hover { background: #1A80F5; }
QPushButton#ctplPrimary:pressed { background: #005BC4; }
QPushButton#ctplDanger { background: transparent; border-color: #5A2E33; color: #F07178; }
QPushButton#ctplDanger:hover { background: #3A2226; }
QPushButton#ctplConfirm { background: #C9434E; border-color: #C9434E; color: #FFFFFF; font-weight: 600; }
QPushButton#ctplConfirm:hover { background: #D85560; }
QPushButton#ctplSmall { min-height: 26px; padding: 0 10px; font-size: 12px; }
QPushButton#ctplLink { min-height: 26px; padding: 0 8px; font-size: 12px; background: transparent; border-color: transparent; color: #4C9BFF; }
QPushButton#ctplLink:hover { background: #24304A; }
QCheckBox:disabled { color: #6B707B; }
QLineEdit:read-only { color: #A5ABB7; background: #24262C; }
QCheckBox { color: #E8EAED; font-size: 13px; spacing: 8px; }
QMessageBox { background: #1E1F24; }
)";

enum class Mode { Create, Edit, CategoryNew, CategoryEdit };
struct Choice { std::string id, name; };

// GUI-thread-only. Built once and reused for every request; never destroyed.
struct Dialog {
    bool built = false, failed = false;
    qt::QDialog* window = nullptr;
    qt::QLabel *title = nullptr, *subtitle = nullptr, *name_caption = nullptr, *category_caption = nullptr,
        *file_caption = nullptr, *thumb_caption = nullptr, *file = nullptr, *preview = nullptr, *hint = nullptr,
        *note = nullptr, *error = nullptr;
    void* name = nullptr;
    qt::QPushButton *category = nullptr, *choose = nullptr, *remove = nullptr, *cancel = nullptr, *save = nullptr;
    qt::QPushButton *thumb_choose = nullptr, *thumb_auto = nullptr;
    qt::QCheckBox* capture = nullptr;
    qt::QMessageBox* confirm = nullptr;
    qt::QMessageBox* notice = nullptr;
    qt::QPushButton *confirm_yes = nullptr, *confirm_no = nullptr;

    // Current request.
    Mode mode = Mode::Create;
    std::string id, category_id, thumbnail_path, source_path, picked_path;
    bool current_place = false;
    std::string request_id, source_label;
    // A PNG the user chose for this request only; empty means automatic.
    std::string manual_path;
    std::vector<Choice> categories;
    // Category chooser: a child Qt dialog of plain push buttons, built once.
    // Its rows act only while chooser_open; a superseding request, save,
    // cancel or stop closes it first.
    qt::QDialog* chooser = nullptr;
    qt::QLabel *chooser_title = nullptr, *chooser_page_label = nullptr;
    std::vector<qt::QPushButton*> chooser_rows;
    qt::QPushButton *chooser_previous = nullptr, *chooser_next = nullptr, *chooser_cancel = nullptr;
    bool chooser_failed = false, chooser_open = false;
    int chooser_page = 0;
    std::vector<Choice> chooser_choices;
    bool is_protected = false;
    bool open = false;
    std::uint64_t session = 0;
    // Nested Qt event loops (file picker, menu, confirmation) may process GUI
    // tasks; requests arriving then are deferred until the loop returns.
    int nested = 0;
    std::optional<std::string> pending;
    bool pending_stop = false;
};
Dialog& ui() {
    static Dialog* const value = new Dialog();
    return *value;
}
std::atomic<bool> g_stopped{false};

void schedule(std::function<void()> task) {
    ctpl::dispatch_gui([task = std::move(task)] {
        if (qt::QApplication::instance()) task();
    });
}

std::string json(NSDictionary* value) {
    NSData* const data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? std::string(static_cast<const char*>(data.bytes), data.length) : std::string();
}
NSString* ns(const std::string& value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}
std::string utf8(id value) {
    return [value isKindOfClass:NSString.class] && [value UTF8String] ? [value UTF8String] : "";
}
std::string trimmed(const std::string& value) {
    @autoreleasepool {
        return utf8([ns(value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }
}
std::string file_name(const std::string& path) { @autoreleasepool { return utf8(ns(path).lastPathComponent); } }
std::string file_stem(const std::string& path) {
    @autoreleasepool { return utf8(ns(path).lastPathComponent.stringByDeletingPathExtension); }
}
std::string directory(const std::string& path) {
    @autoreleasepool { return path.empty() ? std::string() : utf8(ns(path).stringByDeletingLastPathComponent); }
}
bool place_file(const std::string& path) {
    @autoreleasepool {
        NSString* const extension = ns(path).pathExtension.lowercaseString;
        return [extension isEqualToString:@"rbxl"] || [extension isEqualToString:@"rbxlx"];
    }
}

void post(NSDictionary* command) {
    std::string text;
    @autoreleasepool { text = json(command); }
    if (!text.empty()) ctpl_post_command(text);
}

void name_object(void* object, const char* name) {
    const qt::QString value(name);
    api().set_object_name(object, value.data());
}
template<class T> T* tagged(T* object, const char* name) {
    if (object) name_object(object, name);
    return object;
}
qt::QLabel* make_label(const char* object_name, bool wrap = false) {
    auto* label = tagged(qt::QLabel::create("", ui().window), object_name);
    if (label) {
        api().text_format(label, kPlainText);
        if (wrap) api().word_wrap(label, true);
    }
    return label;
}
void set_text(qt::QLabel* label, const std::string& text) { label->setText(text); }
void set_field(void* edit, const std::string& text) {
    const qt::QString value(text);
    api().line_edit_set_text(edit, value.data());
}
std::string field(void* edit) {
    qt::QString value;
    rml::memory::call_returning_member<void*>(api().line_edit_text, *static_cast<void**>(value.storage()),
        static_cast<const void*>(edit));
    return value.to_utf8();
}
void show_at(qt::QWidget* widget, int x, int y, int width, int height) {
    widget->setGeometry(x, y, width, height);
    widget->show();
}
void hide(void* widget) { api().hide(widget); }

const Choice* choice(const std::string& id) {
    for (const auto& value : ui().categories)
        if (value.id == id) return &value;
    return nullptr;
}
void refresh_category() {
    auto& d = ui();
    const auto* current = choice(d.category_id);
    d.category->setText((current ? (current->name.empty() ? "Untitled" : current->name) : "Choose a category") + "   ▾");
}
void show_error(const std::string& text) {
    set_text(ui().error, text);
    ui().error->show();
}
void show_preview(const std::string& path, const char* fallback) {
    auto& d = ui();
    if (!path.empty()) {
        const qt::QPixmap image(path);
        if (image.loaded()) {
            const auto scaled = image.scaled(158, 88, qt::QPixmap::AspectMode::Keep);
            api().set_pixmap(d.preview, scaled.data());
            return;
        }
    }
    set_text(d.preview, fallback);
}

bool category_mode() { return ui().mode == Mode::CategoryNew || ui().mode == Mode::CategoryEdit; }
bool locked() { return ui().mode == Mode::CategoryEdit && ui().is_protected; }
// Studio's own category names; TemplateCatalog rejects them too.
bool reserved_category(const std::string& name) {
    @autoreleasepool {
        NSString* const value = ns(name);
        for (NSString* reserved in @[@"All", @"Blank", @"Gameplay", @"Themed"])
            if ([value caseInsensitiveCompare:reserved] == NSOrderedSame) return true;
        return false;
    }
}

// Checks a chosen thumbnail before it is previewed or sent: a regular file of
// at most 8 MiB whose PNG header declares 1..4096 pixels on each side. The
// header is read first so an oversized image is never decoded.
std::string png_issue(const std::string& path) {
    long long bytes = -1;
    @autoreleasepool {
        NSDictionary* const attributes = [NSFileManager.defaultManager attributesOfItemAtPath:ns(path) error:nil];
        if ([attributes[NSFileType] isEqual:NSFileTypeRegular]) bytes = [attributes[NSFileSize] longLongValue];
        if (![ns(path).pathExtension.lowercaseString isEqualToString:@"png"]) return "Choose a .png image.";
    }
    if (bytes <= 0) return "That image can't be read.";
    if (bytes > kThumbnailBytes) return "Choose a PNG of 8 MB or less.";
    unsigned char header[24]{};
    std::ifstream file(path, std::ios::binary);
    if (!file.read(reinterpret_cast<char*>(header), sizeof(header))) return "That image can't be read.";
    static constexpr unsigned char kSignature[]{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    if (std::memcmp(header, kSignature, 8) != 0 || std::memcmp(header + 12, "IHDR", 4) != 0)
        return "That file is not a PNG image.";
    const auto big_endian = [&](int at) {
        return std::uint32_t{header[at]} << 24 | std::uint32_t{header[at + 1]} << 16 |
            std::uint32_t{header[at + 2]} << 8 | std::uint32_t{header[at + 3]};
    };
    const auto width = big_endian(16), height = big_endian(20);
    if (width == 0 || height == 0 || width > kThumbnailPixels || height > kThumbnailPixels)
        return "Choose a PNG up to 4096 × 4096 pixels.";
    return {};
}

// One place decides the thumbnail column from the request state, so every
// path (new request, replacement place, manual PNG, revert) stays consistent.
void refresh_thumbnail() {
    auto& d = ui();
    const bool manual = !d.manual_path.empty();
    const bool fresh_place = d.mode == Mode::Create || !d.picked_path.empty();
    d.capture->setEnabled(!manual);
    if (manual) {
        d.capture->setChecked(false);
        show_preview(d.manual_path, "Custom image");
        set_text(d.hint, "Using " + file_name(d.manual_path) + ". It replaces the automatic capture.");
        d.thumb_auto->show();
        return;
    }
    hide(d.thumb_auto);
    if (d.current_place) show_preview(d.thumbnail_path, "Current viewport");
    else if (fresh_place) show_preview({}, d.mode == Mode::Create ? "Captured after saving" : "New capture after saving");
    else show_preview(d.thumbnail_path, "No thumbnail yet");
    set_text(d.hint, d.current_place ? "Uses the current place's viewport, or choose your own PNG." : fresh_place
        ? "Opens a separate copy in Studio to capture its 3D view. Your file stays unchanged."
        : "Keeps the current thumbnail. Check the box to recapture, or choose your own PNG.");
}

void flush_pending();
// Exceptions must never unwind through a Qt signal emission.
std::function<void()> guarded(void (*handler)()) {
    return [handler] { try { handler(); } catch (...) { } };
}
struct NestedLoop {
    NestedLoop() { ++ui().nested; }
    ~NestedLoop() { --ui().nested; }
    NestedLoop(const NestedLoop&) = delete;
    NestedLoop& operator=(const NestedLoop&) = delete;
};
void dismiss_chooser();
void close_then_post(NSDictionary* command) {
    auto& d = ui();
    dismiss_chooser();
    d.open = false;
    ++d.session;
    api().accept(d.window);
    post(command);
}

void on_save() {
    auto& d = ui();
    if (!d.open || locked() || d.nested > 0) return;
    const auto name = trimmed(field(d.name));
    if (name.empty()) { show_error("Enter a name."); return; }
    if (category_mode()) {
        if (reserved_category(name)) { show_error("All, Blank, Gameplay, and Themed are Roblox's own categories."); return; }
        @autoreleasepool {
            NSMutableDictionary* const command = [@{@"type": @"save_category", @"name": ns(name)} mutableCopy];
            if (d.mode == Mode::CategoryEdit) command[@"id"] = ns(d.id);
            close_then_post(command);
        }
        return;
    }
    if (!choice(d.category_id)) { show_error("Choose a category."); return; }
    if (d.mode == Mode::Create && d.picked_path.empty()) { show_error("Choose a .rbxl or .rbxlx place file."); return; }
    @autoreleasepool {
        NSMutableDictionary* const command = [@{
            @"type": d.current_place ? @"save_current_snapshot" : @"save_template", @"name": ns(name), @"categoryId": ns(d.category_id),
            @"captureThumbnail": @(d.manual_path.empty() && d.capture->isChecked()),
        } mutableCopy];
        if (d.current_place) command[@"requestId"] = ns(d.request_id);
        if (d.mode == Mode::Edit) command[@"id"] = ns(d.id);
        if (!d.picked_path.empty()) command[@"path"] = ns(d.picked_path);
        if (!d.manual_path.empty()) command[@"thumbnailPath"] = ns(d.manual_path);
        close_then_post(command);
    }
}

void on_rejected() {
    auto& d = ui();
    if (!d.open) return;
    dismiss_chooser();
    d.open = false;
    ++d.session;
    post(@{@"type": @"dialog_cancelled", @"requestId": ns(d.request_id)});
}

void on_remove() {
    auto& d = ui();
    const bool category = d.mode == Mode::CategoryEdit;
    if (!d.open || (d.mode != Mode::Edit && !category) || (category && d.is_protected)) return;
    const auto session = d.session;
    const auto name = trimmed(field(d.name));
    const auto shown = name.empty() ? std::string("this item") : "“" + name + "”";
    {
        const qt::QString text(category ? "Remove the category " + shown + "?" : "Remove " + shown + " from your templates?");
        d.confirm->setText(text);
        const qt::QString detail(category
            ? "Its templates move to the default category. No templates are removed."
            : "The stored snapshot is archived and the card disappears. Your original place file and any opened copies are not affected.");
        api().message_informative(d.confirm, detail.data());
    }
    d.confirm_yes->setText(category ? "Remove Category" : "Remove Template");
    const void* clicked = nullptr;
    {
        NestedLoop loop;
        d.confirm->exec();
        clicked = api().message_clicked(d.confirm);
    }
    if (clicked == d.confirm_yes && d.open && d.session == session) {
        @autoreleasepool {
            close_then_post(@{@"type": category ? @"remove_category" : @"remove", @"id": ns(d.id)});
        }
    }
    flush_pending();
}

void on_choose() {
    auto& d = ui();
    if (!d.open || (d.mode != Mode::Create && d.mode != Mode::Edit)) return;
    const auto start = directory(d.picked_path.empty() ? d.source_path : d.picked_path);
    std::string path;
    {
        NestedLoop loop;
        path = qt::QFileDialog::get_open_file_name(d.window,
            d.mode == Mode::Create ? "Choose a place file" : "Choose an updated place file", start,
            "Roblox places (*.rbxl *.rbxlx)");
    }
    if (d.open && !path.empty()) {
        if (!place_file(path)) show_error("Choose a .rbxl or .rbxlx place file.");
        else {
            d.picked_path = path;
            set_text(d.file, file_name(path));
            if (trimmed(field(d.name)).empty()) set_field(d.name, file_stem(path));
            // A new or replaced place returns to a fresh automatic capture;
            // an image chosen for the previous place is dropped.
            d.manual_path.clear();
            refresh_thumbnail();
            d.capture->setChecked(true);
            hide(d.error);
        }
    }
    flush_pending();
}

void on_thumbnail_choose() {
    auto& d = ui();
    if (!d.open || category_mode()) return;
    const auto start = directory(d.manual_path.empty() ? d.thumbnail_path : d.manual_path);
    std::string path;
    {
        NestedLoop loop;
        path = qt::QFileDialog::get_open_file_name(d.window, "Choose a thumbnail image", start, "PNG images (*.png)");
    }
    if (d.open && !path.empty()) {
        if (const auto issue = png_issue(path); !issue.empty()) show_error(issue);
        else {
            d.manual_path = path;
            refresh_thumbnail();
            hide(d.error);
        }
    }
    flush_pending();
}

void on_thumbnail_automatic() {
    auto& d = ui();
    if (!d.open || d.manual_path.empty()) return;
    d.manual_path.clear();
    refresh_thumbnail();
    d.capture->setChecked(d.mode == Mode::Create || !d.picked_path.empty());
}

// Category chooser. QMenu::exec showed nothing from this application-modal
// editor, and an NSMenu showed but never delivered its selection, so the
// chooser is a small child QDialog built only from QLabel/QPushButton, the
// controls the editor itself already relies on. It is shown with show(),
// application-modal like the editor: no popup window and no nested loop.
constexpr int kChooserWidth = 360;
constexpr int kChooserRows = 8;  // per page; longer lists page with Previous/Next
constexpr int kChooserRowHeight = 34;
constexpr int kChooserGap = 6;
constexpr const char* kChoiceOff = "QPushButton { text-align: left; padding-left: 14px; }";
constexpr const char* kChoiceOn =
    "QPushButton { text-align: left; padding-left: 14px; background: #1E3A66; border-color: #006FEE; font-weight: 600; }";

void close_chooser(bool accepted) {
    auto& d = ui();
    if (!d.chooser || !d.chooser_open) return;
    d.chooser_open = false;
    if (accepted) api().accept(d.chooser);
    else hide(d.chooser);
}
// Any request change, save, cancel or stop: hide without choosing.
void dismiss_chooser() { close_chooser(false); }

int chooser_pages() {
    const auto count = static_cast<int>(ui().chooser_choices.size());
    return std::max(1, (count + kChooserRows - 1) / kChooserRows);
}

void show_chooser_page() {
    auto& d = ui();
    const int pages = chooser_pages();
    d.chooser_page = std::clamp(d.chooser_page, 0, pages - 1);
    constexpr int pad = 20, inner = kChooserWidth - 2 * pad;
    show_at(d.chooser_title, pad, 16, inner, 24);
    int y = 52;
    qt::QPushButton* focus = nullptr;
    for (int row = 0; row < kChooserRows; ++row) {
        auto* const button = d.chooser_rows[static_cast<std::size_t>(row)];
        const auto index = static_cast<std::size_t>(d.chooser_page * kChooserRows + row);
        if (index >= d.chooser_choices.size()) { hide(button); continue; }
        const auto& value = d.chooser_choices[index];
        const bool current = value.id == d.category_id;
        button->setText((current ? "✓  " : "") + (value.name.empty() ? std::string("Untitled") : value.name));
        const qt::QString style(current ? kChoiceOn : kChoiceOff);
        button->setStyleSheet(style);
        show_at(button, pad, y, inner, kChooserRowHeight);
        if (current || !focus) focus = button;  // the current row, else the first
        y += kChooserRowHeight + kChooserGap;
    }
    y += 6;
    if (pages > 1) {
        d.chooser_previous->setEnabled(d.chooser_page > 0);
        d.chooser_next->setEnabled(d.chooser_page < pages - 1);
        show_at(d.chooser_previous, pad, y, 96, 30);
        set_text(d.chooser_page_label, std::to_string(d.chooser_page + 1) + " of " + std::to_string(pages));
        show_at(d.chooser_page_label, pad + 104, y, inner - 208, 30);
        show_at(d.chooser_next, pad + inner - 96, y, 96, 30);
        y += 30 + 14;
    } else {
        hide(d.chooser_previous);
        hide(d.chooser_next);
        hide(d.chooser_page_label);
    }
    show_at(d.chooser_cancel, pad + inner - 100, y, 100, 32);
    d.chooser->setFixedSize(kChooserWidth, y + 32 + 18);
    if (focus) api().set_focus(focus, kOtherFocusReason);
}

// A row click: the chosen ID must still belong to the open editor request.
void on_choice(int row) {
    auto& d = ui();
    if (!d.open || !d.chooser_open || row < 0 || row >= kChooserRows) return;
    const auto index = static_cast<std::size_t>(d.chooser_page * kChooserRows + row);
    if (index >= d.chooser_choices.size()) return;
    const auto identifier = d.chooser_choices[index].id;
    if (choice(identifier)) {
        d.category_id = identifier;
        refresh_category();
        hide(d.error);
    }
    close_chooser(true);
}

void on_chooser_page(int delta) {
    auto& d = ui();
    if (!d.open || !d.chooser_open) return;
    d.chooser_page += delta;
    show_chooser_page();
}

bool build_chooser() {
    auto& d = ui();
    if (d.chooser || d.chooser_failed) return d.chooser != nullptr;
    d.chooser_failed = true;
    auto& a = api();
    auto* const chooser = qt::QDialog::create(d.window);
    if (!chooser) return false;
    {
        const qt::QString style(kStyle), caption("Category");
        chooser->setStyleSheet(style);
        chooser->setWindowTitle(caption);
    }
    chooser->setModal(true);
    auto* const title = tagged(qt::QLabel::create("Choose a category", chooser), "ctplTitle");
    auto* const page = tagged(qt::QLabel::create("", chooser), "ctplHint");
    auto* const previous = tagged(qt::QPushButton::create("‹  Previous", chooser), "ctplSmall");
    auto* const next = tagged(qt::QPushButton::create("Next  ›", chooser), "ctplSmall");
    auto* const cancel = qt::QPushButton::create("Cancel", chooser);
    if (!title || !page || !previous || !next || !cancel) return false;
    std::vector<qt::QPushButton*> rows;
    for (int row = 0; row < kChooserRows; ++row) {
        auto* const button = qt::QPushButton::create("", chooser);
        if (!button) return false;
        // Return/Space on the focused row choose it; nothing is the default.
        a.button_auto_default(button, true);
        button->on_clicked([row] { try { on_choice(row); } catch (...) { } });
        rows.push_back(button);
    }
    a.text_format(title, kPlainText);
    a.text_format(page, kPlainText);
    page->setAlignment(qt::QLabel::AlignCenter);
    for (auto* button : {previous, next, cancel}) a.button_auto_default(button, true);
    previous->on_clicked([] { try { on_chooser_page(-1); } catch (...) { } });
    next->on_clicked([] { try { on_chooser_page(1); } catch (...) { } });
    cancel->on_clicked([] { try { if (ui().chooser_open) api().reject(ui().chooser); } catch (...) { } });
    // Cancel, Escape and the close box all keep the current category.
    if (!detail::connect_function(chooser, a.rejected, a.dialog_meta,
            [](void**) { try { ui().chooser_open = false; } catch (...) { } }))
        return false;
    d.chooser = chooser;
    d.chooser_title = title;
    d.chooser_page_label = page;
    d.chooser_previous = previous;
    d.chooser_next = next;
    d.chooser_cancel = cancel;
    d.chooser_rows = std::move(rows);
    d.chooser_failed = false;
    return true;
}

void on_category() {
    auto& d = ui();
    if (!d.open || d.categories.empty() || d.nested > 0 || d.chooser_open) return;
    if (!build_chooser()) {
        show_error("The category chooser is unavailable. Close the editor and try again.");
        return;
    }
    d.chooser_choices = d.categories;
    int current = 0;
    for (std::size_t index = 0; index < d.chooser_choices.size(); ++index)
        if (d.chooser_choices[index].id == d.category_id) current = static_cast<int>(index);
    d.chooser_page = current / kChooserRows;
    d.chooser_open = true;
    show_chooser_page();
    d.chooser->show();
    api().raise(d.chooser);
    api().activate(d.chooser);
}

bool build() {
    auto& d = ui();
    if (d.built || d.failed) return d.built;
    d.failed = true;
    auto& a = api();
    if (!a.ready) return false;
    d.window = qt::QDialog::create(nullptr);
    if (!d.window) return false;
    {
        const qt::QString style(kStyle);
        d.window->setStyleSheet(style);
        const qt::QString caption("Custom Templates");
        d.window->setWindowTitle(caption);
    }
    // Application-modal but shown without exec(): Studio's event loop and the
    // engine keep running while the dialog is open.
    d.window->setModal(true);
    d.title = make_label("ctplTitle");
    d.subtitle = make_label("ctplSubtitle", true);
    d.name_caption = make_label("ctplCaption");
    d.category_caption = make_label("ctplCaption");
    d.file_caption = make_label("ctplCaption");
    d.thumb_caption = make_label("ctplCaption");
    d.file = make_label("ctplFile");
    d.preview = make_label("ctplPreview", true);
    d.hint = make_label("ctplHint", true);
    d.note = make_label("ctplNote", true);
    d.error = make_label("ctplError", true);
    d.name = detail::heap_construct<void>(detail::WIDGET_INSTANCE_SIZE, a.line_edit_ctor, static_cast<void*>(d.window));
    d.category = tagged(qt::QPushButton::create("", d.window), "ctplPicker");
    d.choose = qt::QPushButton::create("", d.window);
    d.remove = tagged(qt::QPushButton::create("", d.window), "ctplDanger");
    d.cancel = qt::QPushButton::create("Cancel", d.window);
    d.save = tagged(qt::QPushButton::create("", d.window), "ctplPrimary");
    d.capture = qt::QCheckBox::create("", d.window);
    d.thumb_choose = tagged(qt::QPushButton::create("Choose PNG…", d.window), "ctplSmall");
    d.thumb_auto = tagged(qt::QPushButton::create("Use automatic capture", d.window), "ctplLink");
    d.confirm = qt::QMessageBox::create(d.window);
    if (!d.title || !d.subtitle || !d.name_caption || !d.category_caption || !d.file_caption || !d.thumb_caption ||
        !d.file || !d.preview || !d.hint || !d.note || !d.error || !d.name || !d.category || !d.choose ||
        !d.remove || !d.cancel || !d.save || !d.capture || !d.thumb_choose || !d.thumb_auto || !d.confirm)
        return false;
    {
        const qt::QString title("Custom Templates");
        d.confirm->setWindowTitle(title);
        d.confirm->setIcon(qt::QMessageBox::Warning);
        const qt::QString yes("Remove"), no("Cancel");
        d.confirm_yes = static_cast<qt::QPushButton*>(a.message_add_button(d.confirm, yes.data(), kDestructiveRole));
        d.confirm_no = static_cast<qt::QPushButton*>(a.message_add_button(d.confirm, no.data(), kRejectRole));
        if (!d.confirm_yes || !d.confirm_no) return false;
        name_object(d.confirm_yes, "ctplConfirm");
        // Enter must never confirm a removal.
        a.message_default(d.confirm, d.confirm_no);
    }
    d.preview->setAlignment(qt::QLabel::AlignCenter);
    d.file->setAlignment(qt::QLabel::AlignLeft | qt::QLabel::AlignVCenter);
    {
        const qt::QString placeholder("Template name");
        a.line_edit_placeholder(d.name, placeholder.data());
    }
    a.line_edit_max_length(d.name, kNameLength);
    a.button_default(d.save, true);
    for (auto* other : {d.category, d.choose, d.remove, d.cancel, d.thumb_choose, d.thumb_auto})
        a.button_auto_default(other, false);
    d.capture->setText("Capture a thumbnail");

    d.save->on_clicked(guarded(on_save));
    d.cancel->on_clicked(guarded([] { if (ui().open) api().reject(ui().window); }));
    d.remove->on_clicked(guarded(on_remove));
    d.choose->on_clicked(guarded(on_choose));
    d.category->on_clicked(guarded(on_category));
    d.thumb_choose->on_clicked(guarded(on_thumbnail_choose));
    d.thumb_auto->on_clicked(guarded(on_thumbnail_automatic));
    // Escape, the close box and Cancel all arrive here exactly once.
    if (!detail::connect_function(d.window, a.rejected, a.dialog_meta,
            [handler = guarded(on_rejected)](void**) { handler(); }))
        return false;
    d.failed = false;
    d.built = true;
    return true;
}

void configure() {
    auto& d = ui();
    const bool categories = category_mode();
    // Every request starts from a clean slate: the dialog is reused, so no
    // visibility, enabled, read-only, or label state may leak between requests.
    for (qt::QWidget* widget : std::initializer_list<qt::QWidget*>{d.category_caption, d.file_caption,
             d.thumb_caption, d.file, d.preview, d.hint, d.note, d.error, d.category, d.choose, d.remove, d.capture,
             d.thumb_choose, d.thumb_auto, d.save})
        hide(widget);
    api().line_edit_read_only(d.name, locked());
    d.capture->setEnabled(true);
    d.cancel->setText(locked() ? "Close" : "Cancel");

    switch (d.mode) {
    case Mode::Create:
        set_text(d.title, d.current_place ? "Save to Template As" : "New Template");
        set_text(d.subtitle, d.current_place ? "Save the open place and its current edits to your template library."
            : "Save a place as a template. It appears on the Templates page in the category you choose.");
        break;
    case Mode::Edit:
        set_text(d.title, "Edit Template");
        set_text(d.subtitle, "Rename, recategorize, or update this template from a newer place file.");
        break;
    case Mode::CategoryNew:
        set_text(d.title, "New Category");
        set_text(d.subtitle, "Categories appear beside All, Blank, Gameplay, and Themed.");
        break;
    case Mode::CategoryEdit:
        set_text(d.title, locked() ? "Default Category" : "Edit Category");
        set_text(d.subtitle, locked() ? "Templates without another category are kept here."
                                      : "Rename this category. Right-click it on the Templates page to return here.");
        break;
    }
    show_at(d.title, kPad, 20, kField, 26);
    show_at(d.subtitle, kPad, 48, kField, 34);
    set_text(d.name_caption, categories ? "CATEGORY NAME" : "NAME");
    show_at(d.name_caption, kPad, 96, kField, 16);
    show_at(static_cast<qt::QWidget*>(d.name), kPad, 116, kField, 32);

    int y = 164;
    if (!categories) {
        set_text(d.category_caption, "CATEGORY");
        show_at(d.category_caption, kPad, y, kField, 16);
        refresh_category();
        show_at(d.category, kPad, y + 20, kField, 32);
        y += 68;

        set_text(d.file_caption, d.current_place ? "OPEN PLACE" : d.mode == Mode::Create ? "PLACE FILE" : "PLACE");
        show_at(d.file_caption, kPad, y, kField, 16);
        set_text(d.file, d.current_place ? d.source_label : d.mode == Mode::Create
            ? (d.picked_path.empty() ? "No place file selected" : file_name(d.picked_path))
            : "Using the saved snapshot");
        show_at(d.file, kPad, y + 20, d.current_place ? kField : kField - 168, 32);
        d.choose->setText(d.mode == Mode::Create ? "Choose place file…" : "Update place file…");
        if (!d.current_place) show_at(d.choose, kPad + kField - 156, y + 20, 156, 32);
        y += 68;

        // Thumbnail: preview on the left; automatic capture by default, or the
        // user's own PNG, on the right.
        constexpr int column = kPad + 176, column_width = kField - 176;
        set_text(d.thumb_caption, "THUMBNAIL");
        show_at(d.thumb_caption, kPad, y, kField, 16);
        d.preview->setGeometry(kPad, y + 20, 160, 90);
        d.preview->show();
        d.capture->setText(d.current_place ? "Use current viewport" : d.mode == Mode::Create ? "Capture automatically" : "Recapture automatically");
        show_at(d.capture, column, y + 20, column_width, 22);
        show_at(d.thumb_choose, column, y + 48, 112, 28);
        d.thumb_auto->setGeometry(column + 118, y + 48, column_width - 118, 28);
        d.hint->setGeometry(column, y + 82, column_width, 34);
        d.hint->show();
        refresh_thumbnail();
        d.capture->setChecked(d.mode == Mode::Create || !d.picked_path.empty());
        y += 136;

        set_text(d.note, d.current_place ? "Custom Templates keeps its own snapshot. The open place keeps its filename and normal save target."
            : "Custom Templates keeps its own snapshot of the place. Your original file is never modified, and every Open starts a fresh copy.");
        show_at(d.note, kPad, y, kField, 34);
        y += 44;
    } else if (d.mode == Mode::CategoryEdit) {
        set_text(d.note, locked() ? "This is the default category, so it can't be renamed or removed."
                                  : "Removing a category moves its templates to the default category.");
        show_at(d.note, kPad, y, kField, 18);
        y += 28;
    }
    d.error->setGeometry(kPad, y, kField, 18);
    y += 26;

    const bool removable = d.mode == Mode::Edit || (d.mode == Mode::CategoryEdit && !locked());
    if (removable) {
        d.remove->setText(d.mode == Mode::Edit ? "Remove Template" : "Remove Category");
        show_at(d.remove, kPad, y, 148, 32);
    }
    if (locked()) {
        // Nothing to save: Close is the only action, and the default.
        show_at(d.cancel, kWidth - kPad - 100, y, 100, 32);
    } else {
        d.save->setText(d.mode == Mode::Create ? "Save to Template" : d.mode == Mode::CategoryNew ? "Create Category" : "Save");
        show_at(d.cancel, kWidth - kPad - 248, y, 100, 32);
        show_at(d.save, kWidth - kPad - 140, y, 140, 32);
    }
    api().button_default(d.save, !locked());
    api().button_default(d.cancel, locked());
    d.window->setFixedSize(kWidth, y + 32 + 20);
}

void apply(const std::string& request) {
    auto& d = ui();
    if (g_stopped.load(std::memory_order_acquire)) return;
    if (d.nested > 0) { d.pending = request; return; }
    if (!build()) {
        post(@{@"type": @"dialog_cancelled", @"error": @"The Qt template dialog is unavailable."});
        return;
    }
    Mode mode = Mode::Create;
    std::string item, name, category_id, thumbnail, source, request_id, source_label;
    std::vector<Choice> categories;
    bool is_protected = false, current_place = false;
    @autoreleasepool {
        NSData* const data = [NSData dataWithBytes:request.data() length:request.size()];
        id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![decoded isKindOfClass:NSDictionary.class]) return;
        NSDictionary* const value = decoded;
        const auto requested = utf8(value[@"mode"]);
        if (requested == "create") mode = Mode::Create;
        else if (requested == "edit") mode = Mode::Edit;
        else if (requested == "category_new") mode = Mode::CategoryNew;
        else if (requested == "category_edit") mode = Mode::CategoryEdit;
        else return;
        item = utf8(value[@"id"]);
        name = utf8(value[@"name"]);
        category_id = utf8(value[@"categoryId"]);
        thumbnail = utf8(value[@"thumbnailPath"]);
        source = utf8(value[@"sourcePath"]);
        request_id = utf8(value[@"requestId"]);
        source_label = utf8(value[@"sourceLabel"]);
        current_place = mode == Mode::Create && !request_id.empty() && [value[@"currentPlace"] isKindOfClass:NSNumber.class] && [value[@"currentPlace"] boolValue];
        is_protected = [value[@"protected"] isKindOfClass:NSNumber.class] && [value[@"protected"] boolValue];
        id list = value[@"categories"];
        if ([list isKindOfClass:NSArray.class])
            for (id entry in list)
                if ([entry isKindOfClass:NSDictionary.class] && !utf8(entry[@"id"]).empty())
                    categories.push_back({utf8(entry[@"id"]), utf8(entry[@"name"])});
    }
    if ((mode == Mode::Edit || mode == Mode::CategoryEdit) && item.empty()) return;

    // An open dialog being replaced counts as cancelled for its old request.
    if (d.open) post(@{@"type": @"dialog_cancelled", @"requestId": ns(d.request_id)});
    d.mode = mode;
    d.id = std::move(item);
    d.categories = std::move(categories);
    d.category_id = choice(category_id) ? category_id : d.categories.empty() ? std::string() : d.categories.front().id;
    d.thumbnail_path = std::move(thumbnail);
    d.source_path = std::move(source);
    d.current_place = current_place;
    d.request_id = std::move(request_id);
    d.source_label = std::move(source_label);
    // A create request may arrive with a path already chosen elsewhere.
    d.picked_path = mode == Mode::Create && place_file(d.source_path) ? d.source_path : std::string();
    d.is_protected = is_protected;
    d.manual_path.clear();
    set_field(d.name, mode == Mode::Create && name.empty() && !d.picked_path.empty() ? file_stem(d.picked_path) : name);
    // A chooser left open for the previous request must not act on this one.
    dismiss_chooser();
    configure();
    d.open = true;
    ++d.session;
    d.window->show();
    api().raise(d.window);
    api().activate(d.window);
    if (locked()) api().set_focus(d.cancel, kOtherFocusReason);
    else {
        api().set_focus(d.name, kOtherFocusReason);
        api().line_edit_select_all(d.name);
    }
}

void stop_now() {
    auto& d = ui();
    if (d.nested > 0) { d.pending_stop = true; return; }
    d.pending.reset();
    if (d.notice) hide(d.notice);
    if (!d.built || !d.open) return;
    // Hide without reject(): shutdown is not a user cancellation.
    dismiss_chooser();
    d.open = false;
    ++d.session;
    hide(d.window);
}

// Runs as a fresh GUI task so a deferred request never executes inside the
// click handler that opened the nested loop.
void flush_pending() {
    auto& d = ui();
    if (d.pending_stop) { d.pending_stop = false; schedule([] { stop_now(); }); return; }
    if (auto request = std::exchange(d.pending, std::nullopt))
        schedule([request = std::move(*request)] { apply(request); });
}
} // namespace

bool ctpl_dialogs_available() {
    try {
        return qt::QApplication::instance() && api().ready;
    } catch (...) {
        return false;
    }
}

void ctpl_dialogs_show(const std::string& json) {
    if (g_stopped.load(std::memory_order_acquire) || json.empty() || !ctpl_dialogs_available()) return;
    try {
        schedule([json] { apply(json); });
    } catch (...) { }
}

void ctpl_dialogs_notice(const std::string& message) {
    if (message.empty() || g_stopped.load(std::memory_order_acquire) || !ctpl_dialogs_available()) return;
    schedule([message] {
        if (g_stopped.load(std::memory_order_acquire)) return;
        auto*& box = ui().notice;
        if (!box) {
            box = qt::QMessageBox::create(nullptr);
            if (!box) return;
            box->setWindowTitle(qt::QString("Custom Templates"));
            box->setTextFormat(qt::TextFormat::PlainText);
            box->setIcon(qt::QMessageBox::Warning);
            box->addButton(qt::QMessageBox::Ok);
        }
        box->setText(qt::QString(message));
        box->show();
        api().raise(box);
        api().activate(box);
    });
}

void ctpl_dialogs_stop() {
    if (g_stopped.exchange(true, std::memory_order_acq_rel)) return;
    try {
        schedule([] { stop_now(); });
    } catch (...) { }
}
