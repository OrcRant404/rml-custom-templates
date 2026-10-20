#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <expected>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
// These SDK headers normally inherit aliases/Luau's forward declaration from
// RML's precompiled header. Keep the standalone helper independent of that PCH.
using i32 = std::int32_t;
using u64 = std::uint64_t;
struct lua_State;
#include <RobloxModLoader/rml_export.hpp>
#include <RobloxModLoader/hooking/vtable_hook.hpp>
#include <RobloxModLoader/roblox/data_model_job.hpp>
#include <RobloxModLoader/roblox/job_types.hpp>
#include <RobloxModLoader/roblox/task_scheduler.hpp>
#include <RobloxModLoader/roblox/task_scheduler.job.hpp>
#include <RobloxModLoader/roblox/reflection/object.hpp>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#import <AppKit/AppKit.h>
#include "StartPageUI.hpp"
#include "TemplateDialogs.hpp"
#include "ThumbnailCapture.hpp"
#include "TemplateFileMenu.hpp"
#include "CurrentPlaceSnapshot.hpp"
#include "TemplateOpen.hpp"

namespace {
using Clock = std::chrono::steady_clock;
using DataModelFromJob = RBX::DataModel *(*)(const RBX::DataModelJob *);
using WaitingScriptsStep = RBX::TaskScheduler::StepResult (*)(RBX::DataModelJob *, const RBX::Stats &);
constexpr std::string_view kSupportedStudioBuild = "0.741.19.7411056";
constexpr std::uintptr_t kWaitingScriptsVtableAddress = 0x10C594AA0;
constexpr std::uintptr_t kWaitingScriptsStepAddress = 0x1044F45BC;
constexpr std::size_t kWaitingScriptsStepIndex = 9;
constexpr std::size_t kDataModelTypeOffset = 0x348;
constexpr std::int32_t kStandaloneDataModelType = 3;
constexpr std::array<unsigned char,16> kWaitingScriptsStepPrologue{
    0xE9,0x23,0xB9,0x6D,0xFC,0x6F,0x01,0xA9,0xFA,0x67,0x02,0xA9,0xF8,0x5F,0x03,0xA9};
struct NativeState {
    std::mutex mutex;
    std::condition_variable drained;
    std::deque<std::string> commands;
    std::string catalog = R"({"revision":0,"templates":[],"status":"","statusError":false,"selectRevision":0})";
    vtable_hook *hook = nullptr;
    WaitingScriptsStep original = nullptr;
    DataModelFromJob from_job = nullptr;
    Clock::time_point last_tick{};
    std::size_t active_ticks = 0;
    bool active = false;
};
// Callbacks and their UI state remain resident until process exit. No CLR code
// ever runs from this hook or any engine signal callback.
NativeState &state() { static auto *value = new NativeState(); return *value; }
std::atomic_flag g_tick_busy = ATOMIC_FLAG_INIT;

bool queue_command(const std::string &json) {
    auto &s=state(); std::lock_guard lock(s.mutex);
    if (!s.active || s.commands.size()>=1024) return false;
    s.commands.push_back(json);
    return true;
}
bool executable_contains_supported_build(NSString *executable_path) {
    if (executable_path == nil)
        return false;
    const char *const path = executable_path.fileSystemRepresentation;
    if (path == nullptr)
        return false;

    std::ifstream executable(path, std::ios::binary);
    if (!executable)
        return false;

    constexpr std::size_t overlap = kSupportedStudioBuild.size() - 1;
    std::array<char, 4096 + overlap> buffer{};
    std::size_t carry = 0;
    while (executable) {
        executable.read(buffer.data() + carry, static_cast<std::streamsize>(4096));
        const auto read_count = static_cast<std::size_t>(executable.gcount());
        const auto available = carry + read_count;
        const auto found = std::search(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(available),
            kSupportedStudioBuild.begin(), kSupportedStudioBuild.end());
        if (found != buffer.begin() + static_cast<std::ptrdiff_t>(available))
            return true;

        carry = std::min(overlap, available);
        std::move(buffer.begin() + static_cast<std::ptrdiff_t>(available - carry),
            buffer.begin() + static_cast<std::ptrdiff_t>(available), buffer.begin());
    }
    return false;
}

bool supported_studio_runtime() {
#if !defined(__arm64__) && !defined(__aarch64__)
    return false;
#else
    NSBundle *const bundle = NSBundle.mainBundle;
    NSString *const short_version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *const bundle_version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (![short_version isEqualToString:@"0.0.0.1"] || ![bundle_version isEqualToString:@"691"])
        return false;

    // The vtable address and method bytes below are build-specific, so refuse
    // to activate against another Studio executable.
    return executable_contains_supported_build(bundle.executableURL.path);
#endif
}

RBX::TaskScheduler::StepResult waiting_scripts_step_hook(RBX::DataModelJob *job,const RBX::Stats &stats) {
    auto &s=state();
    WaitingScriptsStep original=nullptr; DataModelFromJob from_job=nullptr;
    { std::lock_guard lock(s.mutex); original=s.original; if(s.active) from_job=s.from_job; }
    if (job && from_job && !g_tick_busy.test_and_set(std::memory_order_acquire)) {
        try {
            RBX::DataModel *model=from_job(job);
            std::int32_t type=-1;
            if(model) std::memcpy(&type,reinterpret_cast<const std::byte*>(model)+kDataModelTypeOffset,sizeof(type));
            if(model) {
                bool run=false; std::string catalog;
                {
                    std::lock_guard lock(s.mutex);
                    const auto now=Clock::now();
                    if(s.active) {
                        // Copy first: an allocation failure must not strand the
                        // in-flight counter that shutdown waits to drain.
                        if (type==kStandaloneDataModelType && now-s.last_tick>=std::chrono::milliseconds(250)) {
                            catalog=s.catalog; s.last_tick=now;
                        }
                        ++s.active_ticks; run=true;
                    }
                }
                if(run) {
                    // Native reflection may follow Studio's fiber scheduling;
                    // all state on this stack is C++, with no managed frames.
                    try {
                        ctpl_snapshot_tick(reinterpret_cast<std::uintptr_t>(model));
                        if (!catalog.empty()) ctpl_ui_tick(reinterpret_cast<std::uintptr_t>(model),catalog);
                    } catch (...) {}
                    { std::lock_guard lock(s.mutex); if(--s.active_ticks==0) s.drained.notify_all(); }
                }
            }
        } catch (...) {}
        g_tick_busy.clear(std::memory_order_release);
    }
    return original ? original(job,stats) : RBX::TaskScheduler::Stepped;
}
bool install_hook(NativeState &s) {
    if(s.hook) return s.hook->is_enabled();
    if(!rml::has_task_scheduler()) return false;
    auto result=rml::task_scheduler().get_vtable_for_job_kind(rml::JobKind::WaitingHybridScripts);
    if(!result.has_value() || !*result) return false;
    auto symbol=dlsym(RTLD_DEFAULT,"_ZN3RBX9DataModel8from_jobEPKNS_12DataModelJobE");
    if(!symbol) return false;
    void **vtable=*result; const auto slide=_dyld_get_image_vmaddr_slide(0);
    const auto expected_vtable=static_cast<std::uintptr_t>(static_cast<std::intptr_t>(kWaitingScriptsVtableAddress)+slide);
    const auto expected_step=static_cast<std::uintptr_t>(static_cast<std::intptr_t>(kWaitingScriptsStepAddress)+slide);
    if(reinterpret_cast<std::uintptr_t>(vtable)!=expected_vtable ||
        reinterpret_cast<std::uintptr_t>(vtable[kWaitingScriptsStepIndex])!=expected_step ||
        std::memcmp(reinterpret_cast<const void*>(expected_step),kWaitingScriptsStepPrologue.data(),16)!=0) return false;
    auto *hook=new vtable_hook(vtable,kWaitingScriptsStepIndex+1);
    auto original=hook->get_original<WaitingScriptsStep>(kWaitingScriptsStepIndex);
    if(reinterpret_cast<std::uintptr_t>(original)!=expected_step) { delete hook; return false; }
    s.original=original; s.from_job=reinterpret_cast<DataModelFromJob>(symbol);
    hook->hook(kWaitingScriptsStepIndex,reinterpret_cast<void*>(&waiting_scripts_step_hook));
    if(!hook->enable().has_value()) {s.original=nullptr;delete hook;return false;}
    s.hook=hook; return true;
}
} // namespace

