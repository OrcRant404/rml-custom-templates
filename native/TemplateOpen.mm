#include "TemplateOpen.hpp"
#include "TemplateOpenSource.hpp"
#include "TemplateOpenState.hpp"
#include "CurrentPlaceSnapshot.hpp"
#include "NativeGuiDispatch.hpp"
#include "StartPageUI.hpp"
#include "TemplateFileMenu.hpp"

#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <RobloxModLoader/rml_export.hpp>
#include <RobloxModLoader/qt/qapplication.hpp>
#include <RobloxModLoader/qt/qstring.hpp>
#include <RobloxModLoader/qt/qt_module.hpp>
#include <RobloxModLoader/qt/qtimer.hpp>
#include <RobloxModLoader/qt/qwidget.hpp>
#include <RobloxModLoader/memory/foreign_call.hpp>
#import <AppKit/AppKit.h>

namespace {
using Handle=std::uintptr_t;
using Clock=std::chrono::steady_clock;
using Widget=rml::qt::QWidget;
struct Configuration; // Always owned by Studio's genuine shared_ptr factory.
struct State {
    std::atomic<bool> active{false},busy{false},timer_ready{false};
    std::atomic<std::uint64_t> epoch{0};
    std::mutex publication;
    // Everything below is GUI-thread only. No retained Qt or engine ownership.
    ctpl::opening::Correlation correlation;
    std::unique_ptr<ctpl::opening::OwnedSource> source;
    Clock::time_point started{};
    std::uint64_t request_epoch=0;
    std::string failure;
    rml::qt::QTimer* timer=nullptr;
};
State& state(){static auto* value=new State();return *value;}
Handle runtime(Handle address){return address+_dyld_get_image_vmaddr_slide(0);}
template<class T> T function(Handle address){return reinterpret_cast<T>(runtime(address));}
bool fingerprint(Handle address,std::string_view hex) {
    if(hex.size()%2)return false;
    const auto* code=reinterpret_cast<const unsigned char*>(runtime(address));
    auto digit=[](char value)->unsigned{return value<='9'?value-'0':value-'a'+10;};
    for(std::size_t index=0;index<hex.size()/2;++index)
        if(code[index]!=(digit(hex[index*2])<<4|digit(hex[index*2+1])))return false;
    return true;
}
bool supported() {
    // Exact build fingerprints include both mutators, their only shared tail,
    // doc/context access, title thunks/bodies, and constructor-proven members.
    static const std::pair<Handle,std::string_view> pairs[]{
        {0x101402e28,"08b705d0002143f9c0035fd6"},
        {0x105e26ab0,"f44fbea9fd7b01a9fd430091f40301aaf30300aad970d796e00000b4e203142ae10313aad61d0094084000d11f0000f1e003889afd7b41a9f44fc2a8c0035fd6"},
        {0x105e2e22c,"ff4301d1f65702a9f44f03a9fd7b04a9fd030191f40302aaf50301aaf30300aaa15303d0210019912c51d796e1000036e0d700a9f41b00b9e1230091e00313aa9d51d79602000014000080d2fd7b44a9f44f43a9f65742a9ff430191c0035fd6"},
        {0x101402704,"fd7bbfa9fd030091000440f9080040f9080d40f900013fd6211c4092fd7bc1a8c0035fd6"},
        {0x1014028e0,"000440f9ef0f0014"},
        {0x101404924,"ff8300d1fd7b01a9fd430091e10700f9000c40f9e123009104000094fd7b41a9ff830091c0035fd6"},
        {0x1014049fc,"ff8300d1fd7b01a9fd430091e10700f9000c40f9e123009105000094"},
        {0x1024e5e34,"ff4301d1f44f03a9fd7b04a9fd030191f40300aaf30308aa1f7d00a91f0900f9"},
        {0x1024e5fa4,"ffc301d1f85f03a9f65704a9f44f05a9fd7b06a9fd830191f30301aaf40300aa"},
        {0x1024e6528,"9ffeff97080040f9081540f900013fd6080c41f8"},
        {0x106c9bad0,"00c000d1c0035fd6"},
        {0x10243e814,"0a2442a90a2500a9890000b428210091"},
        {0x1011c0358,"ffc300d1f44f01a9fd7b02a9fd830091"},
        {0x10629f488,"f44fbea9fd7b01a9fd430091f30300aa"},
        {0x10629cb90,"48008052080800b9010c00f928008052"},
        {0x10629cba8,"080840b91f1d0071c1030054ffc300d1"},
        {0x1011c3738,"00c000d113ffff17"},
        {0x1011c3388,"ffc300d1f44f01a9fd7b02a9fd830091"},
        {0x1011c3ebc,"00c000d1dfffff17"},
        {0x1011c3e3c,"ffc300d1f44f01a9fd7b02a9fd830091"},
        {0x1011bca30,"60b201f977b601f979ba01f975be01f9"},
        {0x1011c036c,"00b841f9080040f9090940f9e8030091"},
        {0x1011bca24,"a9a345a9aa2340f9ac2f41a960b201f977b601f979ba01f975be01f974c201f976c601f96cca01f96bce01f968d201f96ad601f969da01f9"},
        {0x1011bc910,"f40306aaf50305aaf90304aaf70303aaf80302aafa0301aaf30300aa"},
        {0x1011b4c70,"080000f9011000f9f40300aa"},
        {0x1011b5b38,"e80300aa000040f9010100f9c00000b4fd7bbfa9fd030091a66eb695fd7bc1a89c25b914"},
        {0x1011b4df8,"ff4301d1f44f03a9fd7b04a9fd030191"},
        {0x102558330,"ffc300d1f44f01a9fd7b02a9fd830091"},
    };
    for(const auto& [address,hex]:pairs)if(!fingerprint(address,hex))return false;
    return true;
}
bool object(void* pointer,Handle vtable,Handle typeinfo,std::intptr_t offset=0) {
    if(!pointer||*reinterpret_cast<Handle*>(pointer)!=runtime(vtable))return false;
    const auto* table=reinterpret_cast<const Handle*>(runtime(vtable));
    return table[-1]==runtime(typeinfo)&&static_cast<std::intptr_t>(table[-2])==offset;
}
void* member(void* pointer,std::size_t offset) {
    void* result=nullptr;
    std::memcpy(&result,static_cast<const std::byte*>(pointer)+offset,sizeof(result));
    return result;
}
std::string string_result(void* entry,const void* self) {
    rml::qt::QString value;
    struct Storage{void* pointer=nullptr;} storage;
    static_assert(sizeof(storage)==sizeof(value));
    rml::memory::call_returning_member(entry,storage,self);
    std::memcpy(value.storage(),&storage,sizeof(storage));
    return value.to_utf8();
}
std::string name(Widget* widget) {
    static auto* entry=rml::qt::detail::core_export_optional("QObject::objectName() const");
    return entry?string_result(entry,widget):std::string();
}
bool visible(Widget* widget,Widget* window) {
    static const auto entry=rml::qt::detail::widgets_optional<bool(*)(const void*,const void*)>(
        "QWidget::isVisibleTo(QWidget const*) const");
    return entry&&entry(widget,window);
}
bool active(Widget* widget) {
    static const auto entry=rml::qt::detail::widgets_optional<bool(*)(const void*)>("QWidget::isActiveWindow() const");
    return entry&&entry(widget);
}
Widget* top(Widget* widget) {
    static const auto entry=rml::qt::detail::widgets_optional<void*(*)(const void*)>("QWidget::window() const");
    return entry?static_cast<Widget*>(entry(widget)):nullptr;
}
Handle start_page_window() {
    // The StartPage's Qtitan panel is a separate native window. Bind the
    // resulting Edit document to the unique actual Studio MainWindow, never to
    // that panel's window pointer. Any additional MainWindow fails closed.
    constexpr std::string_view start="rplg_sabuiltin_StartPage.rbxm_StartPage";
    Widget *main=nullptr,*page=nullptr,*panel=nullptr;
    unsigned main_count=0,page_count=0,panel_count=0,other_views=0;
    std::string view_names;
    static const auto minimized=rml::qt::detail::widgets_optional<bool(*)(const void*)>("QWidget::isMinimized() const");
    static const auto ancestor=rml::qt::detail::widgets_optional<bool(*)(const void*,const void*)>(
        "QWidget::isAncestorOf(QWidget const*) const");
    if(!minimized||!ancestor){NSLog(@"[custom-templates] Template open StartPage guard: Qt methods unavailable.");return 0;}
    const auto widgets=rml::qt::QApplication::all_widgets();
    for(auto* widget:widgets) {
        if(!widget)continue;
        const std::string_view kind=widget->class_name()?:"";
        if(kind=="RBX::Studio::MainWindow") {
            ++main_count;
            if(top(widget)==widget&&!minimized(widget))main=widget;
        }
        auto* window=top(widget);
        // isVisibleTo(window) alone also accepts children of a hidden window.
        if(!window||!visible(window,nullptr)||!visible(widget,window)||widget->width()<320||widget->height()<180)continue;
        if(kind=="RBX::Studio::QEngineWidget") {
            const auto widget_name=name(widget);
            if(view_names.size()<512)view_names+=widget_name+";";
            if(widget_name==start){page=widget;++page_count;}
            else ++other_views;
        }
        if(kind=="Qtitan::DockWidgetPanel"&&name(widget)==start) {
            panel=widget;++panel_count;
        }
    }
    if(main_count!=1||page_count!=1||panel_count!=1||other_views||!main||!page||!panel||
        !ancestor(panel,page)||(!active(main)&&!active(top(page)))) {
        NSLog(@"[custom-templates] Template open StartPage guard: main=%u page=%u panel=%u otherVisibleViews=%u names=%s.",
            main_count,page_count,panel_count,other_views,view_names.c_str());
        return 0;
    }
    return reinterpret_cast<Handle>(main);
}

void* place_document() {
    // Use the genuine registry-backed IPlaceManager accessor used by Studio's
    // own native callers with (nullptr,false). The legacy RobloxDocManager's
    // current-document slot is empty in the pinned live build. No registry
    // maps, ManagedPtr objects or private iterator returns are recreated here.
    void* registry=function<void*(*)()>(0x101402e28)();
    if(!registry)return nullptr;
    if(!object(registry,0x10c36ec80,0x10c36ec90))
        throw std::runtime_error("Studio's place component registry could not be verified.");
    void* implementation=member(registry,0x8); // Native101402704/1014028E0.
    if(!object(implementation,0x10c36edd0,0x10c36edf8))
        throw std::runtime_error("Studio's place component provider could not be verified.");
    const auto* provider_table=*reinterpret_cast<Handle**>(implementation);
    if(provider_table[0x10/8]!=runtime(0x101404924)||provider_table[0x18/8]!=runtime(0x1014049fc))
        throw std::runtime_error("Studio's place component provider methods changed.");
    void* manager=function<void*(*)(void*,bool)>(0x105e26ab0)(nullptr,false);
    if(!manager)return nullptr;
    if(!object(manager,0x10c838340,0x10c838568))
        throw std::runtime_error("Studio's place manager could not be verified.");
    const auto* table=*reinterpret_cast<Handle**>(manager);
    if(table[0x160/8]!=runtime(0x1024e5e34))
        throw std::runtime_error("Studio's place session accessor changed.");
    // The returned vector and its strings use genuine native C++ value
    // lifetimes. Both rollout branches obtain these IDs from session contexts;
    // the trace ID accessor at+80 is unrelated and is deliberately unused.
    const auto sessions=function<std::vector<std::string>(*)(void*)>(0x1024e5e34)(manager);
    if(sessions.empty())return nullptr;
    // Session IDs can contain the full source path (197 bytes in the retained
    // live fixture), so their bound must accommodate the accepted staging path.
    if(!ctpl::opening::valid_session_set(sessions))
        throw std::runtime_error("Open this template with one editable place session in this Studio window.");
    // Native caller1024E6528 immediately invokes the returned object's+28
    // complete-document accessor, proving this borrowed IRIDE return boundary.
    return function<void*(*)(void*,const std::string&)>(0x1024e5fa4)(manager,sessions.front());
}
bool reset_document(const CtplOpenDocumentContext& document,const std::string& path) {
    if(!pthread_main_np()||!supported())throw std::runtime_error("This Studio build does not support the template destination transition.");
    void* ide=place_document();
    // A not-yet-adopted session is retried only before mutation and within the
    // existing45-second request bound. Nonnull type/path mismatches still fail.
    if(!ide)return false;
    if(!object(ide,0x10c746670,0x10c746748,-0x30))throw std::runtime_error("Studio's active place document could not be verified.");
    auto* ide_table=*reinterpret_cast<Handle**>(ide);
    if(ide_table[0x28/8]!=runtime(0x106c9bad0)||ide_table[0x58/8]!=runtime(0x1011c3738)||
        ide_table[0x68/8]!=runtime(0x1011c3ebc))throw std::runtime_error("Studio's document methods changed.");
    void* complete=function<void*(*)(void*)>(0x106c9bad0)(ide);
    if(!object(complete,0x10c746400,0x10c746748)||
        reinterpret_cast<Handle>(complete)+0x30!=reinterpret_cast<Handle>(ide))
        throw std::runtime_error("Studio's document ownership could not be verified.");
    // These three fields and context dependencies are proven by this build's
    // constructor/getters, not reconstructed class/shared_ptr layouts.
    void* context=member(complete,0x370);
    void* lock=member(complete,0x380);
    void* latest=member(complete,0x3b0);
    if(!object(context,0x10c41a540,0x10c41a608)||!object(lock,0x10c34d640,0x10c34d650)||
        !object(latest,0x10c4253c8,0x10c4253f0)||member(lock,0x20)!=context||member(latest,0x20)!=context)
        throw std::runtime_error("Studio's document session dependencies could not be verified.");
    auto* context_table=*reinterpret_cast<Handle**>(context);
    auto* latest_table=*reinterpret_cast<Handle**>(latest);
    if(context_table[0x10/8]!=runtime(0x10243e814)||latest_table[0x18/8]!=runtime(0x102558330))
        throw std::runtime_error("Studio's document session methods changed.");
    auto configuration=function<std::shared_ptr<Configuration>(*)(void*)>(0x10243e814)(context);
    if(!configuration)throw std::runtime_error("Studio has no active place configuration.");
    const auto filename=string_result(reinterpret_cast<void*>(runtime(0x1011c0358)),complete);
    if(filename!=path)throw std::runtime_error("The active native document is not this template working copy.");
    const auto fresh=ctpl_snapshot_open_document_context();
    if(!fresh||fresh->stable_document_id!=document.stable_document_id||fresh->window!=document.window||fresh->source_path!=path)
        throw std::runtime_error("The active template document changed before its destination could be cleared.");
    rml::qt::QString empty("");
    // Synthesized from native FileNew/Save success operations. No loader,
    // serializer or engine Instance is called or changed here. The isolated
    // lifecycle test must prove the complete transition before installation.
    function<void(*)(Configuration*,const void*)>(0x10629f488)(configuration.get(),empty.data());
    function<void(*)(Configuration*,std::int64_t)>(0x10629cb90)(configuration.get(),0);
    function<void(*)(void*,std::uint32_t)>(0x102558330)(latest,1);
    function<void(*)(void*,void*)>(0x1011b5b38)(static_cast<std::byte*>(lock)+0x28,nullptr);
    function<void(*)(void*)>(0x1011b4df8)(lock);
    function<void(*)(void*)>(0x1011c3738)(ide);
    function<void(*)(void*)>(0x1011c3ebc)(ide);
    if(!string_result(reinterpret_cast<void*>(runtime(0x1011c0358)),complete).empty())
        throw std::runtime_error("Studio did not clear the template's save destination.");
    const auto after=ctpl_snapshot_open_document_context();
    if(!after||after->stable_document_id!=document.stable_document_id||after->window!=document.window)
        throw std::runtime_error("The template's active document identity changed during its destination transition.");
    NSLog(@"[custom-templates] Template destination cleared; native new-place title refreshed.");
    return true;
}

NSString* ns(const std::string& value){return [[NSString alloc]initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding]?:@"";}
std::string json(NSDictionary* value) {
    NSData* data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data?std::string(static_cast<const char*>(data.bytes),data.length):std::string();
}
void clear_request() {
    auto& s=state();s.correlation.cancel();s.source.reset();s.failure.clear();s.busy.store(false);
}
bool publish(const std::string& value,std::uint64_t epoch) {
    auto& s=state();std::lock_guard lock(s.publication);
    return s.active.load()&&s.epoch.load()==epoch&&ctpl_try_post_command(value);
}
void deliver() {
    auto& s=state();
    const auto ticket=s.correlation.ticket();
    if(!s.failure.empty()) {
        if(publish(json(@{@"type":@"template_open_failed",@"requestId":ns(ticket.request_id),@"message":ns(s.failure)}),s.request_epoch))
            clear_request();
        return;
    }
    if(s.correlation.completed_id().empty())return;
    const auto value=json(@{@"type":@"template_opened",@"requestId":ns(ticket.request_id),@"path":ns(ticket.path),
        @"stableDocumentId":ns(s.correlation.completed_id())});
    if(s.correlation.delivered(ticket,publish(value,s.request_epoch))) {
        s.source.reset();s.busy.store(false);
        NSLog(@"[custom-templates] Template open completed and linked.");
    }
}
void fail(std::string message) {
    auto& s=state();if(!s.correlation.pending())return;
    if(!s.correlation.completed_id().empty()){deliver();return;}
    s.failure=std::move(message);deliver();
}
void tick() {
    auto& s=state();
    if(!s.active.load()||!s.correlation.pending())return;
    if(s.request_epoch!=s.epoch.load()){clear_request();return;}
    ctpl_filemenu_set_state(false,{});
    if(!s.failure.empty()||!s.correlation.completed_id().empty()){deliver();return;}
    if(Clock::now()-s.started>std::chrono::seconds(45)) {
        fail("Studio did not expose the exact template working copy before the open request timed out.");return;
    }
    if(!s.source||!s.source->unchanged()){fail("The template working file changed while Studio was opening it.");return;}
    auto document=ctpl_snapshot_open_document_context();
    if(!document)return;
    const ctpl::opening::Document candidate{document->stable_document_id,document->source_path,document->window};
    if(!s.correlation.candidate(candidate,true))return;
    const auto ticket=s.correlation.ticket();
    if(!reset_document(*document,ticket.path))return;
    if(!s.active.load()||s.request_epoch!=s.epoch.load())return;
    s.correlation.reset_complete(ticket,document->stable_document_id);
    deliver();
}
void begin(std::string request,std::string id,std::string path,std::uint64_t epoch) {
    auto& s=state();
    if(!s.active.load()||s.epoch.load()!=epoch){s.busy.store(false);return;}
    const auto window=start_page_window();
    // Install a request ticket even on GUI validation failure, so the error is
    // delivered through the matching requestId and retried if the queue is full.
    if(!s.correlation.begin({request,id,path},window?window:1,ctpl_snapshot_known_document_ids())) {
        s.busy.store(false);return;
    }
    s.request_epoch=epoch;s.started=Clock::now();ctpl_filemenu_set_state(false,{});
    try {
        if(!s.timer_ready.load())throw std::runtime_error("Studio's template opening timer is unavailable.");
        if(!window)throw std::runtime_error("Open this template from Studio's Templates page with one Studio window.");
        auto* home=NSHomeDirectory().fileSystemRepresentation;
        s.source=std::make_unique<ctpl::opening::OwnedSource>(
            std::filesystem::path(home)/"Library/Application Support/RobloxCustomTemplates",request,path);
        NSURL* file=[NSURL fileURLWithPath:ns(path)];
        auto* configuration=[NSWorkspaceOpenConfiguration configuration];
        configuration.activates=YES;configuration.createsNewApplicationInstance=NO;
        [NSWorkspace.sharedWorkspace openURLs:@[file] withApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration
            completionHandler:^(__unused NSRunningApplication* application,NSError* error) {
                if(!error)return;
                ctpl::dispatch_gui([request,epoch]{
                    auto& s=state();
                    if(s.active.load()&&s.epoch.load()==epoch&&s.correlation.pending()&&s.correlation.ticket().request_id==request)
                        fail("Studio could not open the template working copy.");
                });
            }];
        NSLog(@"[custom-templates] Template open waiting for its exact Edit document.");
    }catch(const std::exception& error){fail(error.what());}
}
} // namespace

