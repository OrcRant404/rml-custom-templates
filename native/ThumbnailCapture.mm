#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <mach-o/dyld.h>
#include <pthread.h>
#include <unistd.h>

#include <RobloxModLoader/memory/foreign_call.hpp>
#include <RobloxModLoader/qt/qapplication.hpp>
#include <RobloxModLoader/qt/qt_module.hpp>
#include <RobloxModLoader/qt/qstring.hpp>
#include <RobloxModLoader/qt/qtimer.hpp>
#include <RobloxModLoader/qt/qwidget.hpp>

#import <AppKit/AppKit.h>

#include "OwnWindowCapture.hpp"
#include "NativeGuiDispatch.hpp"
#include "StartPageUI.hpp"
#include "ThumbnailCapture.hpp"

namespace {
using Clock = std::chrono::steady_clock;
using rml::qt::QWidget;

constexpr auto kPollIntervalMs = 250;
constexpr auto kCaptureTimeout = std::chrono::seconds(30);
constexpr auto kRenderWarmup = std::chrono::milliseconds(1800);
constexpr auto kGeometryWarmup = std::chrono::milliseconds(750);
constexpr auto kDiagnosticLoadWait = std::chrono::milliseconds(2500);
constexpr int kThumbnailWidth = 640;
constexpr int kThumbnailHeight = 360;
constexpr std::uintmax_t kMaximumThumbnailBytes = 8 * 1024 * 1024;
constexpr std::string_view kSupportedQtVersion = "5.15.9";
constexpr int kMaximumMethodsPerObject = 256;
constexpr std::size_t kMaximumMetadataObjects = 512;
constexpr std::size_t kMaximumWidgetMetadataObjects = 384;
constexpr std::size_t kMaximumPlaceManagers = 32;

struct CaptureRequest {
    std::string id;
    std::string request_id;
    std::string output_path;
    std::string place_path;
    std::string expected_token;
    std::string viewport_name;
    std::string viewport_class;
    std::string active_attempt_path;
    std::uint64_t generation = 0;
    Clock::time_point queued_at = Clock::now();
    Clock::time_point identity_since{};
    Clock::time_point identity_geometry_since{};
    Clock::time_point geometry_since{};
    QWidget *candidate = nullptr;
    int identity_window_width = 0;
    int identity_window_height = 0;
    int candidate_width = 0;
    int candidate_height = 0;
    int attempt_width = 0;
    int attempt_height = 0;
    int failed_grabs = 0;
    std::uint64_t active_attempt = 0;
    std::string last_capture_error;
    bool capture_in_flight = false;
    bool diagnostic_written = false;
};

struct CaptureState {
    // The timer and its signal connection intentionally remain resident for
    // Studio's process lifetime. A stopped capture only makes it inert.
    rml::qt::QTimer *timer = nullptr;
    bool timer_running = false;
    std::uint64_t next_attempt_id = 0;
    std::vector<CaptureRequest> requests;
};

CaptureState &capture_state() {
    static auto *value = new CaptureState();
    return *value;
}

std::atomic<std::uint64_t> g_generation{1};
std::mutex g_generation_mutex;

NSString *to_nsstring(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data()
                                   length:value.size()
                                 encoding:NSUTF8StringEncoding];
}

std::string from_nsstring(NSString *value) {
    if (!value) return {};
    const char *utf8 = value.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

std::string json_string(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? std::string(static_cast<const char *>(data.bytes), data.length) : std::string();
}

std::string command_json(NSString *type, const CaptureRequest &request, NSString *message = nil) {
    NSMutableDictionary *command = [@{
        @"type": type,
        @"id": to_nsstring(request.id) ?: @"",
        @"requestId": to_nsstring(request.request_id) ?: @"",
        @"path": to_nsstring(request.output_path) ?: @""
    } mutableCopy];
    if (message) command[@"message"] = message;
    return json_string(command);
}

void post_failure(const CaptureRequest &request, NSString *message) {
    ctpl_post_command(command_json(@"thumbnail_failed", request, message));
}

void post_success(const CaptureRequest &request) {
    ctpl_post_command(command_json(@"thumbnail_captured", request));
}

std::optional<std::string> dictionary_string(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSString.class]) return std::nullopt;
    return from_nsstring(static_cast<NSString *>(value));
}

bool path_is_absolute_readable_file(const std::string &path, const std::string_view extension) {
    @autoreleasepool {
        NSString *ns_path = to_nsstring(path);
        if (!ns_path || !ns_path.isAbsolutePath) return false;
        NSString *actual_extension = ns_path.pathExtension.lowercaseString;
        if (![actual_extension isEqualToString:to_nsstring(std::string(extension))]) return false;
        BOOL directory = NO;
        return [NSFileManager.defaultManager fileExistsAtPath:ns_path isDirectory:&directory] && !directory &&
            [NSFileManager.defaultManager isReadableFileAtPath:ns_path];
    }
}

std::string read_qstring_member(void *function, const void *self) {
    if (!function || !self) return {};
    rml::qt::QString result;
    struct QStringReturnStorage { void *data; } raw{};
    static_assert(sizeof(QStringReturnStorage) == sizeof(rml::qt::QString));
    rml::memory::call_returning_member(function, raw, self);
    std::memcpy(result.storage(), &raw, sizeof(raw));
    return result.to_utf8();
}

std::string read_qstring_member(void *function, const void *self, int argument) {
    if (!function || !self) return {};
    rml::qt::QString result;
    struct QStringReturnStorage { void *data; } raw{};
    static_assert(sizeof(QStringReturnStorage) == sizeof(rml::qt::QString));
    rml::memory::call_returning_member(function, raw, self, argument);
    std::memcpy(result.storage(), &raw, sizeof(raw));
    return result.to_utf8();
}

std::string object_name(const rml::qt::QObject *object) {
    static void *const function = rml::qt::detail::core_export_optional("QObject::objectName() const");
    return read_qstring_member(function, object);
}

std::string window_title(const QWidget *widget) {
    static void *const function = rml::qt::detail::widgets_export_optional("QWidget::windowTitle() const");
    return read_qstring_member(function, widget);
}

std::string window_file_path(const QWidget *widget) {
    static void *const function = rml::qt::detail::widgets_export_optional("QWidget::windowFilePath() const");
    return read_qstring_member(function, widget);
}

QWidget *top_level(QWidget *widget) {
    static const auto function = rml::qt::detail::widgets<void *(*)(const void *)>("QWidget::window() const");
    return function && widget ? static_cast<QWidget *>(function(widget)) : nullptr;
}

bool is_active_window(QWidget *widget) {
    static const auto function = rml::qt::detail::widgets_optional<bool (*)(const void *)>("QWidget::isActiveWindow() const");
    return function && widget && function(widget);
}