void ctpl_post_command(const std::string &json) {
    // Engine and Qt callbacks only enqueue data. No CLR callback is involved.
    ctpl_try_post_command(json);
}
bool ctpl_try_post_command(const std::string &json) noexcept {
    try { return queue_command(json); } catch (...) { return false; }
}
bool ctpl_ui_set_image(std::uintptr_t image, const std::string &uri) {
    if (!image || (!uri.empty() && !uri.starts_with("rbxasset://RMLCustomTemplates/"))) return false;
    auto *instance=reinterpret_cast<RBX::Reflection::DescribedBase*>(image);
    if (std::string_view(instance->get_descriptor().name.c_str())!="ImageLabel") return false;
    for (const char *name : {"Image", "ImageContent"}) {
        const auto *descriptor=instance->find_property_descriptor(name);
        if (descriptor && !descriptor->is_read_only() && descriptor->has_string_value() &&
            descriptor->set_string_value(instance,uri)) return true;
    }
    return false;
}
bool ctpl_ui_set_style_enum(std::uintptr_t object, const std::string &property, const std::string &value) {
    if (!object) return false;
    auto *instance=reinterpret_cast<RBX::Reflection::DescribedBase*>(object);
    const std::string_view kind=instance->get_descriptor().name.c_str();
    const bool text=(kind=="TextLabel" || kind=="TextButton");
    const bool allowed=(text && property=="TextXAlignment" && (value=="Left" || value=="Center" || value=="Right")) ||
        (text && property=="TextYAlignment" && (value=="Top" || value=="Center" || value=="Bottom")) ||
        (text && property=="Font" && (value=="BuilderSans" || value=="BuilderSansMedium" ||
            value=="BuilderSansBold" || value=="BuilderSansExtraBold")) ||
        (kind=="ImageLabel" && property=="ScaleType" && (value=="Crop" || value=="Fit" || value=="Stretch"));
    if (!allowed) return false;
    const auto *descriptor=instance->find_property_descriptor(property.c_str());
    return descriptor && !descriptor->is_read_only() && descriptor->has_string_value() &&
        descriptor->set_string_value(instance,value);
}
std::string ctpl_ui_font_name(std::int64_t enum_value) {
    // Exact values from the pinned RML SDK's generated Roblox.Enum.Font:
    // code/dotnet/Roblox/src/Roblox/Generated/Enums.cs:2155-2158.
    // Only Foundation's four BuilderSans fonts are supported. The caller can
    // read GetStyled("Font") as an enum primitive without decoding FontFace.
    switch (enum_value) {
    case 46: return "BuilderSans";
    case 47: return "BuilderSansMedium";
    case 48: return "BuilderSansBold";
    case 49: return "BuilderSansExtraBold";
    default: return {};
    }
}
bool ctpl_ui_copy_text_style(std::uintptr_t target, std::uintptr_t source) {
    if (!target || !source) return false;
    try {
        auto *destination=reinterpret_cast<RBX::Reflection::DescribedBase*>(target);
        auto *donor=reinterpret_cast<RBX::Reflection::DescribedBase*>(source);
        const auto is_text=[](const RBX::Reflection::DescribedBase *object) {
            const std::string_view kind=object->get_descriptor().name.c_str();
            return kind=="TextLabel" || kind=="TextButton";
        };
        if (!is_text(destination) || !is_text(donor)) return false;

        constexpr std::array<const char*,3> names{"FontFace","TextSize","TextScaled"};
        std::array<const RBX::Reflection::PropertyDescriptor*,names.size()> properties{};
        // Validate the complete set before the first write. A descriptor's
        // native copy can use its declaring class's getter and setter, so a
        // same-named property on a different text class is not sufficient.
        for (std::size_t i=0; i<names.size(); ++i) {
            const auto *from=donor->find_property_descriptor(names[i]);
            const auto *to=destination->find_property_descriptor(names[i]);
            if (!from || from!=to || from->is_write_only() || to->is_read_only()) return false;
            properties[i]=from;
        }
        for (const auto *property : properties) {
            if (!property->equal_values(donor,destination))
                property->copy_value(donor,destination);
        }
        // FontFace remains an engine-owned value, including its family,
        // weight, and style. No InteropVariant or guessed Font layout is used.
        return std::all_of(properties.begin(),properties.end(),[&](const auto *property) {
            return property->equal_values(donor,destination);
        });
    } catch (...) { return false; }
}
extern "C" RML_EXPORT bool ctpl_show_dialog(const char *json) noexcept {
    if (!json) return false;
    try {
        if (!ctpl_dialogs_available()) return false;
        ctpl_dialogs_show(json);
        return true;
    } catch (...) { return false; }
}
extern "C" RML_EXPORT bool ctpl_capture_thumbnail(const char *json) noexcept {
    if (!json) return false;
    try { return ctpl_capture_request(json); } catch (...) { return false; }
}
extern "C" RML_EXPORT bool ctpl_show_notice(const char *json) noexcept {
    if (!json) return false;
    try {
        std::string message;
        bool quiet = false;
        @autoreleasepool {
            NSData* data = [NSData dataWithBytes:json length:std::strlen(json)];
            id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![value isKindOfClass:NSDictionary.class] || ![value[@"message"] isKindOfClass:NSString.class]) return false;
            message = [value[@"message"] UTF8String];
            quiet = [value[@"quiet"] isKindOfClass:NSNumber.class] && [value[@"quiet"] boolValue];
        }
        if (quiet) ctpl_filemenu_status(message);
        else ctpl_dialogs_notice(message);
        return true;
    } catch (...) { return false; }
}
extern "C" RML_EXPORT void ctpl_cancel_capture() noexcept {
    try { ctpl_capture_cancel(); } catch (...) {}
}
extern "C" RML_EXPORT bool ctpl_start() noexcept {
    try {
        if(!supported_studio_runtime() || !ctpl_ui_init()) return false;
        auto &s=state();
        {
            std::lock_guard lock(s.mutex);
            if(!install_hook(s)) return false;
            s.active=true; s.last_tick={};
        }
        if (!ctpl_snapshot_start()) return false;
        if (!ctpl_template_open_start()) return false;
        ctpl_filemenu_start();
        return true;
    } catch (...) {return false;}
}
extern "C" RML_EXPORT void ctpl_stop() noexcept {
    try {
        auto &s=state();
        {
            std::unique_lock lock(s.mutex); s.active=false;
            s.commands.clear(); s.drained.wait(lock,[&]{return s.active_ticks==0;});
        }
        ctpl_ui_stop();
        ctpl_template_open_stop();
        ctpl_snapshot_stop();
        ctpl_filemenu_stop();
        ctpl_dialogs_stop();
        ctpl_capture_cancel();
    } catch (...) {}
}
extern "C" RML_EXPORT int ctpl_poll_command(char *buffer,int capacity) noexcept {
    try {
        auto &s=state();std::lock_guard lock(s.mutex);
        if(s.commands.empty()) return 0;
        const auto &command=s.commands.front();
        if(command.size()>static_cast<std::size_t>(INT_MAX-1)) return 0;
        const int length=static_cast<int>(command.size());
        if(!buffer || capacity<=length) return -(length+1);
        std::memcpy(buffer,command.c_str(),length+1);s.commands.pop_front();return length;
    } catch (...) {return 0;}
}
extern "C" RML_EXPORT bool ctpl_publish_catalog(const char *json) noexcept {
    if(!json) return false;
    try {
        const auto length=std::strlen(json);if(length>4*1024*1024) return false;
        @autoreleasepool {
            id value=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:length] options:0 error:nil];
            if(![value isKindOfClass:NSDictionary.class]) return false;
        }
        auto &s=state();std::lock_guard lock(s.mutex);s.catalog=json;return true;
    } catch (...) {return false;}
}
extern "C" RML_EXPORT bool ctpl_open_file(const char *utf8_path) noexcept {
    if(!utf8_path || !utf8_path[0]) return false;
    @autoreleasepool { @try {
        NSString *path=[[NSString alloc]initWithUTF8String:utf8_path];
        NSString *extension=path.pathExtension.lowercaseString;
        if(!path || (![@"rbxl" isEqual:extension] && ![@"rbxlx" isEqual:extension])) return false;
        BOOL directory=NO;
        if(![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory ||
            ![NSFileManager.defaultManager isReadableFileAtPath:path]) return false;
        NSURL *file=[NSURL fileURLWithPath:path];NSURL *app=NSBundle.mainBundle.bundleURL;
        NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];
        configuration.activates=YES;configuration.createsNewApplicationInstance=NO;
        dispatch_async(dispatch_get_main_queue(),^{
            [NSWorkspace.sharedWorkspace openURLs:@[file] withApplicationAtURL:app configuration:configuration
                completionHandler:^(__unused NSRunningApplication *application,NSError *error){
                    if(error) {
                        @autoreleasepool {
                            NSData *data=[NSJSONSerialization dataWithJSONObject:@{
                                @"type":@"open_failed", @"path":path,
                                @"message":@"Studio could not open the working copy."} options:0 error:nil];
                            if(data) ctpl_post_command(std::string(static_cast<const char*>(data.bytes),data.length));
                        }
                    }
                }];
        });return true;
    } @catch (__unused NSException *exception) {return false;} }
}
