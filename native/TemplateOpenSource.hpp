#pragma once

#include <array>
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <string_view>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CommonCrypto/CommonDigest.h>

namespace ctpl::opening {

inline bool uuid(std::string_view value) {
    if (value.size() != 36) return false;
    for (std::size_t index = 0; index < value.size(); ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) { if (value[index] != '-') return false; }
        else if (!((value[index] >= '0' && value[index] <= '9') || (value[index] >= 'a' && value[index] <= 'f'))) return false;
    }
    return true;
}
inline bool working_directory(std::string_view value) {
    if (uuid(value)) return true;
    return value.size() == 32 && value.find_first_not_of("0123456789abcdef") == std::string_view::npos;
}

// Borrows the managed-created writable working copy. It never deletes or
// modifies that file, including on cancel. Retain the descriptor so replacing
// its pathname cannot authorize resetting a different open document.
class OwnedSource {
public:
    OwnedSource(const std::filesystem::path& root, const std::string& request_id, const std::string& path) {
        namespace fs = std::filesystem;
        if (!uuid(request_id) || !root.is_absolute() || !fs::path(path).is_absolute() ||
            root.lexically_normal() != root || fs::path(path).lexically_normal() != fs::path(path) ||
            fs::canonical(root) != root || fs::canonical(path) != fs::path(path))
            throw std::runtime_error("The template working path is not canonical.");
        const auto relative = fs::path(path).lexically_relative(root);
        auto part = relative.begin();
        if (part == relative.end() || *part++ != "working" || part == relative.end())
            throw std::runtime_error("The template must open from its private working folder.");
        const auto folder = part++->string();
        if (!working_directory(folder) || part == relative.end())
            throw std::runtime_error("The template working folder has an invalid identity.");
        const auto filename = part++->string();
        if (part != relative.end() || (filename != "CTPL-OPEN-" + request_id + ".rbxl" &&
            filename != "CTPL-OPEN-" + request_id + ".rbxlx"))
            throw std::runtime_error("The template working filename does not match this request.");
        int parent = open(root.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (parent < 0) throw std::runtime_error("The template catalog folder could not be opened.");
        try {
            check_directory(parent);
            for (const auto& name : {std::string("working"), folder}) {
                const int child = openat(parent, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (child < 0) throw std::runtime_error("The template working folder could not be opened.");
                close(parent); parent = child; check_directory(parent);
            }
            file_ = openat(parent, filename.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            if (file_ < 0 || fstat(file_, &identity_) || !S_ISREG(identity_.st_mode) || identity_.st_uid != getuid() ||
                identity_.st_nlink != 1 || (identity_.st_mode & 077) || !(identity_.st_mode & S_IWUSR) ||
                identity_.st_size < 8 || identity_.st_size > 512LL * 1024 * 1024)
                throw std::runtime_error("The template working file is not a private writable place copy.");
            std::array<char, 256> header{};
            const auto count=pread(file_,header.data(),header.size(),0);
            std::string_view prefix(header.data(),count>0?static_cast<std::size_t>(count):0);
            if(prefix.starts_with("\xef\xbb\xbf"))prefix.remove_prefix(3);
            while(!prefix.empty()&&(prefix.front()==' '||prefix.front()=='\r'||prefix.front()=='\n'||prefix.front()=='\t'))prefix.remove_prefix(1);
            if(count<8||(!prefix.starts_with("<roblox!")&&!prefix.starts_with("<roblox ")&&
                !prefix.starts_with("<roblox>")&&!prefix.starts_with("<roblox/")&&!prefix.starts_with("<?xml")))
                throw std::runtime_error("The template working file has no supported place header.");
            path_ = path;
            if(!hash(content_))throw std::runtime_error("The template working file could not be verified.");
            struct stat after{};
            if(fstat(file_,&after)||!valid_identity(after)||!same_change(after,identity_))
                throw std::runtime_error("The template working file changed while it was being verified.");
            accepted_=after;
            close(parent);
        } catch (...) { close(parent); if (file_ >= 0) close(file_); file_ = -1; throw; }
    }
    ~OwnedSource() { if (file_ >= 0) close(file_); }
    OwnedSource(const OwnedSource&) = delete;
    OwnedSource& operator=(const OwnedSource&) = delete;
    bool unchanged() const {
        if(invalid_)return false;
        struct stat current{}, held{};
        if(!metadata(current,held))return invalidate();
        if(same_change(current,accepted_))return true;
        // NSWorkspace writes last-used/provenance xattrs, changing ctime even
        // though the place bytes and mtime stay unchanged. Rehash only after a
        // new ctime, and cache that stamp only after verifying stable bytes.
        // A same-size edit with a restored mtime still changes ctime and must
        // pass this comparison with the original, pre-open content digest.
        for(unsigned attempt=0;attempt<3;++attempt) {
            Digest observed{};
            if(!hash(observed)||observed!=content_)return invalidate();
            struct stat after{},after_held{};
            if(!metadata(after,after_held))return invalidate();
            if(same_change(after,current)){accepted_=after;return true;}
            current=after;
        }
        return invalidate();
    }
private:
    using Digest=std::array<unsigned char,CC_SHA256_DIGEST_LENGTH>;
    bool invalidate() const {invalid_=true;return false;}
    bool hash(Digest& result) const {
        CC_SHA256_CTX context;
        if(CC_SHA256_Init(&context)!=1)return false;
        std::array<unsigned char,64*1024> buffer{};
        off_t offset=0;
        while(offset<identity_.st_size) {
            const auto count=pread(file_,buffer.data(),std::min<off_t>(buffer.size(),identity_.st_size-offset),offset);
            if(count<0&&errno==EINTR)continue;
            if(count<=0||CC_SHA256_Update(&context,buffer.data(),static_cast<CC_LONG>(count))!=1)return false;
            offset+=count;
        }
        return CC_SHA256_Final(result.data(),&context)==1;
    }
    bool valid_identity(const struct stat& value) const {
        return S_ISREG(value.st_mode)&&value.st_uid==getuid()&&value.st_nlink==1&&
            !(value.st_mode&077)&&(value.st_mode&S_IWUSR)&&value.st_dev==identity_.st_dev&&
            value.st_ino==identity_.st_ino&&value.st_size==identity_.st_size&&same_modification(value,identity_);
    }
    bool metadata(struct stat& current,struct stat& held) const {
        std::error_code error;
        return std::filesystem::canonical(path_,error)==std::filesystem::path(path_)&&!error&&file_>=0&&
            !lstat(path_.c_str(),&current)&&!fstat(file_,&held)&&valid_identity(current)&&valid_identity(held)&&same_change(current,held);
    }
    static bool same_modification(const struct stat& a,const struct stat& b) {
#if defined(__APPLE__)
        return a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec&&a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec;
#else
        return a.st_mtim.tv_sec==b.st_mtim.tv_sec&&a.st_mtim.tv_nsec==b.st_mtim.tv_nsec;
#endif
    }
    static bool same_change(const struct stat& a,const struct stat& b) {
#if defined(__APPLE__)
        return a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec&&a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
#else
        return a.st_ctim.tv_sec==b.st_ctim.tv_sec&&a.st_ctim.tv_nsec==b.st_ctim.tv_nsec;
#endif
    }
    static void check_directory(int descriptor) {
        struct stat value{};
        if (fstat(descriptor, &value) || !S_ISDIR(value.st_mode) || value.st_uid != getuid() || (value.st_mode & 022))
            throw std::runtime_error("The template working folder is not owned by the current user.");
    }
    int file_ = -1;
    struct stat identity_{};
    Digest content_{};
    mutable struct stat accepted_{};
    mutable bool invalid_=false;
    std::string path_;
};

} // namespace ctpl::opening