bool is_studio_main_window(QWidget *widget) {
    if (!widget) return false;
    return widget->inherits("QMainWindow") ||
        std::string_view(widget->class_name() ?: "") == "RBX::Studio::MainWindow";
}

QWidget *active_window() {
    for (QWidget *widget : rml::qt::QApplication::all_widgets()) {
        if (widget && top_level(widget) == widget && is_active_window(widget)) return widget;
    }
    return nullptr;
}

bool widget_visible_to(QWidget *widget, QWidget *ancestor) {
    static const auto function = rml::qt::detail::widgets<bool (*)(const void *, const void *)>(
        "QWidget::isVisibleTo(QWidget const*) const");
    return function && widget && ancestor && function(widget, ancestor);
}

bool is_minimized(QWidget *widget) {
    static const auto function = rml::qt::detail::widgets<bool (*)(const void *)>("QWidget::isMinimized() const");
    return function && widget && function(widget);
}

std::optional<std::string> current_tab_text(QWidget *widget) {
    if (!widget) return std::nullopt;
    if (widget->inherits("QTabBar")) {
        static const auto current_index = rml::qt::detail::widgets<int (*)(const void *)>("QTabBar::currentIndex() const");
        static void *const tab_text = rml::qt::detail::widgets_export_optional("QTabBar::tabText(int) const");
        if (current_index && tab_text) return read_qstring_member(tab_text, widget, current_index(widget));
    }
    if (widget->inherits("QTabWidget")) {
        static const auto current_index = rml::qt::detail::widgets<int (*)(const void *)>("QTabWidget::currentIndex() const");
        static void *const tab_text = rml::qt::detail::widgets_export_optional("QTabWidget::tabText(int) const");
        if (current_index && tab_text) return read_qstring_member(tab_text, widget, current_index(widget));
    }
    return std::nullopt;
}

// These layouts and symbols match the toolkit's validated Qt 5.15.9 metadata
// inspection path. Metadata reads are skipped unless the loaded Qt runtime,
// shared-null layouts, and QApplication thread all match those checks.
struct QtListData {
    std::atomic<int> ref;
    int alloc;
    int begin;
    int end;
    void *array[1];
};

struct QtArrayData {
    std::atomic<int> ref;
    int size;
    unsigned int alloc : 31;
    unsigned int capacity_reserved : 1;
    std::ptrdiff_t offset;
};

struct QtMetaMethodValue {
    const rml::qt::QMetaObject *meta_object;
    unsigned int handle;
};

static_assert(sizeof(void *) == 8 && sizeof(int) == 4 && sizeof(unsigned int) == 4);
static_assert(sizeof(std::atomic<int>) == 4 && alignof(std::atomic<int>) == 4);
static_assert(std::atomic<int>::is_always_lock_free);
static_assert(std::is_standard_layout_v<QtListData> && sizeof(QtListData) == 24);
static_assert(offsetof(QtListData, begin) == 8 && offsetof(QtListData, end) == 12);
static_assert(offsetof(QtListData, array) == 16);
static_assert(std::is_standard_layout_v<QtArrayData> && sizeof(QtArrayData) == 24);
static_assert(offsetof(QtArrayData, size) == 4 && offsetof(QtArrayData, offset) == 16);
static_assert(std::is_trivially_copyable_v<QtMetaMethodValue>);
static_assert(sizeof(QtMetaMethodValue) == 16 && offsetof(QtMetaMethodValue, handle) == 8);

bool release_qt_ref(std::atomic<int> &ref) {
    const int count = ref.load(std::memory_order_relaxed);
    return count != -1 && (count == 0 || ref.fetch_sub(1, std::memory_order_acq_rel) == 1);
}

using DisposeQtList = void (*)(QtListData *);
using DeallocateQtArray = void (*)(QtArrayData *, std::size_t, std::size_t);

class QtListOwner {
public:
    QtListOwner(QtListData *shared_null, DisposeQtList dispose) : data_(shared_null), dispose_(dispose) {}
    ~QtListOwner() { if (data_ && release_qt_ref(data_->ref)) dispose_(data_); }
    QtListOwner(const QtListOwner &) = delete;
    QtListOwner &operator=(const QtListOwner &) = delete;
    bool valid() const { return data_ && data_->alloc >= 0 && data_->begin >= 0 && data_->end >= data_->begin && data_->end <= data_->alloc; }
    int size() const { return data_->end - data_->begin; }
    void *at(int index) const { return data_->array[data_->begin + index]; }
    QtListData *data() { return data_; }
    QtListData **slot() { return &data_; }
private:
    QtListData *data_;
    DisposeQtList dispose_;
};

class QtArrayOwner {
public:
    QtArrayOwner(QtArrayData *shared_null, DeallocateQtArray deallocate, std::size_t element_size)
        : data_(shared_null), deallocate_(deallocate), element_size_(element_size) {}
    ~QtArrayOwner() {
        if (data_ && release_qt_ref(data_->ref)) deallocate_(data_, element_size_, alignof(QtArrayData));
    }
    QtArrayOwner(const QtArrayOwner &) = delete;
    QtArrayOwner &operator=(const QtArrayOwner &) = delete;
    QtArrayData *data() { return data_; }
    void adopt(QtArrayData *data) { data_ = data; }
    QtArrayData **slot() { return &data_; }
private:
    QtArrayData *data_;
    DeallocateQtArray deallocate_;
    std::size_t element_size_;
};

