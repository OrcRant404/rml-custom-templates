#include "CurrentPlaceSnapshot.hpp"
#include "NativeGuiDispatch.hpp"
#include "StartPageUI.hpp"
#include "ThumbnailCapture.hpp"
#include "TemplateFileMenu.hpp"
#include "TemplateOpen.hpp"
#include "dotnet/interop_registry.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
using i32 = std::int32_t;
using u64 = std::uint64_t;
struct lua_State;
#include <RobloxModLoader/rml_export.hpp>
#include <RobloxModLoader/roblox/reflection/object.hpp>
namespace RBX { class DataModel; class DataModelSerialize; }
#include <RobloxModLoader/memory/foreign_call.hpp>
#include <RobloxModLoader/qt/qapplication.hpp>
#include <RobloxModLoader/qt/qt_module.hpp>
#include <RobloxModLoader/qt/qstring.hpp>
#include <RobloxModLoader/qt/qtimer.hpp>
#include <RobloxModLoader/qt/qwidget.hpp>
#import <AppKit/AppKit.h>

namespace {
using Clock = std::chrono::steady_clock;
using NativeHandle = std::uintptr_t;
using Variant = rml::dotnet::InteropVariant;
using Tag = rml::dotnet::InteropValueTag;
using QWidget = rml::qt::QWidget;
constexpr auto kFresh = std::chrono::milliseconds(1500);
constexpr auto kDeadline = std::chrono::seconds(15);
constexpr std::size_t kMaximumPlaceBytes = 512 * 1024 * 1024;
constexpr NativeHandle kSerializerVtable = 0x10c850a98;
constexpr NativeHandle kSerializeMethod = 0x107d63508;
constexpr NativeHandle kSerializerGlobal = 0x10d0486c8;
constexpr NativeHandle kSerializerSetter = 0x1047c5760;
constexpr std::array<unsigned char,16> kSetterCode{
    0xe1,0x03,0x00,0xaa,0x00,0x44,0x04,0xf0,0x00,0x20,0x1b,0x91,0x98,0x10,0xe2,0x16};
constexpr std::array<unsigned char,16> kSerializePrologue{
    0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf4,0x03,0x01,0xaa};
// Same pinned and live-validated scalar type field as CustomTemplatesUI.mm.
// No DataModel serializer field/Instance/shared_ptr layout is read. The SDK's
// macOS serializer member offset disagrees with its Windows-only assertion;
// the verified native startup global below avoids that field entirely.
constexpr std::size_t kDataModelTypeOffset = 0x348;
using Serialize = std::shared_ptr<std::stringstream> (*)(void*, RBX::DataModel*);
static_assert(sizeof(std::shared_ptr<std::stringstream>) == 16);
static_assert(sizeof(std::stringstream) == 0x118); // Native make_shared allocation 0x130, object at +0x18.

struct Observation {
    std::string id;
    Clock::time_point seen{};
    Clock::time_point queried{};
    bool editable = false;
};
struct Context {
    std::string document_id, engine_id, source_path, title, name;
    NativeHandle window = 0, model = 0;
    bool viewport_visible = false;
};
struct Stage {
    int directory = -1;
    dev_t device{};
    ino_t inode{};
    std::string parent, path, thumbnail_path, temporary;
    std::atomic<bool> place_created{false}, thumbnail_created{false}, delivered{false};
    ~Stage() {
        if (directory >= 0) {
            if (!temporary.empty()) unlinkat(directory, temporary.c_str(), 0);
            // The native request owns its exact generated files until a success
            // command is accepted by the managed queue. Cancelled/dropped work
            // cannot leave a large unconsumed snapshot or PNG behind.
            if (!delivered.load()) {
                if (place_created.load()) unlinkat(directory,"place.rbxl",0);
                if (thumbnail_created.load()) unlinkat(directory,"thumbnail.png",0);
            }
            close(directory);
        }
    }
};
struct Request {
    std::string id;
    Context context;
    std::shared_ptr<Stage> stage;
    std::uint64_t generation = 0;
    Clock::time_point queued = Clock::now();
};
struct State {
    rml::dotnet::InteropTable api{};
    std::once_flag populate_once;
    bool populated = false;
    std::atomic<bool> active{false};
    std::atomic<std::uint64_t> generation{1};
    std::mutex mutex;
    std::map<NativeHandle, Observation> edits;
    Clock::time_point runtime_seen{};
    std::optional<Request> pending;
    bool serializing = false;
    // These are GUI-thread only. Context records contain values, never retained
    // QWidget/engine ownership; every use re-discovers the live Qt widget.
    std::map<std::string, Context> contexts;
    std::uint64_t next_context = 0;
    rml::qt::QTimer* timer = nullptr;
    std::mutex diagnostic_mutex;
    std::map<std::string,std::string> diagnostic_last;
    std::uint32_t diagnostic_lines = 0;
    std::atomic<std::uint32_t> observed_types{0};
};
State& state() { static auto* s = new State(); return *s; }
void diagnostic_changed(const std::string& key, const std::string& detail) {
    auto& s=state();
    bool emit=false;
    {
        std::lock_guard lock(s.diagnostic_mutex);
        if(s.diagnostic_lines>=128)return;
        const auto found=s.diagnostic_last.find(key);
        if(found!=s.diagnostic_last.end()&&found->second==detail)return;
        if(found==s.diagnostic_last.end()&&s.diagnostic_last.size()>=32)return;
        s.diagnostic_last[key]=detail;++s.diagnostic_lines;emit=true;
    }
    // This is the SDK's native logger, not a CLR callback. Never emit while
    // holding either the observation mutex or this diagnostic-state mutex.
    if(emit&&s.api.managed_log) {
        const std::string message="Custom Templates current save: "+detail;
        s.api.managed_log(2,message.c_str(),static_cast<std::int32_t>(message.size()));
    }
}
NSString* ns(const std::string& s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}
std::string utf8(NSString* s) { return s.UTF8String ? s.UTF8String : ""; }
std::string json(NSDictionary* v) {
    NSData* d = [NSJSONSerialization dataWithJSONObject:v options:0 error:nil];
    return d ? std::string(static_cast<const char*>(d.bytes), d.length) : "";
}
void failure(const Request& r, const std::string& message) {
    ctpl_post_command(json(@{@"type":@"current_place_snapshot_failed", @"requestId":ns(r.id),
        @"message":ns(message)}));
}
void success(const Request& r, const std::string& thumbnail, const std::string& message) {
    NSMutableDictionary* result = [@{@"type":@"current_place_snapshot", @"requestId":ns(r.id),
        @"path":ns(r.stage->path), @"documentId":ns(r.context.document_id),
        @"sourcePath":ns(r.context.source_path), @"name":ns(r.context.name),
        @"stableDocumentId":ns("ctpl:"+std::to_string(getpid())+":"+r.context.engine_id)} mutableCopy];
    if (!thumbnail.empty()) result[@"thumbnailPath"] = ns(thumbnail);
    if (!message.empty()) result[@"message"] = ns(message);
    if (ctpl_try_post_command(json(result))) r.stage->delivered.store(true);
}
void free_result(Variant& v) {
    auto& api = state().api;
    if (v.tag == Tag::String && v.as_string) api.free_string(v.as_string);
    else if ((v.tag == Tag::InstanceArray || v.tag == Tag::Blittable) && v.as_instance)
        api.free_native_ptr(reinterpret_cast<const void*>(v.as_instance));
    v = {};
}
struct Result { Variant v{}; ~Result() { free_result(v); } };
std::string engine_id(NativeHandle game, std::string* diagnostic=nullptr) {
    Variant arg{}; arg.tag = Tag::Int64; arg.as_int64 = 32;
    Result r; state().api.reflection_invoke(game, "GetDebugId", &arg, 1, &r.v);
    const std::string value=r.v.tag == Tag::String && r.v.as_string ? r.v.as_string : "";
    if(diagnostic)*diagnostic="GetDebugId(tag="+std::to_string(static_cast<int>(r.v.tag))+
        ",length="+std::to_string(value.size())+",valid="+(value.empty()?"false":"true")+")";
    return value;
}
std::optional<bool> engine_bool(NativeHandle target, const char* method, std::string* diagnostic=nullptr) {
    // The pinned SDK's encode_return_value lacks a scalar Bool case: false is
    // encoded as Null and true as Int64. Null also represents invocation errors,
    // so treating it as false would weaken the Play-mode guard. Use only these
    // two declared bool methods and the SDK's native member-pointer mechanism,
    // with an exact bool return rather than its generic uint64 return adapter.
    if(!target||(std::strcmp(method,"IsEdit")!=0&&std::strcmp(method,"IsRunning")!=0))return std::nullopt;
    auto* instance=reinterpret_cast<RBX::Reflection::DescribedBase*>(target);
    const auto& class_descriptor=instance->get_descriptor();
    if(std::string_view(class_descriptor.name.c_str())!="RunService")return std::nullopt;
    // ClassDescriptor::find_function is inline and reads g_pointers, an inline
    // loader global that this hidden-visibility helper would privately define.
    // Obtain RML's initialized table through its exported SDK accessor, then
    // use exactly find_function's atom lookup and discovered member-table offset.
    const RBX::Reflection::FunctionDescriptor* descriptor=nullptr;
    try {
        const auto* pointers=get_roblox_pointers();
        if(!pointers||!pointers->get_string_atom||!pointers->descriptor_lookup||!pointers->member_table_offset) {
            if(diagnostic)*diagnostic=std::string(method)+"(loader_lookup_unavailable)";
            return std::nullopt;
        }
        auto atom=pointers->get_string_atom(method);
        if(atom) {
            const auto member=pointers->descriptor_lookup(
                reinterpret_cast<std::uintptr_t>(&class_descriptor)+pointers->member_table_offset,&atom);
            if(member&&*member)descriptor=reinterpret_cast<const RBX::Reflection::FunctionDescriptor*>(*member);
        }
    } catch(...) {
        if(diagnostic)*diagnostic=std::string(method)+"(loader_lookup_unavailable)";
        return std::nullopt;
    }
    if(!descriptor) {
        if(diagnostic)*diagnostic=std::string(method)+"(descriptor_missing)";
        return std::nullopt;
    }
    const auto& signature=descriptor->get_signature();
    const auto* type=signature.first_result_type();
    const bool supported=descriptor->name==method&&type&&type->type_id==RBX::Reflection::TypeId::Bool&&
        std::string_view(type->name.c_str())=="bool"&&signature.arguments().empty()&&
        signature.result_types().size()==1&&descriptor->get_kind()==RBX::Reflection::FunctionDescriptor::Default&&
        descriptor->invoke_func_ptr;
    if(!supported) {
        if(diagnostic)*diagnostic=std::string(method)+"(unsupported_signature,type="+
            (type?std::string(type->name.c_str()):"missing")+",kind="+
            std::to_string(static_cast<int>(descriptor->get_kind()))+")";
        return std::nullopt;
    }
    class BooleanCallable {};
    using BooleanMember=bool (BooleanCallable::*)() const;
    static_assert(sizeof(BooleanMember)==sizeof(descriptor->invoke_func_ptr)+sizeof(descriptor->bound_this_delta));
    BooleanMember member{};
    // Same adjacent invoke_func_ptr/bound_this_delta copy as the SDK's
    // RBX::Reflection::Function::load_member_pointer, preserving this adjustment.
    std::memcpy(&member,&descriptor->invoke_func_ptr,sizeof(member));
    const bool result=(reinterpret_cast<BooleanCallable*>(instance)->*member)();
    if(diagnostic)*diagnostic=std::string(method)+"(native_bool="+(result?"true":"false")+",signature=bool())";
    return result;
}
bool is_editable(NativeHandle game, std::string* diagnostic=nullptr) {
    Variant name{}; name.tag = Tag::String; name.as_string = const_cast<char*>("RunService");
    Result r; state().api.reflection_invoke(game, "GetService", &name, 1, &r.v);
    if(diagnostic)*diagnostic="GetService(RunService,tag="+std::to_string(static_cast<int>(r.v.tag))+
        ",valid="+((r.v.tag==Tag::Instance&&r.v.as_instance)?"true":"false")+")";
    if (r.v.tag != Tag::Instance || !r.v.as_instance) return false;
    std::string edit_detail,running_detail;
    const auto edit = engine_bool(r.v.as_instance, "IsEdit",&edit_detail);
    const auto running = engine_bool(r.v.as_instance, "IsRunning",&running_detail);
    if(diagnostic)*diagnostic+=" "+edit_detail+" "+running_detail;
    return edit && *edit && running && !*running;
}
NativeHandle relocated(NativeHandle address) {
    return static_cast<NativeHandle>(static_cast<std::intptr_t>(address) + _dyld_get_image_vmaddr_slide(0));
}
bool mapped_in_main(NativeHandle address, std::size_t bytes, bool executable) {
    const auto* h = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(0));
    if (!h || h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64) return false;
    auto* command = reinterpret_cast<const load_command*>(h + 1);
    for (std::uint32_t i = 0; i < h->ncmds; ++i) {
        if (command->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const segment_command_64*>(command);
            const NativeHandle begin = relocated(seg->vmaddr);
            if (address >= begin && bytes <= seg->vmsize && address - begin <= seg->vmsize - bytes &&
                (seg->initprot & VM_PROT_READ) && (!executable || (seg->initprot & VM_PROT_EXECUTE))) return true;
        }
        command = reinterpret_cast<const load_command*>(reinterpret_cast<const char*>(command) + command->cmdsize);
    }
    return false;
}
bool serializer_supported() {
    const NativeHandle function = relocated(kSerializeMethod), table = relocated(kSerializerVtable);
    if (!mapped_in_main(function, kSerializePrologue.size(), true) || !mapped_in_main(table, 6*sizeof(void*), false) ||
        !mapped_in_main(relocated(kSerializerSetter),kSetterCode.size(),true) ||
        !mapped_in_main(relocated(kSerializerGlobal),sizeof(std::shared_ptr<RBX::DataModelSerialize>),false) ||
        std::memcmp(reinterpret_cast<const void*>(relocated(kSerializerSetter)),kSetterCode.data(),kSetterCode.size())) return false;
    const auto* vtable = reinterpret_cast<const NativeHandle*>(table);
    return vtable[0] == relocated(0x107d634f0) && vtable[1] == relocated(0x107d634f4) &&
        vtable[2] == function && vtable[3] == relocated(0x107d6407c) &&
        std::memcmp(reinterpret_cast<const void*>(function), kSerializePrologue.data(), kSerializePrologue.size()) == 0;
}
std::optional<std::pair<NativeHandle,std::string>> fresh_edit() {
    auto& s = state(); const auto now = Clock::now();
    std::optional<std::pair<NativeHandle,std::string>> found;
    std::string reason;
    std::size_t tracked=0,fresh=0,eligible=0;
    {
        std::lock_guard lock(s.mutex);
        tracked=s.edits.size();
        if(!s.active.load())reason="inactive";
        else if(s.runtime_seen!=Clock::time_point{}&&now-s.runtime_seen<=kFresh)reason="recent_play_model";
        for (const auto& [model,item]:s.edits) {
            if(now-item.seen>kFresh)continue;
            ++fresh;
            if(!item.editable||item.id.empty())continue;
            ++eligible;
            if(!found)found=std::pair(model,item.id);
        }
        if(reason.empty())reason=eligible==1?"ready":eligible>1?"ambiguous_edit_models":fresh?"edit_checks_failed":"no_fresh_edit_model";
        if(reason!="ready")found.reset();
    }
    diagnostic_changed("observation","observation="+reason+" tracked="+std::to_string(tracked)+
        " fresh="+std::to_string(fresh)+" eligible="+std::to_string(eligible)+
        " seen_type_mask="+std::to_string(s.observed_types.load()));
    return found;
}
std::string qstring(void* function, const void* self) {
    if (!function || !self) return {};
    rml::qt::QString result;
    struct Storage { void* data = nullptr; } raw;
    static_assert(sizeof(raw) == sizeof(result));
    rml::memory::call_returning_member(function, raw, self);
    std::memcpy(result.storage(), &raw, sizeof(raw));
    return result.to_utf8();
}
std::string tab_string(void* function, const void* self, int index) {
    if(!function||!self)return {};
    rml::qt::QString result;
    struct Storage {void* data=nullptr;} raw;
    static_assert(sizeof(raw)==sizeof(result));
    rml::memory::call_returning_member(function,raw,self,index);
    std::memcpy(result.storage(),&raw,sizeof(raw));
    return result.to_utf8();
}
QWidget* top_level(QWidget* w) {
    static const auto f = rml::qt::detail::widgets_optional<void* (*)(const void*)>("QWidget::window() const");
    return f && w ? static_cast<QWidget*>(f(w)) : nullptr;
}
bool active(QWidget* w) {
    static const auto f = rml::qt::detail::widgets_optional<bool (*)(const void*)>("QWidget::isActiveWindow() const");
    return f && w && f(w);
}
bool visible(QWidget* w, QWidget* root) {
    static const auto f = rml::qt::detail::widgets_optional<bool (*)(const void*,const void*)>("QWidget::isVisibleTo(QWidget const*) const");
    return f && w && root && f(w,root);
}
void dump_active_widgets_once() {
    // GUI-thread only and process-lifetime bounded. Keep the output inode open
    // through the queued dumper so its ofstream cannot follow a replacement
    // diagnostic-path symlink or truncate another file.
    static bool attempted=false;
    if(attempted||!pthread_main_np())return;
    attempted=true;
    struct Output {
        int directory=-1,file=-1;
        std::string name;
        ~Output(){if(file>=0)close(file);if(directory>=0)close(directory);}
        void remove_empty_owned() const {
            struct stat opened{},named{};
            if(file>=0&&directory>=0&&!fstat(file,&opened)&&opened.st_size==0&&
                !fstatat(directory,name.c_str(),&named,AT_SYMLINK_NOFOLLOW)&&S_ISREG(named.st_mode)&&
                named.st_dev==opened.st_dev&&named.st_ino==opened.st_ino)unlinkat(directory,name.c_str(),0);
        }
    };
    auto output=std::make_shared<Output>();
    try {
        const auto root=std::filesystem::path(utf8(NSHomeDirectory()))/
            "Library/Application Support/RobloxCustomTemplates";
        for(auto part=root;!part.empty();) {
            struct stat item{};
            if(lstat(part.c_str(),&item)||!S_ISDIR(item.st_mode)||S_ISLNK(item.st_mode))
                throw std::runtime_error("catalog diagnostic path is unavailable or contains a symbolic link");
            const auto parent=part.parent_path();if(parent==part)break;part=parent;
        }
        const int catalog=open(root.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(catalog<0)throw std::runtime_error("catalog diagnostic folder could not be opened");
        struct stat catalog_stat{};
        const bool owned=!fstat(catalog,&catalog_stat)&&catalog_stat.st_uid==getuid();
        const bool created=owned&&(mkdirat(catalog,"diagnostics",0700)==0||errno==EEXIST);
        const int diagnostics=created?openat(catalog,"diagnostics",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
        close(catalog);
        struct stat diagnostics_stat{};
        const bool diagnostics_owned=diagnostics>=0&&!fstat(diagnostics,&diagnostics_stat)&&diagnostics_stat.st_uid==getuid();
        const bool child_created=diagnostics_owned&&(mkdirat(diagnostics,"current-save",0700)==0||errno==EEXIST);
        if(child_created)output->directory=openat(diagnostics,"current-save",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(diagnostics>=0)close(diagnostics);
        struct stat directory{};
        if(output->directory<0||fstat(output->directory,&directory)||directory.st_uid!=getuid()||
            (directory.st_mode&0077)!=0)
            throw std::runtime_error("current-save diagnostics requires an owned private directory");
        output->name="current-save-active-widgets-"+std::to_string(getpid())+".json";
        output->file=openat(output->directory,output->name.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(output->file<0)throw std::runtime_error("diagnostic output already exists or could not be created");
        const std::string descriptor_path="/dev/fd/"+std::to_string(output->file);
        if(!ctpl_capture_dump_widgets(descriptor_path))throw std::runtime_error("Qt widget dumper could not be queued");
        // Both operations use the same serial main queue. This following task
        // keeps the descriptor alive until the existing dumper has finished.
        ctpl::dispatch_gui([output]{
            struct stat result{};
            if(fstat(output->file,&result)||result.st_size<=0) {
                output->remove_empty_owned();
                diagnostic_changed("widgetdump","Qt widget diagnostic failed to produce output");
                return;
            }
            if(fsync(output->file)) {
                diagnostic_changed("widgetdump","Qt widget diagnostic could not be flushed");
                return;
            }
            diagnostic_changed("widgetdump","Qt widget diagnostic saved in diagnostics/current-save/"+output->name);
        });
        diagnostic_changed("widgetdump","Qt widget diagnostic queued once for the active Edit window");
    }catch(const std::exception& error) {
        output->remove_empty_owned();
        diagnostic_changed("widgetdump",std::string("Qt widget diagnostic skipped: ")+error.what());
    }
}
std::optional<Context> gui_context() {
    auto reject=[](const std::string& reason)->std::optional<Context>{diagnostic_changed("gui","GUI guard="+reason);return std::nullopt;};
    if (!pthread_main_np() || !state().active.load()) return reject("inactive_or_wrong_thread");
    const auto edit = fresh_edit(); if (!edit) return reject("no_eligible_edit_model");
    const auto widgets = rml::qt::QApplication::all_widgets();
    QWidget* window = nullptr;
    std::string main_candidates;
    static const auto minimized = rml::qt::detail::widgets_optional<bool (*)(const void*)>("QWidget::isMinimized() const");
    for (auto* w : widgets) {
        if(w&&top_level(w)==w&&w->inherits("QMainWindow")&&main_candidates.size()<512)
            main_candidates+=std::string(w->class_name()?:"")+"(active="+(active(w)?"true":"false")+") ";
        if (!w || top_level(w) != w || std::string_view(w->class_name() ?: "") != "RBX::Studio::MainWindow" ||
            !active(w) || !minimized || minimized(w)) continue;
        if (window) return reject("multiple_active_main_windows");
        window = w;
    }
    if (!window) return reject("no_active_main_window candidates="+main_candidates);
    int viewports = 0;
    std::string viewport_candidates;
    std::vector<QWidget*> place_views,script_editors;
    static void* const name = rml::qt::detail::core_export_optional("QObject::objectName() const");
    for (auto* w : widgets) {
        if(!w||top_level(w)!=window)continue;
        const std::string_view kind=w->class_name()?:"";
        if(kind.find("EngineWidget")!=std::string_view::npos&&viewport_candidates.size()<512)
            viewport_candidates+=std::string(kind)+"/"+qstring(name,w)+"("+std::to_string(w->width())+"x"+
                std::to_string(w->height())+",visible="+(visible(w,window)?"true":"false")+") ";
        if(kind=="RBX::Studio::QEngineWidget"&&qstring(name,w)=="QEngineWidget")place_views.push_back(w);
        if (!visible(w,window) || w->width() < 320 || w->height() < 180) continue;
        if(kind=="RBX::Studio::QEngineWidget"&&qstring(name,w)=="QEngineWidget")++viewports;
        if(kind=="StudioScriptEditor"&&qstring(name,w)=="ScriptTextEditor")script_editors.push_back(w);
    }
    QWidget* script_tabs=nullptr;
    const bool script_mode=viewports!=1;
    if (viewports != 1) {
        dump_active_widgets_once();
        // Script Editor replaces the place page, while the hidden place page
        // remains a sibling in the same document group. Require that exact
        // observed topology, not a generic text editor or Command Bar widget.
        static const auto ancestor=rml::qt::detail::widgets_optional<bool (*)(const void*,const void*)>(
            "QWidget::isAncestorOf(QWidget const*) const");
        if(viewports!=0||place_views.size()!=1||visible(place_views.front(),window)||script_editors.size()!=1||!ancestor)
            return reject("viewport_count="+std::to_string(viewports)+" candidates="+viewport_candidates);
        QWidget *script_panel=nullptr,*place_panel=nullptr;
        int script_panels=0,place_panels=0;
        for(auto* w:widgets) {
            if(!w||top_level(w)!=window||std::string_view(w->class_name()?:"")!="Qtitan::DockDocumentPanel")continue;
            const auto object_name=qstring(name,w);
            if(object_name.starts_with("script_")&&object_name.size()>7&&visible(w,window)&&ancestor(w,script_editors.front())) {
                script_panel=w;++script_panels;
            }
            if(object_name=="ideDocDocumentPanel"&&ancestor(w,place_views.front())) {place_panel=w;++place_panels;}
        }
        if(script_panels!=1||place_panels!=1||visible(place_panel,window))return reject("script_document_panels_unverified");
        QWidget *script_group=nullptr,*place_group=nullptr;
        int script_groups=0,place_groups=0;
        for(auto* w:widgets) {
            if(!w||top_level(w)!=window||std::string_view(w->class_name()?:"")!="Qtitan::DockDocumentTabbedLayoutPanel")continue;
            if(ancestor(w,script_panel)){script_group=w;++script_groups;}
            if(ancestor(w,place_panel)){place_group=w;++place_groups;}
        }
        if(script_groups!=1||place_groups!=1||script_group!=place_group)return reject("script_document_group_unverified");
        for(auto* w:widgets) {
            if(!w||top_level(w)!=window||!visible(w,window)||w->width()<=0||w->height()<=0||
                std::string_view(w->class_name()?:"")!="Qtitan::DockDocumentAreaTabBar"||!ancestor(script_group,w))continue;
            if(script_tabs)return reject("script_document_tabs_ambiguous");
            script_tabs=w;
        }
        if(!script_tabs)return reject("script_document_tabs_unverified");
    }
    static void* const title = rml::qt::detail::widgets_export_optional("QWidget::windowTitle() const");
    static void* const file = rml::qt::detail::widgets_export_optional("QWidget::windowFilePath() const");
    Context c; c.model = edit->first; c.engine_id = edit->second;
    c.window = reinterpret_cast<NativeHandle>(window); c.title = qstring(title,window); c.source_path = qstring(file,window);
    c.viewport_visible=!script_mode;
    constexpr std::string_view suffix = " - Roblox Studio";
    std::string label = c.title;
    if (label.ends_with(suffix)) label.resize(label.size()-suffix.size());
    while (!label.empty() && (label.back() == '*' || label.back() == ' ')) label.pop_back();
    if (c.source_path.empty() && !script_mode && std::filesystem::path(label).is_absolute()) {
        const auto extension = std::filesystem::path(label).extension().string();
        if (extension == ".rbxl" || extension == ".rbxlx") c.source_path = label;
    }
    if (!c.source_path.empty() && !std::filesystem::path(c.source_path).is_absolute()) c.source_path.clear();
    if(script_mode) {
        // A script title may contain arbitrary separators. Only the actual
        // place tab's unique absolute tooltip/text path may supply a new path;
        // never split the main title at " - ". Read at most 64 document tabs.
        static const auto count=rml::qt::detail::widgets_optional<int (*)(const void*)>("QTabBar::count() const");
        static void* const text=rml::qt::detail::widgets_export_optional("QTabBar::tabText(int) const");
        static void* const tooltip=rml::qt::detail::widgets_export_optional("QTabBar::tabToolTip(int) const");
        const auto title_matches=[&](const std::string& path) {
            return label==path||label.starts_with(path+" - ")||label.starts_with(path+"* - ")||label.starts_with(path+" * - ");
        };
        std::optional<std::string> tab_path;bool ambiguous=false;
        const int tabs=count?count(script_tabs):0;
        if(tabs>0&&tabs<=64)for(int index=0;index<tabs;++index) {
            for(void* getter:{tooltip,text}) {
                const auto value=tab_string(getter,script_tabs,index);
                const std::filesystem::path path(value);const auto extension=path.extension().string();
                if(!path.is_absolute()||(extension!=".rbxl"&&extension!=".rbxlx")||!title_matches(value))continue;
                if(tab_path&&*tab_path!=value)ambiguous=true;else tab_path=value;
            }
        }
        if(tab_path&&!ambiguous)c.source_path=*tab_path;
        if(!c.source_path.empty())c.name=std::filesystem::path(c.source_path).stem().string();
        else {
            std::optional<std::pair<std::string,std::string>> previous;
            bool previous_ambiguous=false;
            for(const auto& [_,known]:state().contexts) {
                if(!known.viewport_visible||known.model!=c.model||known.engine_id!=c.engine_id||known.window!=c.window||
                    (!known.source_path.empty()&&!title_matches(known.source_path)))continue;
                const auto value=std::pair(known.source_path,known.name);
                if(previous&&*previous!=value)previous_ambiguous=true;else previous=value;
            }
            if(previous&&!previous_ambiguous){c.source_path=previous->first;c.name=previous->second;}
        }
    }else c.name = std::filesystem::path(label).stem().string();
    if (c.name.empty()) c.name = "Untitled Template";
    diagnostic_changed("gui",script_mode?"GUI guard=ready_script_editor":"GUI guard=ready");
    return c;
}
bool same_context(const Context& a, const Context& b) {
    return a.model == b.model && a.engine_id == b.engine_id && a.window == b.window &&
        a.source_path == b.source_path && a.title == b.title && a.viewport_visible == b.viewport_visible;
}
bool uuid(const std::string& s) {
    if (s.size() != 36) return false;
    for (std::size_t i = 0; i < s.size(); ++i) {
        if (i==8 || i==13 || i==18 || i==23) { if (s[i]!='-') return false; }
        else if (!((s[i]>='0'&&s[i]<='9') || (s[i]>='a'&&s[i]<='f') || (s[i]>='A'&&s[i]<='F'))) return false;
    }
    return true;
}
std::shared_ptr<Stage> staging(const std::string& id, const std::string& path, const std::string& thumbnail) {
    if (!uuid(id)) throw std::runtime_error("Invalid template save request.");
    const std::filesystem::path root = std::filesystem::path(utf8(NSHomeDirectory())) /
        "Library/Application Support/RobloxCustomTemplates/saves" / id;
    if (path != (root/"place.rbxl").string() || thumbnail != (root/"thumbnail.png").string())
        throw std::runtime_error("Template saves require a fresh private staging folder.");
    for (auto part = root; !part.empty();) {
        struct stat st{};
        if (lstat(part.c_str(), &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode))
            throw std::runtime_error("Template save staging contains an unavailable folder or symbolic link.");
        const auto parent = part.parent_path(); if (parent == part) break; part = parent;
    }
    auto result = std::make_shared<Stage>();
    result->parent = root.string(); result->path = path; result->thumbnail_path = thumbnail;
    result->directory = open(root.c_str(), O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st{};
    if (result->directory < 0 || fstat(result->directory,&st) || st.st_uid != getuid())
        throw std::runtime_error("The private template save folder is unavailable.");
    result->device=st.st_dev; result->inode=st.st_ino;
    for (const char* file : {"place.rbxl","thumbnail.png"}) {
        if (fstatat(result->directory,file,&st,AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT)
            throw std::runtime_error("The template save staging folder is already in use.");
    }
    result->temporary = ".place-" + id + ".tmp";
    return result;
}
bool complete_binary_place(std::string_view bytes) {
    constexpr std::array<unsigned char,14> signature{'<','r','o','b','l','o','x','!',0x89,0xff,0x0d,0x0a,0x1a,0x0a};
    if (bytes.size()<32 || bytes.size()>kMaximumPlaceBytes ||
        std::memcmp(bytes.data(),signature.data(),signature.size())) return false;
    // The pinned binary serializer uses the same 32-byte header and 16-byte
    // chunk framing as the shipped binary places. Validate framing through its
    // terminal END chunk; a header or truncated partial stream is insufficient.
    auto u32=[&](std::size_t at) {
        return std::uint32_t(static_cast<unsigned char>(bytes[at])) |
            std::uint32_t(static_cast<unsigned char>(bytes[at+1]))<<8 |
            std::uint32_t(static_cast<unsigned char>(bytes[at+2]))<<16 |
            std::uint32_t(static_cast<unsigned char>(bytes[at+3]))<<24;
    };
    // A complete empty stream is still not a saved place. In particular an
    // incorrect native subobject can produce just PRNT/END with zero counts.
    if(!u32(16)||!u32(20))return false;
    std::size_t at=32;
    while (at<=bytes.size() && bytes.size()-at>=16) {
        const auto compressed=u32(at+4), uncompressed=u32(at+8);
        const std::size_t length=compressed?compressed:uncompressed;
        if (length>bytes.size()-at-16) return false;
        const std::size_t next=at+16+length;
        if (std::memcmp(bytes.data()+at,"END\0",4)==0)
            return !compressed && uncompressed==9 && next==bytes.size() && bytes.substr(at+16,length)=="</roblox>";
        at=next;
    }
    return false;
}
void write_snapshot(const Request& r, const std::string& bytes) {
    if (!complete_binary_place(bytes))
        throw std::runtime_error("Studio did not produce a complete binary place snapshot.");
    auto& stage = *r.stage;
    const int fd = openat(stage.directory,stage.temporary.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd < 0) throw std::runtime_error("The template snapshot file could not be created.");
    bool ok = true; std::size_t done = 0;
    while (done < bytes.size()) {
        const auto amount = write(fd,bytes.data()+done,bytes.size()-done);
        if (amount<0 && errno==EINTR) continue;
        if (amount<=0) {ok=false;break;} done+=static_cast<std::size_t>(amount);
    }
    if (ok && fsync(fd)) ok=false;
    if (close(fd)) ok=false;
    if (!ok) throw std::runtime_error("The template snapshot could not be written.");
    struct stat parent{};
    if (lstat(stage.parent.c_str(),&parent) || !S_ISDIR(parent.st_mode) || S_ISLNK(parent.st_mode) ||
        parent.st_dev!=stage.device || parent.st_ino!=stage.inode)
        throw std::runtime_error("The template save folder changed during serialization.");
    if (!state().active.load() || state().generation.load()!=r.generation)
        throw std::runtime_error("The template save was cancelled.");
    // Hard-link publication is atomic and refuses to replace an existing name.
    if (linkat(stage.directory,stage.temporary.c_str(),stage.directory,"place.rbxl",0))
        throw std::runtime_error("The template snapshot could not be finalized.");
    stage.place_created.store(true);
    unlinkat(stage.directory,stage.temporary.c_str(),0);
    fsync(stage.directory);
}
void finish(Request r, std::string error) {
    auto& s = state();
    {std::lock_guard lock(s.mutex);s.serializing=false;}
    if (!s.active.load() || s.generation.load()!=r.generation) return;
    if (!error.empty()) {failure(r,error);return;}
    std::uintptr_t window = 0;
    if (!ctpl_snapshot_document_matches(r.context.document_id,&window)) {
        success(r,"","The place snapshot was saved. The active document changed before its thumbnail could be captured.");return;
    }
    if(!r.context.viewport_visible) {
        success(r,"","The place snapshot was saved. Its thumbnail was not updated because the 3D viewport is hidden in Script Editor.");return;
    }
    const std::string token = r.context.document_id;
    const bool accepted = ctpl_capture_current_viewport(window,r.stage->thumbnail_path,
        [token]{return ctpl_snapshot_document_matches(token);},
        [r](bool ok,std::string message) {
            if (ok) r.stage->thumbnail_created.store(true);
            if (!state().active.load() || state().generation.load()!=r.generation) return;
            success(r,ok?r.stage->thumbnail_path:std::string(),ok?std::string():
                "The place snapshot was saved. " + (message.empty()?"Its thumbnail could not be captured.":message));
        });
    if (!accepted) success(r,"","The place snapshot was saved. Current viewport capture is unavailable.");
}
void expire_pending() {
    auto& s=state(); std::optional<Request> expired;
    {std::lock_guard lock(s.mutex);
        if (s.pending && Clock::now()-s.pending->queued > kDeadline) {expired=std::move(s.pending);s.pending.reset();}}
    if (expired) failure(*expired,"Studio did not expose the selected Edit place before the template save timed out.");
}
} // namespace

bool ctpl_snapshot_start() {
    auto& s=state();
    std::call_once(s.populate_once,[&s]{
        using Populate=void (*)(rml::dotnet::InteropTable&);
        auto f=reinterpret_cast<Populate>(dlsym(RTLD_DEFAULT,"_ZN3rml6dotnet21RobloxInteropProvider8populateERNS0_12InteropTableE"));
        if (!f) return;
        s.api.version=rml::dotnet::RML_INTEROP_VERSION;s.api.size=sizeof(s.api);f(s.api);
        s.populated=s.api.reflection_invoke&&s.api.free_string&&s.api.free_native_ptr;
    });
    if (!s.populated || !serializer_supported()) return false;
    s.active.store(true);s.generation.fetch_add(1);
    ctpl::dispatch_gui([]{
        auto& s=state();s.contexts.clear();
        if (!s.timer) {s.timer=rml::qt::QTimer::create(nullptr);if(s.timer){s.timer->setInterval(500);s.timer->on_timeout([]{try{expire_pending();ctpl_filemenu_set_state(!ctpl_template_open_pending()&&!ctpl_snapshot_document_token().empty(),{});}catch(...){ctpl_filemenu_set_state(false,{});}});}}
        if(s.timer)s.timer->start();
    });
    return true;
}
void ctpl_snapshot_stop() {
    auto& s=state();s.active.store(false);s.generation.fetch_add(1);
    {std::lock_guard lock(s.mutex);s.pending.reset();s.edits.clear();s.runtime_seen={};}
    ctpl_filemenu_set_state(false,{});
    ctpl::dispatch_gui([]{state().contexts.clear();if(state().timer)state().timer->stop();});
}
std::string ctpl_snapshot_document_token() {
    auto current=gui_context();if(!current)return {};
    auto& s=state();
    for(const auto& [token,c]:s.contexts)if(same_context(c,*current))return token;
    current->document_id="ctpl:"+std::to_string(getpid())+":"+std::to_string(++s.next_context)+":"+current->engine_id;
    const auto token=current->document_id;
    if(s.contexts.size()>=64)s.contexts.erase(s.contexts.begin());
    s.contexts[token]=std::move(*current);return token;
}
bool ctpl_snapshot_document_matches(const std::string& token,std::uintptr_t* window) {
    if (!pthread_main_np() || token.empty()) return false;
    const auto found=state().contexts.find(token);if(found==state().contexts.end())return false;
    auto current=gui_context();if(!current||!same_context(found->second,*current))return false;
    if(window)*window=current->window;return true;
}
std::optional<CtplOpenDocumentContext> ctpl_snapshot_open_document_context() {
    auto current=gui_context();
    if(!current)return std::nullopt;
    return CtplOpenDocumentContext{"ctpl:"+std::to_string(getpid())+":"+current->engine_id,
        current->source_path,current->window};
}
std::vector<std::string> ctpl_snapshot_known_document_ids() {
    if(!pthread_main_np())return {};
    std::vector<std::string> result;
    auto& s=state();
    std::lock_guard lock(s.mutex);
    for(const auto& [_,entry]:s.edits)if(!entry.id.empty())
        result.push_back("ctpl:"+std::to_string(getpid())+":"+entry.id);
    return result;
}
void ctpl_snapshot_tick(std::uintptr_t handle) {
    if(!handle||!state().active.load())return;
    auto& s=state();auto* game=reinterpret_cast<RBX::DataModel*>(handle);
    std::int32_t type=-1;
    std::memcpy(&type,reinterpret_cast<const std::byte*>(game)+kDataModelTypeOffset,sizeof(type));
    const std::uint32_t type_bit=type>=0&&type<31?std::uint32_t{1}<<type:std::uint32_t{1}<<31;
    const auto previous_types=s.observed_types.fetch_or(type_bit);
    if(!(previous_types&type_bit))diagnostic_changed("types","observed DataModel type="+std::to_string(type)+
        " seen_type_mask="+std::to_string(previous_types|type_bit));
    const auto now=Clock::now();
    if(type==1||type==2){std::lock_guard lock(s.mutex);s.runtime_seen=now;return;}
    if(type!=0)return;
    bool query=false;
    {std::lock_guard lock(s.mutex);auto& edit=s.edits[handle];edit.seen=now;query=now-edit.queried>=std::chrono::milliseconds(250);if(query)edit.queried=now;}
    if(!query)return;
    // Reflection and typed serializer execution must remain outside all locks
    // and Objective-C autorelease pools: Studio may migrate this fiber.
    std::string id,id_detail,edit_detail;bool editable=false;
    try{id=engine_id(handle,&id_detail);editable=!id.empty()&&is_editable(handle,&edit_detail);}
    catch(const std::exception& error){edit_detail=std::string("native query exception: ")+error.what();}
    catch(...){edit_detail="native query exception";}
    diagnostic_changed("edit:"+std::to_string(handle),"Edit model "+id_detail+" "+edit_detail+
        " eligible="+(editable?"true":"false"));
    std::optional<Request> request;
    {std::lock_guard lock(s.mutex);
        auto& edit=s.edits[handle];edit.id=id;edit.editable=editable;edit.seen=Clock::now();
        const bool runtime=s.runtime_seen!=Clock::time_point{}&&now-s.runtime_seen<=kFresh;
        int fresh=0;for(const auto& [_,item]:s.edits)if(now-item.seen<=kFresh&&item.editable&&!item.id.empty())++fresh;
        if(editable&&!runtime&&fresh==1&&s.pending&&!s.serializing&&s.pending->context.model==handle&&s.pending->context.engine_id==id){
            request=std::move(s.pending);s.pending.reset();s.serializing=true;
        }
        for(auto it=s.edits.begin();it!=s.edits.end();)if(now-it->second.seen>std::chrono::seconds(30))it=s.edits.erase(it);else ++it;
    }
    if(!request)return;
    std::string error;
    try {
        if(!serializer_supported())throw std::runtime_error("This Studio serializer does not match the supported build.");
        // Startup constructs this exact std::shared_ptr<DataModelSerialize> and
        // copies it with libc++ assignment at the verified setter. Reading the
        // typed global avoids the SDK's unverified DataModel serializer field.
        const auto serializer=*reinterpret_cast<const std::shared_ptr<RBX::DataModelSerialize>*>(relocated(kSerializerGlobal));
        if(!serializer||*reinterpret_cast<const NativeHandle*>(serializer.get())!=relocated(kSerializerVtable))
            throw std::runtime_error("The selected place has no supported binary serializer.");
        // The SDK job adapter exposes DataModel's Instance/Reflection view.
        // This native serializer expects the complete object and itself adds
        // 0x1F0 before visiting Instance children. Use the standard RTTI cast,
        // bounded by the pinned vtables/RTTI and exact roundtrip; never pass
        // the Instance view twice or assume the SDK's complete-object layout.
        constexpr NativeHandle instance_vtable=0x10c5a59f0, primary_vtable=0x10c5a58d0, type_info=0x10c5a5cd0;
        constexpr std::ptrdiff_t instance_offset=0x1f0;
        const NativeHandle table=*reinterpret_cast<const NativeHandle*>(game);
        if(table!=relocated(instance_vtable)||!mapped_in_main(table-2*sizeof(NativeHandle),3*sizeof(NativeHandle),false))
            throw std::runtime_error("The selected place's native object view does not match this Studio build.");
        const auto* metadata=reinterpret_cast<const NativeHandle*>(table);
        std::ptrdiff_t to_top=0;std::memcpy(&to_top,metadata-2,sizeof(to_top));
        if(to_top!=-instance_offset||metadata[-1]!=relocated(type_info))
            throw std::runtime_error("The selected place's native object identity could not be verified.");
        void* complete=dynamic_cast<void*>(reinterpret_cast<RBX::Reflection::DescribedBase*>(game));
        const NativeHandle complete_address=reinterpret_cast<NativeHandle>(complete);
        if(!complete||handle<static_cast<NativeHandle>(instance_offset)||
            complete_address!=handle-static_cast<NativeHandle>(instance_offset)||
            *reinterpret_cast<const NativeHandle*>(complete)!=relocated(primary_vtable))
            throw std::runtime_error("The selected place's complete native object could not be verified.");
        const auto function=reinterpret_cast<Serialize>(relocated(kSerializeMethod));
        const auto stream=function(serializer.get(),reinterpret_cast<RBX::DataModel*>(complete));
        if(!stream)throw std::runtime_error("Studio returned no place snapshot.");
        const auto bytes=stream->str();write_snapshot(*request,bytes);
    }catch(const std::exception& e){error=e.what();}catch(...){error="Studio could not serialize the selected Edit place.";}
    ctpl::dispatch_gui([r=std::move(*request),error=std::move(error)]() mutable {finish(std::move(r),std::move(error));});
}
extern "C" RML_EXPORT bool ctpl_snapshot_current(const char* input) noexcept {
    if(!input||!state().active.load())return false;
    try {
        const auto size=std::strlen(input);if(size==0||size>16384)return false;
        std::string text(input,size);
        ctpl::dispatch_gui([text=std::move(text)]{
            Request r;r.generation=state().generation.load();
            try {
                id value=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:text.data() length:text.size()] options:0 error:nil];
                if(![value isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid current-place save request.");
                auto string=[&](NSString* key){id v=value[key];if(![v isKindOfClass:NSString.class])throw std::runtime_error("Missing current-place save request field.");return utf8(v);};
                r.id=string(@"requestId");const auto token=string(@"documentId");
                if(!ctpl_snapshot_document_matches(token))throw std::runtime_error("The open place changed. Choose Save to Template again in the intended Edit place.");
                r.context=state().contexts.at(token);
                r.stage=staging(r.id,string(@"path"),string(@"thumbnailPath"));
                bool busy=false;
                {std::lock_guard lock(state().mutex);busy=state().pending.has_value()||state().serializing;if(!busy)state().pending=r;}
                if(busy)throw std::runtime_error("Another template snapshot is still being saved.");
            }catch(const std::exception& e){failure(r,e.what());}catch(...){failure(r,"The current-place template save could not start.");}
        });
        return true;
    }catch(...){return false;}
}