bool ctpl_template_open_start() {
    if(!supported())return false;
    auto& s=state();s.active.store(true);s.epoch.fetch_add(1);
    ctpl::dispatch_gui([]{
        auto& s=state();clear_request();
        if(!s.timer) {
            s.timer=rml::qt::QTimer::create(nullptr);
            if(s.timer){s.timer->setInterval(100);s.timer->on_timeout([]{
                try{tick();}catch(const std::exception& error){fail(error.what());}
                catch(...){fail("Studio could not finish opening this template as a new place.");}
            });}
        }
        if(s.timer){s.timer->start();s.timer_ready.store(true);}
        else {s.timer_ready.store(false);s.active.store(false);NSLog(@"[custom-templates] Template opening disabled: GUI timer creation failed.");}
    });
    return true;
}
void ctpl_template_open_stop() {
    auto& s=state();
    {std::lock_guard lock(s.publication);s.active.store(false);s.epoch.fetch_add(1);s.busy.store(false);s.timer_ready.store(false);}
    ctpl::dispatch_gui([]{clear_request();if(state().timer)state().timer->stop();});
}
bool ctpl_template_open_pending(){return state().busy.load();}
extern "C" RML_EXPORT bool ctpl_open_template(const char* input) noexcept {
    if(!input||!state().active.load()||!state().timer_ready.load())return false;
    try { @autoreleasepool {
        const auto length=strnlen(input,16385);if(length>16384)return false;
        id value=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:input length:length] options:0 error:nil];
        if(![value isKindOfClass:NSDictionary.class])return false;
        auto string=[&](NSString* key)->std::string {
            id field=value[key];return [field isKindOfClass:NSString.class]?std::string([field UTF8String]?:""):std::string();
        };
        auto request=string(@"requestId"),id=string(@"id"),path=string(@"path");
        if(!ctpl::opening::uuid(request)||!ctpl::opening::uuid(id)||path.empty()||path.size()>8192||path.find('\0')!=std::string::npos)return false;
        bool expected=false;if(!state().busy.compare_exchange_strong(expected,true))return false;
        const auto epoch=state().epoch.load();
        ctpl::dispatch_gui([request,id,path,epoch]{begin(request,id,path,epoch);});
        return true;
    }}catch(...){state().busy.store(false);return false;}
}