class QtMetadataApi {
public:
    QtMetadataApi() {
        if (!pthread_main_np()) { skip_reason_ = "not_process_main_thread"; return; }

        std::uint32_t path_capacity = 1024;
        std::vector<char> executable(path_capacity);
        if (_NSGetExecutablePath(executable.data(), &path_capacity) != 0) {
            executable.resize(path_capacity);
            if (_NSGetExecutablePath(executable.data(), &path_capacity) != 0) {
                skip_reason_ = "executable_path_unavailable";
                return;
            }
        }
        const auto frameworks = std::filesystem::path(executable.data()).parent_path().parent_path() / "Frameworks";
        const auto core_path = frameworks / "QtCore.framework/Versions/5/QtCore";
        core_ = dlopen(core_path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        if (!core_) { skip_reason_ = "bundled_qtcore_not_loaded"; return; }

        if (!resolve(qversion_, core_, "qVersion")) return;
        const char *version = qversion_();
        version_ = version ? version : "";
        if (version_ != kSupportedQtVersion) { skip_reason_ = "unsupported_qt_version"; return; }

        if (!resolve(list_shared_null_, core_, "_ZN9QListData11shared_nullE") ||
            !resolve(array_shared_null_, core_, "_ZN10QArrayData11shared_nullE") ||
            !resolve(dispose_list_, core_, "_ZN9QListData7disposeEPNS_4DataE") ||
            !resolve(deallocate_array_, core_, "_ZN10QArrayData10deallocateEPS_mm") ||
            !resolve(application_, core_, "_ZN16QCoreApplication4selfE") ||
            !resolve(current_thread_, core_, "_ZN7QThread13currentThreadEv") ||
            !resolve(object_thread_, core_, "_ZNK7QObject6threadEv") ||
            !resolve(object_meta_, core_, "_ZN7QObject16staticMetaObjectE") ||
            !resolve(find_children_, core_, "_Z23qt_qFindChildren_helperPK7QObjectRK7QStringRK11QMetaObjectP5QListIPvE6QFlagsIN2Qt15FindChildOptionEE") ||
            !resolve(method_count_, core_, "_ZNK11QMetaObject11methodCountEv") ||
            !resolve(method_offset_, core_, "_ZNK11QMetaObject12methodOffsetEv") ||
            !resolve(method_, core_, "_ZNK11QMetaObject6methodEi") ||
            !resolve(method_signature_, core_, "_ZNK11QMetaMethod15methodSignatureEv") ||
            !resolve(method_type_, core_, "_ZNK11QMetaMethod10methodTypeEv") ||
            !resolve(parameter_count_, core_, "_ZNK11QMetaMethod14parameterCountEv") ||
            !resolve(type_name_, core_, "_ZNK11QMetaMethod8typeNameEv")) return;

        if (!*application_) { skip_reason_ = "no_qapplication"; return; }
        if (current_thread_() != object_thread_(*application_)) {
            skip_reason_ = "not_qapplication_thread";
            return;
        }
        if (list_shared_null_->ref.load(std::memory_order_relaxed) != -1 || list_shared_null_->alloc != 0 ||
            list_shared_null_->begin != 0 || list_shared_null_->end != 0 ||
            array_shared_null_->ref.load(std::memory_order_relaxed) != -1 || array_shared_null_->size != 0) {
            skip_reason_ = "qt_shared_null_layout_mismatch";
            return;
        }

        const auto widgets_path = frameworks / "QtWidgets.framework/Versions/5/QtWidgets";
        widgets_ = dlopen(widgets_path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        if (!widgets_) { skip_reason_ = "bundled_qtwidgets_not_loaded"; return; }
    }

    ~QtMetadataApi() {
        if (widgets_) dlclose(widgets_);
        if (core_) dlclose(core_);
    }
    QtMetadataApi(const QtMetadataApi &) = delete;
    QtMetadataApi &operator=(const QtMetadataApi &) = delete;

    bool enabled() const { return skip_reason_.empty(); }
    const std::string &version() const { return version_; }
    const std::string &skip_reason() const { return skip_reason_; }
    QtListData *list_shared_null() const { return list_shared_null_; }
    QtArrayData *array_shared_null() const { return array_shared_null_; }
    DisposeQtList dispose_list() const { return dispose_list_; }
    DeallocateQtArray deallocate_array() const { return deallocate_array_; }
    const rml::qt::QMetaObject *object_meta() const { return object_meta_; }
    using FindChildren = void (*)(const rml::qt::QObject *, const void *, const rml::qt::QMetaObject *, void *, int);
    FindChildren find_children() const { return find_children_; }

    int method_count(const rml::qt::QMetaObject *meta) const { return method_count_(meta); }
    int method_offset(const rml::qt::QMetaObject *meta) const { return method_offset_(meta); }
    QtMetaMethodValue method(const rml::qt::QMetaObject *meta, int index) const { return method_(meta, index); }
    int method_type(const QtMetaMethodValue *method_value) const { return method_type_(method_value); }
    int parameter_count(const QtMetaMethodValue *method_value) const { return parameter_count_(method_value); }
    const char *type_name(const QtMetaMethodValue *method_value) const { return type_name_(method_value); }

    void *method_signature() const { return method_signature_; }

private:
    template<typename T>
    bool resolve(T &destination, void *image, const char *symbol) {
        destination = reinterpret_cast<T>(dlsym(image, symbol));
        if (!destination) skip_reason_ = std::string("missing_symbol:") + symbol;
        return destination != nullptr;
    }

    void *core_ = nullptr;
    void *widgets_ = nullptr;
    std::string version_;
    std::string skip_reason_;
    QtListData *list_shared_null_ = nullptr;
    QtArrayData *array_shared_null_ = nullptr;
    DisposeQtList dispose_list_ = nullptr;
    DeallocateQtArray deallocate_array_ = nullptr;
    rml::qt::QObject *const *application_ = nullptr;
    const rml::qt::QMetaObject *object_meta_ = nullptr;
    const char *(*qversion_)() = nullptr;
    void *(*current_thread_)() = nullptr;
    void *(*object_thread_)(const rml::qt::QObject *) = nullptr;
    void (*find_children_)(const rml::qt::QObject *, const void *, const rml::qt::QMetaObject *, void *, int) = nullptr;
    int (*method_count_)(const rml::qt::QMetaObject *) = nullptr;
    int (*method_offset_)(const rml::qt::QMetaObject *) = nullptr;
    QtMetaMethodValue (*method_)(const rml::qt::QMetaObject *, int) = nullptr;
    int (*method_type_)(const QtMetaMethodValue *) = nullptr;
    int (*parameter_count_)(const QtMetaMethodValue *) = nullptr;
    const char *(*type_name_)(const QtMetaMethodValue *) = nullptr;
    void *method_signature_ = nullptr;
};

NSString *qt_method_kind(int kind) {
    switch (kind) {
    case 0: return @"method";
    case 1: return @"signal";
    case 2: return @"slot";
    case 3: return @"constructor";
    default: return @"unknown";
    }
}

NSDictionary *qt_metadata_description(const rml::qt::QObject *object, const QtMetadataApi &api) {
    const rml::qt::QMetaObject *meta = object ? object->metaObject() : nullptr;
    if (!meta) return @{ @"error": @"no_metaobject" };

    const int total = api.method_count(meta);
    const int offset = api.method_offset(meta);
    if (total < 0 || offset < 0 || offset > total) return @{ @"error": @"invalid_method_range" };

    const int start = std::max(0, total - kMaximumMethodsPerObject);
    NSMutableArray *methods = [NSMutableArray array];
    for (int index = start; index < total; ++index) {
        const QtMetaMethodValue method_value = api.method(meta, index);
        if (!method_value.meta_object) continue;

        QtArrayOwner signature_data(api.array_shared_null(), api.deallocate_array(), sizeof(char));
        QtArrayData *raw_signature = api.array_shared_null();
        rml::memory::call_returning_member(api.method_signature(), raw_signature, &method_value);
        signature_data.adopt(raw_signature);
        QtArrayData *array = signature_data.data();
        if (!array || array->size < 0) continue;
        const std::size_t length = std::min<std::size_t>(static_cast<std::size_t>(array->size), 512);
        const char *bytes = reinterpret_cast<const char *>(array) + array->offset;
        std::string signature(bytes, length);
        for (char &value : signature) {
            const unsigned char byte = static_cast<unsigned char>(value);
            if (byte < 32 || byte == 127) value = '?';
        }

        const int kind = api.method_type(&method_value);
        if (kind < 0 || kind > 3) continue;
        const char *return_type = api.type_name(&method_value);
        NSString *signature_text = to_nsstring(signature) ?: @"";
        [methods addObject:@{
            @"index": @(index),
            @"kind": qt_method_kind(kind),
            @"name": [signature_text componentsSeparatedByString:@"("].firstObject ?: @"",
            @"signature": signature_text,
            @"parameters": @(api.parameter_count(&method_value)),
            @"returnType": return_type ? [NSString stringWithUTF8String:return_type] ?: @"" : @"",
            @"inherited": @(index < offset),
            @"signatureTruncated": @(array->size > 512)
        }];
    }

    return @{
        @"methodCount": @(total),
        @"methodOffset": @(offset),
        @"methodStart": @(start),
        @"truncated": @(start > 0),
        @"methods": methods
    };
}

bool is_place_manager(const std::string &class_name) {
    return class_name.find("IPlaceManager") != std::string::npos ||
        class_name.find("PlaceManager") != std::string::npos;
}

NSArray *place_manager_diagnostics(const std::vector<QWidget *> &main_windows, const QtMetadataApi &api,
                                   std::size_t &metadata_objects, NSString **scan_error) {
    NSMutableArray *managers = [NSMutableArray array];
    if (!api.enabled()) {
        if (scan_error) *scan_error = to_nsstring(api.skip_reason()) ?: @"Qt metadata access is unavailable.";
        return managers;
    }

    std::unordered_set<const rml::qt::QObject *> seen;
    auto append_manager = [&](const rml::qt::QObject *object, QWidget *main_window) {
        if (!object || managers.count >= kMaximumPlaceManagers || metadata_objects >= kMaximumMetadataObjects ||
            !seen.insert(object).second) return;
        const std::string class_name = object->class_name() ? object->class_name() : "";
        if (!is_place_manager(class_name)) return;
        const std::string name = object_name(object);
        const std::string title = main_window ? window_title(main_window) : "";
        [managers addObject:@{
            @"address": [NSString stringWithFormat:@"%p", object],
            @"class": to_nsstring(class_name) ?: @"",
            @"name": to_nsstring(name) ?: @"",
            @"mainWindowTitle": to_nsstring(title) ?: @"",
            @"qtMetadata": qt_metadata_description(object, api)
        }];
        ++metadata_objects;
    };

    for (QWidget *main_window : main_windows) {
        if (!main_window || managers.count >= kMaximumPlaceManagers || metadata_objects >= kMaximumMetadataObjects) break;
        append_manager(main_window, main_window);

        QtListOwner descendants(api.list_shared_null(), api.dispose_list());
        QtArrayOwner null_name(api.array_shared_null(), api.deallocate_array(), sizeof(char16_t));
        api.find_children()(main_window, null_name.slot(), api.object_meta(), descendants.slot(), 1);
        if (!descendants.valid()) {
            if (scan_error && !*scan_error) *scan_error = @"Qt returned an invalid QObject descendant list.";
            continue;
        }
        for (int index = 0; index < descendants.size(); ++index) {
            auto *object = static_cast<const rml::qt::QObject *>(descendants.at(index));
            const std::string class_name = object && object->class_name() ? object->class_name() : "";
            if (is_place_manager(class_name)) append_manager(object, main_window);
            if (managers.count >= kMaximumPlaceManagers || metadata_objects >= kMaximumMetadataObjects) break;
        }
    }
    return managers;
}

struct QObjectHierarchy {
    std::unordered_map<const rml::qt::QObject *, const rml::qt::QObject *> parents;
    std::string status;
    bool truncated = false;
};

QObjectHierarchy collect_qobject_hierarchy(const std::vector<QWidget *> &widgets, const QtMetadataApi &api) {
    constexpr std::size_t kMaximumObjects = 8192;
    QObjectHierarchy hierarchy;
    if (!api.enabled()) {
        hierarchy.status = "skipped:" + api.skip_reason();
        return hierarchy;
    }

    std::unordered_set<const rml::qt::QObject *> seen;
    std::unordered_set<QWidget *> seen_roots;
    std::vector<QWidget *> roots;
    std::vector<const rml::qt::QObject *> pending;
    for (QWidget *widget : widgets) {
        if (!widget) continue;
        QWidget *root = top_level(widget);
        if (root == widget && seen_roots.insert(root).second) roots.push_back(root);
    }
    std::stable_sort(roots.begin(), roots.end(), [](QWidget *left, QWidget *right) {
        const bool left_active_main = is_studio_main_window(left) && is_active_window(left);
        const bool right_active_main = is_studio_main_window(right) && is_active_window(right);
        if (left_active_main != right_active_main) return left_active_main;
        const bool left_main = is_studio_main_window(left);
        const bool right_main = is_studio_main_window(right);
        return left_main && !right_main;
    });
    for (QWidget *root : roots) {
        if (!seen.insert(root).second) continue;
        hierarchy.parents.emplace(root, nullptr);
        pending.push_back(root);
    }

    std::size_t cursor = 0;
    while (cursor < pending.size()) {
        if (pending.size() >= kMaximumObjects) {
            hierarchy.truncated = true;
            break;
        }
        const rml::qt::QObject *parent = pending[cursor++];
        QtListOwner children(api.list_shared_null(), api.dispose_list());
        QtArrayOwner null_name(api.array_shared_null(), api.deallocate_array(), sizeof(char16_t));
        // Qt::FindChildrenRecursively is bit 0. Zero requests direct children;
        // walking each returned child preserves exact QObject parent links.
        api.find_children()(parent, null_name.slot(), api.object_meta(), children.slot(), 0);
        if (!children.valid()) {
            hierarchy.status = "error:invalid_direct_child_list";
            return hierarchy;
        }
        for (int index = 0; index < children.size(); ++index) {
            auto *child = static_cast<const rml::qt::QObject *>(children.at(index));
            if (!child || !seen.insert(child).second) continue;
            hierarchy.parents.emplace(child, parent);
            pending.push_back(child);
            if (pending.size() >= kMaximumObjects) {
                hierarchy.truncated = true;
                break;
            }
        }
        if (hierarchy.truncated) break;
    }
    hierarchy.status = hierarchy.truncated ? "truncated_at_8192_objects" : "complete";
    return hierarchy;
}

bool document_matches(const CaptureRequest &request, QWidget **matched_window = nullptr) {
    const std::string expected_path = std::filesystem::path(request.place_path).lexically_normal().string();
    const auto widgets = rml::qt::QApplication::all_widgets();
    QWidget *match = nullptr;
    for (QWidget *candidate : widgets) {
        if (!candidate || top_level(candidate) != candidate || !is_studio_main_window(candidate) ||
            is_minimized(candidate)) continue;

        const std::string file_path = window_file_path(candidate);
        bool identity_matches = false;
        if (!file_path.empty()) {
            identity_matches = std::filesystem::path(file_path).lexically_normal().string() == expected_path;
        } else {
            const std::string title = window_title(candidate);
            const std::string title_prefix = expected_path + " - ";
            identity_matches = title == expected_path || title.starts_with(title_prefix);
        }
        if (!identity_matches) continue;
        if (match) return false;
        match = candidate;
    }

    if (!match) return false;
    if (matched_window) *matched_window = match;
    return true;
}

bool validate_owned_capture(const std::string &path, std::string *error);

NSDictionary *widget_description(QWidget *widget, QWidget *active, const QtMetadataApi &metadata,
                                const QObjectHierarchy &hierarchy, std::size_t &metadata_objects) {
    if (!widget) return @{};
    QWidget *window = top_level(widget);
    const auto parent_entry = hierarchy.parents.find(widget);
    const rml::qt::QObject *parent = parent_entry == hierarchy.parents.end() ? nullptr : parent_entry->second;
    NSMutableArray *parent_chain = [NSMutableArray array];
    const rml::qt::QObject *ancestor = parent;
    for (int depth = 0; ancestor && depth < 32; ++depth) {
        NSString *class_name = [NSString stringWithUTF8String:ancestor->class_name() ?: ""];
        NSString *name = to_nsstring(object_name(ancestor)) ?: @"";
        [parent_chain addObject:@{ @"class": class_name ?: @"", @"name": name }];
        const auto next = hierarchy.parents.find(ancestor);
        ancestor = next == hierarchy.parents.end() ? nullptr : next->second;
    }

    const bool window_active = window && is_active_window(window);
    const bool visible_to_window = window_active && !is_minimized(window) &&
        (widget == window || widget_visible_to(widget, window));

    NSMutableDictionary *item = [@{
        @"address": [NSString stringWithFormat:@"%p", widget],
        @"parent": parent ? [NSString stringWithFormat:@"%p", parent] : NSNull.null,
        @"parentLookup": parent_entry == hierarchy.parents.end() ? @"not_found" : @"qobject_children",
        @"window": [NSString stringWithFormat:@"%p", window],
        @"class": [NSString stringWithUTF8String:widget->class_name() ?: ""],
        @"name": to_nsstring(object_name(widget)) ?: @"",
        @"width": @(widget->width()),
        @"height": @(widget->height()),
        @"visibleToWindow": @(visible_to_window),
        @"windowActive": @(window_active),
        @"windowMinimized": @(window && is_minimized(window)),
        @"activeWindow": @(window && window == active),
        @"parentChain": parent_chain
    } mutableCopy];

    if (widget->inherits("QMainWindow") || std::string_view(widget->class_name() ?: "") == "RBX::Studio::MainWindow") {
        item[@"windowTitle"] = to_nsstring(window_title(widget)) ?: @"";
        item[@"windowFilePath"] = to_nsstring(window_file_path(widget)) ?: @"";
    }
    if (auto tab = current_tab_text(widget)) item[@"currentTab"] = to_nsstring(*tab) ?: @"";
    if (metadata.enabled() && metadata_objects < kMaximumWidgetMetadataObjects && visible_to_window &&
        widget->width() >= 320 && widget->height() >= 180) {
        item[@"qtMetadata"] = qt_metadata_description(widget, metadata);
        ++metadata_objects;
    }
    return item;
}

bool write_widget_dump(const std::string &path) {
    @autoreleasepool {
        const auto widgets = rml::qt::QApplication::all_widgets();
        QtMetadataApi metadata;
        const QObjectHierarchy hierarchy = collect_qobject_hierarchy(widgets, metadata);
        QWidget *active = active_window();
        QWidget *active_root = top_level(active);
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:widgets.size()];
        std::vector<QWidget *> main_windows;
        std::size_t metadata_objects = 0;
        for (QWidget *widget : widgets) {
            if (items.count >= 10000) break;
            [items addObject:widget_description(widget, active_root, metadata, hierarchy, metadata_objects)];
            if (is_studio_main_window(widget)) main_windows.push_back(widget);
        }
        NSString *manager_scan_error = nil;
        NSArray *place_managers = place_manager_diagnostics(main_windows, metadata, metadata_objects, &manager_scan_error);
        NSDictionary *dump = @{
            @"activeWindow": [NSString stringWithFormat:@"%p", active],
            @"activeRoot": [NSString stringWithFormat:@"%p", active_root],
            @"activeClass": active ? [NSString stringWithUTF8String:active->class_name() ?: ""] : @"",
            @"activeTitle": to_nsstring(window_title(active_root)) ?: @"",
            @"qtMetadataVersion": to_nsstring(metadata.version()) ?: @"",
            @"qtMetadataSkipReason": to_nsstring(metadata.skip_reason()) ?: @"",
            @"qtMetadataObjects": @(metadata_objects),
            @"qtObjectHierarchyStatus": to_nsstring(hierarchy.status) ?: @"",
            @"qtObjectHierarchyCount": @(hierarchy.parents.size()),
            @"placeManagerScanError": manager_scan_error ?: @"",
            @"placeManagers": place_managers,
            @"widgets": items
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:dump options:NSJSONWritingPrettyPrinted error:nil];
        if (!data) return false;
        const char *file = path.c_str();
        std::ofstream output(file, std::ios::binary | std::ios::trunc);
        if (!output) return false;
        output.write(static_cast<const char *>(data.bytes), static_cast<std::streamsize>(data.length));
        return output.good();
    }
}

std::string diagnostic_path() {
    @autoreleasepool {
        NSString *base = NSTemporaryDirectory();
        NSString *path = [base stringByAppendingPathComponent:@"custom-templates-qt-widget-hierarchy.json"];
        return from_nsstring(path);
    }
}

bool write_png_is_nonblank(const std::string &path) {
    @autoreleasepool {
        NSString *ns_path = to_nsstring(path);
        NSImageRep *representation = ns_path ? [NSBitmapImageRep imageRepWithContentsOfFile:ns_path] : nil;
        if (![representation isKindOfClass:NSBitmapImageRep.class]) return false;
        NSBitmapImageRep *bitmap = static_cast<NSBitmapImageRep *>(representation);
        if (bitmap.pixelsWide < 8 || bitmap.pixelsHigh < 8 || bitmap.bitsPerPixel < 24) return false;
        unsigned char *pixels = bitmap.bitmapData;
        if (!pixels) return false;
        const std::size_t bytes_per_pixel = static_cast<std::size_t>(bitmap.bitsPerPixel / 8);
        const std::size_t row_bytes = static_cast<std::size_t>(bitmap.bytesPerRow);
        std::array<std::array<unsigned char, 3>, 16> samples{};
        std::size_t out = 0;
        for (int y = 0; y < 4; ++y) {
            const int py = (y * (bitmap.pixelsHigh - 1)) / 3;
            for (int x = 0; x < 4; ++x) {
                const int px = (x * (bitmap.pixelsWide - 1)) / 3;
                const unsigned char *pixel = pixels + static_cast<std::size_t>(py) * row_bytes +
                    static_cast<std::size_t>(px) * bytes_per_pixel;
                samples[out++] = {pixel[0], pixel[1], pixel[2]};
            }
        }
        return std::any_of(samples.begin() + 1, samples.end(), [&](const auto &sample) {
            return sample != samples.front();
        });
    }
}

std::optional<std::string> locate_viewport(const CaptureRequest &request, QWidget *window, QWidget **result) {
    if (request.viewport_name.empty()) return "viewportName is required; inspect the Qt widget dump first.";
    const auto widgets = rml::qt::QApplication::all_widgets();
    std::vector<QWidget *> matches;
    for (QWidget *widget : widgets) {
        if (!widget || top_level(widget) != window || object_name(widget) != request.viewport_name) continue;
        if (!request.viewport_class.empty() && request.viewport_class != widget->class_name() &&
            !widget->inherits(request.viewport_class.c_str())) continue;
        if (widget == window || !widget_visible_to(widget, window)) continue;
        if (widget->width() < 320 || widget->height() < 180) continue;
        matches.push_back(widget);
    }
    if (matches.size() != 1) {
        return matches.empty() ? "The named viewport is not visible yet." : "The viewport selector matches multiple widgets.";
    }
    *result = matches.front();
    return std::nullopt;
}

std::optional<std::uintptr_t> native_view_id(QWidget *widget) {
    static const auto function = rml::qt::detail::widgets_optional<std::uintptr_t (*)(const void *)>(
        "QWidget::winId() const");
    if (!function || !widget) return std::nullopt;
    const std::uintptr_t value = function(widget);
    return value == 0 ? std::nullopt : std::optional<std::uintptr_t>(value);
}

std::string capture_attempt_path(const std::string &output_path, std::uint64_t attempt_id) {
    const std::filesystem::path final_path(output_path);
    const std::string filename = final_path.stem().string() + ".capture-" +
        std::to_string(attempt_id) + final_path.extension().string();
    return (final_path.parent_path() / filename).string();
}

void remove_capture_path(const std::string &path) {
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
}

void complete_owned_capture(std::string request_id, std::string output_path, std::string attempt_path,
                            std::uint64_t generation, std::uint64_t attempt_id,
                            std::uintptr_t requested_view_id, int requested_width, int requested_height,
                            bool capture_succeeded, std::string capture_error) {
    auto &state = capture_state();
    const auto found = std::find_if(state.requests.begin(), state.requests.end(), [&](const CaptureRequest &request) {
        return request.request_id == request_id && request.generation == generation &&
            request.active_attempt == attempt_id && request.capture_in_flight;
    });
    if (found == state.requests.end() || generation != g_generation.load(std::memory_order_acquire)) {
        remove_capture_path(attempt_path);
        return;
    }

    CaptureRequest &request = *found;
    request.capture_in_flight = false;
    request.active_attempt = 0;
    request.active_attempt_path.clear();
    request.last_capture_error = std::move(capture_error);
    auto reject_capture = [&](std::string reason, bool document_changed) {
        remove_capture_path(attempt_path);
        ++request.failed_grabs;
        request.last_capture_error = std::move(reason);
        request.candidate = nullptr;
        request.geometry_since = {};
        if (document_changed) {
            request.identity_since = {};
            request.identity_geometry_since = {};
        }
    };

    if (Clock::now() - request.queued_at > kCaptureTimeout) {
        reject_capture("The owned-window capture completed after the request timed out.", false);
        return;
    }

    QWidget *window = nullptr;
    QWidget *viewport = nullptr;
    if (!document_matches(request, &window) || !window ||
        locate_viewport(request, window, &viewport).has_value() || !viewport) {
        reject_capture("The active place or selected viewport changed while its capture was pending.", true);
        return;
    }

    const auto current_view_id = native_view_id(viewport);
    if (!current_view_id || *current_view_id != requested_view_id ||
        viewport->width() != requested_width || viewport->height() != requested_height) {
        reject_capture("The viewport changed while its capture was pending.", false);
        return;
    }

    std::string validation_error;
    if (!capture_succeeded || !validate_owned_capture(attempt_path, &validation_error)) {
        if (validation_error.empty()) validation_error = request.last_capture_error;
        if (validation_error.empty()) validation_error = "The owned-window capture failed.";
        reject_capture(validation_error, false);
        return;
    }

    // Serialize the final generation check and publish with cancellation. If a
    // cancel wins this lock first, this completion only removes its staged file.
    std::lock_guard generation_guard(g_generation_mutex);
    if (generation != g_generation.load(std::memory_order_acquire)) {
        remove_capture_path(attempt_path);
        return;
    }
    std::error_code rename_error;
    std::filesystem::rename(attempt_path, output_path, rename_error);
    if (rename_error) {
        reject_capture("The validated viewport capture could not be moved into the template thumbnail path.", false);
        return;
    }
    post_success(request);
    state.requests.erase(found);
}

bool validate_owned_capture(const std::string &path, std::string *error = nullptr) {
    auto fail = [&](const char *message) {
        if (error) *error = message;
        return false;
    };
    std::ifstream input(path, std::ios::binary);
    std::array<unsigned char, 8> signature{};
    input.read(reinterpret_cast<char *>(signature.data()), signature.size());
    constexpr std::array<unsigned char, 8> kPng{137, 80, 78, 71, 13, 10, 26, 10};
    if (!input || signature != kPng) return fail("The owned-window capture did not produce a readable PNG.");
    std::error_code size_error;
    const auto output_size = std::filesystem::file_size(path, size_error);
    if (size_error || output_size == 0 || output_size > kMaximumThumbnailBytes)
        return fail("The captured thumbnail is empty or exceeds the size limit.");

    @autoreleasepool {
        NSString *ns_path = to_nsstring(path);
        NSImageRep *representation = ns_path ? [NSBitmapImageRep imageRepWithContentsOfFile:ns_path] : nil;
        if (![representation isKindOfClass:NSBitmapImageRep.class])
            return fail("The captured PNG could not be decoded.");
        NSBitmapImageRep *bitmap = static_cast<NSBitmapImageRep *>(representation);
        if (bitmap.pixelsWide != kThumbnailWidth || bitmap.pixelsHigh != kThumbnailHeight ||
            bitmap.bitsPerPixel < 24 || !bitmap.bitmapData)
            return fail("The captured PNG has unexpected dimensions or pixel data.");
        if (!write_png_is_nonblank(path)) return fail("The captured viewport image was blank.");
    }
    return true;
}

void fail_and_remove(CaptureState &state, std::size_t index, NSString *reason) {
    CaptureRequest request = std::move(state.requests[index]);
    remove_capture_path(request.output_path);
    remove_capture_path(request.active_attempt_path);
    post_failure(request, reason);
    state.requests.erase(state.requests.begin() + static_cast<std::ptrdiff_t>(index));
}

void process_requests() {
    auto &state = capture_state();
    const auto now = Clock::now();
    for (std::size_t index = 0; index < state.requests.size();) {
        CaptureRequest &request = state.requests[index];
        if (request.generation != g_generation.load(std::memory_order_acquire)) {
            state.requests.erase(state.requests.begin() + static_cast<std::ptrdiff_t>(index));
            continue;
        }
        if (now - request.queued_at > kCaptureTimeout) {
            if (!request.diagnostic_written) write_widget_dump(diagnostic_path());
            NSString *reason = request.last_capture_error.empty()
                ? (request.failed_grabs > 0
                    ? @"Studio did not produce a usable viewport capture after retries; the previous thumbnail was kept."
                    : @"Studio did not expose the requested place and viewport before timeout.")
                : to_nsstring(request.last_capture_error);
            fail_and_remove(state, index, reason ?: @"Studio did not produce a usable viewport capture.");
            continue;
        }

        QWidget *window = nullptr;
        if (!document_matches(request, &window)) {
            request.identity_since = {};
            request.identity_geometry_since = {};
            request.candidate = nullptr;
            request.geometry_since = {};
            ++index;
            continue;
        }
        if (request.identity_since == Clock::time_point{}) {
            request.identity_since = now;
            request.identity_window_width = window->width();
            request.identity_window_height = window->height();
            request.identity_geometry_since = now;
            if (!request.viewport_name.empty()) {
                write_widget_dump(diagnostic_path());
                request.diagnostic_written = true;
            }
        } else if (window->width() != request.identity_window_width ||
                   window->height() != request.identity_window_height) {
            request.identity_window_width = window->width();
            request.identity_window_height = window->height();
            request.identity_geometry_since = now;
        }

        if (request.capture_in_flight) {
            ++index;
            continue;
        }

        if (request.viewport_name.empty()) {
            if (now - request.identity_since < kDiagnosticLoadWait ||
                now - request.identity_geometry_since < kGeometryWarmup) {
                ++index;
                continue;
            }
            write_widget_dump(diagnostic_path());
            request.diagnostic_written = true;
            fail_and_remove(state, index, @"Viewport selector is missing. The settled Qt widget tree was written to the temporary diagnostic file.");
            continue;
        }

        QWidget *viewport = nullptr;
        if (auto error = locate_viewport(request, window, &viewport)) {
            request.candidate = nullptr;
            request.geometry_since = {};
            ++index;
            continue;
        }
        const int width = viewport->width();
        const int height = viewport->height();
        if (viewport != request.candidate || width != request.candidate_width || height != request.candidate_height) {
            request.candidate = viewport;
            request.candidate_width = width;
            request.candidate_height = height;
            request.geometry_since = now;
            ++index;
            continue;
        }
        if (now - request.identity_since < kRenderWarmup || now - request.geometry_since < kGeometryWarmup) {
            ++index;
            continue;
        }

        // Recheck document identity immediately before starting the asynchronous
        // own-window capture. The completion re-discovers the viewport and repeats
        // both identity and native-view checks before it can publish success.
        QWidget *verified_window = nullptr;
        if (!document_matches(request, &verified_window) || verified_window != window) {
            request.identity_since = {};
            request.identity_geometry_since = {};
            request.candidate = nullptr;
            request.geometry_since = {};
            ++index;
            continue;
        }
        const auto view_id = native_view_id(viewport);
        if (!view_id) {
            request.last_capture_error = "Qt could not provide the viewport's native window identifier.";
            ++request.failed_grabs;
            request.candidate = nullptr;
            request.geometry_since = now;
            ++index;
            continue;
        }

        remove_capture_path(request.output_path);
        const std::string request_id = request.request_id;
        const std::string output_path = request.output_path;
        const std::uint64_t generation = request.generation;
        const std::uint64_t attempt_id = ++state.next_attempt_id;
        const std::string attempt_path = capture_attempt_path(output_path, attempt_id);
        const std::uintptr_t requested_view_id = *view_id;
        request.active_attempt = attempt_id;
        request.active_attempt_path = attempt_path;
        request.attempt_width = width;
        request.attempt_height = height;
        request.capture_in_flight = true;
        request.candidate = nullptr;

        const bool accepted = ctpl_capture_owned_view(requested_view_id, attempt_path,
            [request_id, output_path, attempt_path, generation, attempt_id, requested_view_id, width, height]
            (bool succeeded, std::string error) mutable {
                complete_owned_capture(std::move(request_id), std::move(output_path), std::move(attempt_path),
                    generation, attempt_id, requested_view_id, width, height, succeeded, std::move(error));
            });
        if (!accepted) {
            const auto still_pending = std::find_if(state.requests.begin(), state.requests.end(),
                [&](const CaptureRequest &pending) {
                    return pending.request_id == request_id && pending.generation == generation &&
                        pending.active_attempt == attempt_id && pending.capture_in_flight;
                });
            if (still_pending != state.requests.end()) {
                still_pending->capture_in_flight = false;
                still_pending->active_attempt = 0;
                still_pending->active_attempt_path.clear();
                still_pending->last_capture_error = "The owned-window capture service rejected the request.";
                ++still_pending->failed_grabs;
                still_pending->geometry_since = now;
            }
            remove_capture_path(attempt_path);
        }
        ++index;
    }

    if (state.requests.empty() && state.timer_running && state.timer) {
        state.timer->stop();
        state.timer_running = false;
    }
}

void ensure_timer() {
    auto &state = capture_state();
    if (!state.timer) {
        state.timer = rml::qt::QTimer::create(nullptr);
        if (!state.timer) return;
        state.timer->setInterval(kPollIntervalMs);
        state.timer->setSingleShot(false);
        state.timer->on_timeout([] {
            try { process_requests(); } catch (...) {}
        });
    }
    if (!state.timer_running && !state.requests.empty()) {
        state.timer->start();
        state.timer_running = true;
    }
}

std::optional<CaptureRequest> parse_request(const std::string &json) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:json.data() length:json.size()];
        id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![value isKindOfClass:NSDictionary.class]) return std::nullopt;
        NSDictionary *dictionary = static_cast<NSDictionary *>(value);
        auto id_value = dictionary_string(dictionary, @"id");
        auto request_id = dictionary_string(dictionary, @"requestId");
        auto output_path = dictionary_string(dictionary, @"path");
        auto place_path = dictionary_string(dictionary, @"placePath");
        if (!id_value || !request_id || !output_path || !place_path || id_value->empty() || request_id->empty())
            return std::nullopt;

        CaptureRequest request;
        request.id = std::move(*id_value);
        request.request_id = std::move(*request_id);
        request.output_path = std::move(*output_path);
        request.place_path = std::move(*place_path);
        request.expected_token = "CTPL-" + request.request_id;
        if (auto viewport_name = dictionary_string(dictionary, @"viewportName"))
            request.viewport_name = std::move(*viewport_name);
        if (auto viewport_class = dictionary_string(dictionary, @"viewportClass"))
            request.viewport_class = std::move(*viewport_class);

        NSString *place = to_nsstring(request.place_path);
        NSString *stem = place.lastPathComponent.stringByDeletingPathExtension;
        if (![stem isEqualToString:to_nsstring(request.expected_token)] ||
            (!path_is_absolute_readable_file(request.place_path, "rbxl") &&
             !path_is_absolute_readable_file(request.place_path, "rbxlx"))) return std::nullopt;

        NSString *output = to_nsstring(request.output_path);
        if (!output || !output.isAbsolutePath || ![output.pathExtension.lowercaseString isEqualToString:@"png"])
            return std::nullopt;
        NSString *parent = output.stringByDeletingLastPathComponent;
        BOOL directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:parent isDirectory:&directory] || !directory ||
            ![NSFileManager.defaultManager isWritableFileAtPath:parent]) return std::nullopt;

        request.generation = g_generation.load(std::memory_order_acquire);
        request.queued_at = Clock::now();
        return request;
    }
}

} // namespace

