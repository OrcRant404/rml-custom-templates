#include "TemplateOpenSource.hpp"
#include "TemplateOpenState.hpp"

#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <cstdlib>
#include <sys/xattr.h>

namespace fs=std::filesystem;
using namespace ctpl::opening;
namespace {
constexpr const char* request="11111111-2222-3333-4444-555555555555";
constexpr const char* template_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
int assertions=0;
void check(bool condition,const char* message) {
    ++assertions;
    if(!condition)throw std::runtime_error(message);
}
template<class F> void rejects(F&& operation,const char* message) {
    bool threw=false;
    try{operation();}catch(const std::exception&){threw=true;}
    check(threw,message);
}
void put(const fs::path& path,const std::string& content="<roblox!fixture") {
    std::ofstream(path,std::ios::binary)<<content;
    if(chmod(path.c_str(),0600))throw std::runtime_error("chmod fixture failed");
}
struct Fixture {
    fs::path root,folder,file;
    Fixture() {
        char name[]="/tmp/ctpl-native-open-XXXXXX";
        if(!mkdtemp(name))throw std::runtime_error("mkdtemp failed");
        root=fs::canonical(name);
        folder=root/"working"/"0123456789abcdef0123456789abcdef";
        fs::create_directories(folder);
        file=folder/(std::string("CTPL-OPEN-")+request+".rbxl");
        put(file);
    }
    ~Fixture(){std::error_code ignored;fs::remove_all(root,ignored);}
};
void source_checks() {
    Fixture f;
    {
        OwnedSource source(f.root,request,f.file.string());
        check(source.unchanged(),"new working copy must validate");
        fs::rename(f.file,f.file.string()+".old");
        put(f.file);
        check(!source.unchanged(),"replaced path must not authorize reset");
    }
    check(fs::exists(f.file),"borrowed working copy must survive destructor");
    {
        OwnedSource source(f.root,request,f.file.string());
        struct stat before{},after{};
        check(!stat(f.file.c_str(),&before),"xattr baseline stat must succeed");
        constexpr char attribute[]="ctpl-last-used";
#if defined(__APPLE__)
        check(!setxattr(f.file.c_str(),"com.apple.lastuseddate#PS",attribute,sizeof(attribute),0,0),"actual last-used xattr write must succeed");
#else
        check(!setxattr(f.file.c_str(),"user.ctpl.lastused",attribute,sizeof(attribute),0),"actual last-used xattr write must succeed");
#endif
        check(!stat(f.file.c_str(),&after),"xattr updated stat must succeed");
#if defined(__APPLE__)
        check(before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
            "xattr write must preserve original content mtime");
        check(before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec||before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec,
            "regression must exercise a real ctime change");
#else
        check(before.st_mtim.tv_sec==after.st_mtim.tv_sec&&before.st_mtim.tv_nsec==after.st_mtim.tv_nsec,
            "xattr write must preserve original content mtime");
        check(before.st_ctim.tv_sec!=after.st_ctim.tv_sec||before.st_ctim.tv_nsec!=after.st_ctim.tv_nsec,
            "regression must exercise a real ctime change");
#endif
        check(source.unchanged(),"metadata-only xattr change must pass content comparison");
        check(source.unchanged(),"accepted metadata stamp must remain usable on next poll");
        std::fstream changed(f.file,std::ios::in|std::ios::out|std::ios::binary);
        changed.seekp(9);changed.put('X');changed.flush();changed.close();
#if defined(__APPLE__)
        const struct timespec times[]{before.st_atimespec,before.st_mtimespec};
#else
        const struct timespec times[]{before.st_atim,before.st_mtim};
#endif
        check(!utimensat(AT_FDCWD,f.file.c_str(),times,0),"test must restore original mtime after same-size edit");
        struct stat restored{};
        check(!stat(f.file.c_str(),&restored)&&restored.st_ino==before.st_ino&&restored.st_size==before.st_size,
            "restored-mtime regression must preserve source inode and size");
#if defined(__APPLE__)
        check(restored.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec&&restored.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,
            "restored-mtime regression must exercise unchanged original mtime");
#else
        check(restored.st_mtim.tv_sec==before.st_mtim.tv_sec&&restored.st_mtim.tv_nsec==before.st_mtim.tv_nsec,
            "restored-mtime regression must exercise unchanged original mtime");
#endif
        check(!source.unchanged(),"content edit with restored mtime must fail original SHA-256 comparison");
    }
    {
        OwnedSource source(f.root,request,f.file.string());
        const auto renamed=f.folder.string()+"-moved";
        fs::rename(f.folder,renamed);
        check(!source.unchanged(),"renamed parent must invalidate source");
        fs::rename(renamed,f.folder);
        fs::rename(f.folder,renamed);
        fs::create_directory_symlink(renamed,f.folder);
        check(!source.unchanged(),"symlink parent must invalidate held inode");
        fs::remove(f.folder);fs::rename(renamed,f.folder);
    }
    chmod(f.file.c_str(),0400);
    rejects([&]{OwnedSource source(f.root,request,f.file.string());},"stored read-only snapshot must not be accepted");
    chmod(f.file.c_str(),0600);
    rejects([&]{OwnedSource source(f.root,template_id,f.file.string());},"request basename must match");
    const auto hardlink=f.folder/"hardlink.rbxl";
    fs::create_hard_link(f.file,hardlink);
    rejects([&]{OwnedSource source(f.root,request,f.file.string());},"hardlinked snapshot must not be accepted");
    fs::remove(hardlink);
    const auto alternate=f.folder/"alternate.rbxl";
    fs::rename(f.file,alternate);fs::create_symlink(alternate,f.file);
    rejects([&]{OwnedSource source(f.root,request,f.file.string());},"symlink source must not be accepted");
    fs::remove(f.file);fs::rename(alternate,f.file);
    put(f.file,"invalid fixture");
    rejects([&]{OwnedSource source(f.root,request,f.file.string());},"non-place header must fail");
    put(f.file,"<roblox version=\"4\"></roblox>");
    check(OwnedSource(f.root,request,f.file.string()).unchanged(),"XML places must validate");
    put(f.file,"<?xml version=\"1.0\"?><roblox version=\"4\"></roblox>");
    check(OwnedSource(f.root,request,f.file.string()).unchanged(),"XML declaration must validate");
    put(f.file,"\xef\xbb\xbf\r\n<roblox version=\"4\"></roblox>");
    check(OwnedSource(f.root,request,f.file.string()).unchanged(),"BOM and XML whitespace must validate");
    {
        OwnedSource source(f.root,request,f.file.string());
        std::fstream changed(f.file,std::ios::in|std::ios::out|std::ios::binary);
        changed.seekp(14);changed.put('X');changed.flush();
        check(!source.unchanged(),"same-size in-place content changes must invalidate source");
    }
    const auto outside=f.root/"templates";
    fs::create_directory(outside);
    const auto snapshot=outside/f.file.filename();put(snapshot);
    rejects([&]{OwnedSource source(f.root,request,snapshot.string());},"stored template directory must fail");
    chmod(f.folder.c_str(),0777);
    rejects([&]{OwnedSource source(f.root,request,f.file.string());},"writable-by-others folder must fail");
    chmod(f.folder.c_str(),0755);
}
void correlation_checks() {
    Fixture f;
    Correlation state;
    const auto path=f.file.string();
    check(state.begin({request,template_id,path},42,{"ctpl:10:old"}),"first request must start");
    const auto first=state.ticket();
    check(!state.begin({template_id,template_id,path},42,{}),"second request must preserve first");
    check(state.current(first),"busy request must preserve original ticket");
    check(!state.candidate({"ctpl:10:old",path,42},true),"old model must not bind");
    check(!state.candidate({"ctpl:10:new",path,43},true),"different window must not bind");
    check(!state.candidate({"ctpl:10:new",path+".other",42},true),"different document path must not bind");
    check(!state.candidate({"",path,42},true),"missing model identity must not bind");
    check(!state.candidate({"ctpl:10:new",path,42},false),"changed source must not bind");
    check(state.candidate({"ctpl:10:new",path,42},true),"new model with exact source must bind");
    state.cancel();
    check(!state.current(first)&&!state.candidate({"ctpl:10:new",path,42},true),"cancel must reject late completion");
    check(fs::exists(f.file),"cancel must preserve borrowed working copy");
    check(state.begin({request,template_id,path},42,{}),"request can restart after cancel");
    check(!state.current(first),"reused request ID must still reject old generation");
    const auto second=state.ticket();
    check(state.reset_complete(second,"ctpl:10:new"),"successful reset must record document identity");
    check(!state.reset_complete(second,"ctpl:10:other"),"delivery retry must not repeat a reset");
    check(!state.delivered(second,false)&&state.pending(),"full queue must retain pending link");
    check(state.completed_id()=="ctpl:10:new", "queue retry must preserve exact completed identity");
    check(state.delivered(second,true)&&!state.pending(),"accepted queue must release pending request");
    check(!state.delivered(second,true),"late duplicate completion must not deliver twice");
    state.cancel();
}
void session_checks() {
    check(valid_session_set({std::string(197,'p')}),"native path-derived197-byte session ID must pass");
    check(valid_session_set({std::string(16384,'p')}),"accepted long staging session ID must pass");
    check(!valid_session_set({std::string(16385,'p')}),"oversized session ID must fail");
    check(!valid_session_set({}),"no native session must not authorize a reset");
    check(!valid_session_set({""}),"empty native session ID must fail");
    check(!valid_session_set({"one","two"}),"multiple native sessions must fail closed");
    check(!valid_session_set({std::string("one\0other",9)}),"embedded NUL session ID must fail");
}
}
int main() {
    try {
        source_checks();correlation_checks();session_checks();
        std::cout<<"Template opening: "<<assertions<<" source ownership, document correlation and native session checks passed.\n";
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