bool ctpl_capture_request(std::string json) {
    auto request = parse_request(json);
    if (!request) return false;
    if (!rml::qt::QApplication::instance()) return false;
    ctpl::dispatch_gui([request = std::move(*request)]() mutable {
        if (!rml::qt::QApplication::instance()) return;
        auto &state = capture_state();
        if (request.generation != g_generation.load(std::memory_order_acquire)) return;
        state.requests.push_back(std::move(request));
        ensure_timer();
    });
    return true;
}

void ctpl_capture_cancel() {
    {
        std::lock_guard generation_guard(g_generation_mutex);
        g_generation.fetch_add(1, std::memory_order_acq_rel);
    }
    if (rml::qt::QApplication::instance()) {
        ctpl::dispatch_gui([] {
            if (!rml::qt::QApplication::instance()) return;
            auto &state = capture_state();
            state.requests.clear();
            if (state.timer && state.timer_running) state.timer->stop();
            state.timer_running = false;
        });
    }
}

bool ctpl_capture_dump_widgets(std::string output_path) {
    if (output_path.empty()) output_path = diagnostic_path();
    if (!rml::qt::QApplication::instance()) return false;
    ctpl::dispatch_gui([output_path = std::move(output_path)] {
        if (!rml::qt::QApplication::instance()) return;
        write_widget_dump(output_path);
    });
    return true;
}

bool ctpl_capture_current_viewport(std::uintptr_t window_identity, const std::string& output_path,
    std::function<bool()> identity_matches, std::function<void(bool,std::string)> completion) {
    if (!pthread_main_np() || !window_identity || !identity_matches || !completion) return false;
    QWidget* window = nullptr;
    for (auto* w : rml::qt::QApplication::all_widgets())
        if (reinterpret_cast<std::uintptr_t>(w) == window_identity && top_level(w) == w &&
            is_studio_main_window(w) && is_active_window(w) && !is_minimized(w)) window = w;
    if (!window || !identity_matches()) return false;
    CaptureRequest selector;
    selector.viewport_name = "QEngineWidget";
    selector.viewport_class = "RBX::Studio::QEngineWidget";
    QWidget* viewport = nullptr;
    if (locate_viewport(selector,window,&viewport).has_value() || !viewport) return false;
    const auto view = native_view_id(viewport);
    if (!view) return false;
    const int width=viewport->width(), height=viewport->height();
    const auto generation=g_generation.load(std::memory_order_acquire);
    const std::string attempt=capture_attempt_path(output_path,++capture_state().next_attempt_id);
    return ctpl_capture_owned_view(*view,attempt,
        [window_identity,output_path,attempt,view=*view,width,height,generation,
         identity_matches=std::move(identity_matches),completion=std::move(completion)]
        (bool captured,std::string message) mutable {
            auto fail=[&](std::string reason){remove_capture_path(attempt);completion(false,std::move(reason));};
            if (!captured) {fail(message.empty()?"The current viewport could not be captured.":std::move(message));return;}
            if (generation!=g_generation.load(std::memory_order_acquire) || !identity_matches()) {
                fail("The active place changed while its thumbnail was being captured.");return;
            }
            QWidget* current_window=nullptr;
            for (auto* w:rml::qt::QApplication::all_widgets())
                if(reinterpret_cast<std::uintptr_t>(w)==window_identity&&top_level(w)==w&&
                    is_active_window(w)&&!is_minimized(w))current_window=w;
            CaptureRequest selector;selector.viewport_name="QEngineWidget";selector.viewport_class="RBX::Studio::QEngineWidget";
            QWidget* current_viewport=nullptr;
            if(!current_window||locate_viewport(selector,current_window,&current_viewport).has_value()||
                !current_viewport||native_view_id(current_viewport)!=std::optional<std::uintptr_t>(view)||
                current_viewport->width()!=width||current_viewport->height()!=height) {
                fail("The current viewport changed while its thumbnail was being captured.");return;
            }
            std::string error;
            if(!validate_owned_capture(attempt,&error)){fail(std::move(error));return;}
            // Refuse to replace a pre-existing destination. Existing path-mode
            // captures retain their separate generation and publication guards.
            bool cancelled=false, publish_failed=false;
            {
                // Match the existing path-mode publication protocol: a cancel
                // and final publication are serialized. The document/Qt reads
                // above are complete before acquiring this mutex. Completion
                // here only transfers values/enqueues the snapshot result.
                std::lock_guard generation_guard(g_generation_mutex);
                if(generation!=g_generation.load(std::memory_order_acquire))cancelled=true;
                else if(link(attempt.c_str(),output_path.c_str())!=0)publish_failed=true;
                else {remove_capture_path(attempt);completion(true,{});return;}
            }
            if(cancelled)fail("The current thumbnail capture was cancelled.");
            else if(publish_failed)fail("The current thumbnail could not be finalized.");
        });
}
