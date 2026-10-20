// scripts/test-current generates this include from the actual production
// parser and Stage definitions. It never connects to or launches Studio.
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "current_snapshot_under_test.inc"

namespace {
namespace fs = std::filesystem;

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

std::string read_file(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    require(static_cast<bool>(input), "Could not open fixture " + path.filename().string());
    std::ostringstream bytes;
    bytes << input.rdbuf();
    require(!input.bad(), "Could not read fixture " + path.filename().string());
    return bytes.str();
}

void write_file(const fs::path& path) {
    std::ofstream output(path, std::ios::binary);
    output << "filesystem ownership fixture";
    require(static_cast<bool>(output), "Could not create filesystem fixture.");
}

struct TemporaryDirectory {
    fs::path path;
    TemporaryDirectory() {
        const auto pattern = (fs::temp_directory_path() / "ctpl-current-save-XXXXXX").string();
        std::vector<char> buffer(pattern.begin(), pattern.end());
        buffer.push_back('\0');
        char* created = mkdtemp(buffer.data());
        require(created != nullptr, "Could not create private test directory.");
        path = created;
    }
    ~TemporaryDirectory() {
        std::error_code ignored;
        fs::remove_all(path, ignored);
    }
};

std::shared_ptr<Stage> make_stage(const fs::path& directory) {
    fs::create_directories(directory);
    auto stage = std::make_shared<Stage>();
    stage->directory = open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    require(stage->directory >= 0, "Could not open test staging directory.");
    stage->temporary = ".stage-test.tmp";
    write_file(directory / stage->temporary);
    return stage;
}

int framing_checks(const fs::path& path) {
    const auto label = path.filename().string();
    const auto original = read_file(path);
    require(complete_binary_place(original), label + ": valid bundled place rejected.");
    require(original.size() > 48, label + ": fixture is too small for corruption cases.");

    auto bad_signature = original;
    bad_signature.front() ^= 1;
    require(!complete_binary_place(bad_signature), label + ": corrupt signature accepted.");
    require(!complete_binary_place(original.substr(0, original.size() - 1)),
            label + ": truncated place accepted.");
    require(!complete_binary_place(original + "trailing bytes"), label + ": trailing data accepted.");
    auto oversized_chunk = original;
    std::memset(oversized_chunk.data() + 36, 0xff, 4);
    require(!complete_binary_place(oversized_chunk), label + ": oversized chunk accepted.");
    require(!complete_binary_place(original.substr(0, 32)), label + ": header-only stream accepted.");
    auto bad_end = original;
    bad_end.back() ^= 1;
    require(!complete_binary_place(bad_end), label + ": corrupt END payload accepted.");
    auto no_classes = original;
    std::memset(no_classes.data() + 16, 0, 4);
    require(!complete_binary_place(no_classes), label + ": zero-class place accepted.");
    auto no_instances = original;
    std::memset(no_instances.data() + 20, 0, 4);
    require(!complete_binary_place(no_instances), label + ": zero-instance place accepted.");
    std::memset(no_instances.data() + 16, 0, 4);
    require(!complete_binary_place(no_instances), label + ": zero-class/instance place accepted.");
    return 10;
}

int empty_snapshot_check(const fs::path& path) {
    const auto original = read_file(path);
    auto empty = original.substr(0, 32);
    std::memset(empty.data() + 16, 0, 8);
    // Actual native regression: valid 79-byte RBXL framing containing an empty
    // compressed PRNT chunk and END, generated from the wrong object subview.
    empty.append("PRNT\x06\0\0\0\x05\0\0\0\0\0\0\0\x50\0\0\0\0\0", 22);
    empty.append(original, original.size() - 25, 25);
    require(empty.size() == 79 && !complete_binary_place(empty),
            "The complete empty native snapshot was accepted as a place.");
    return 1;
}

void ownership_checks() {
    TemporaryDirectory root;
    {
        const auto dir = root.path / "cancelled";
        auto stage = make_stage(dir);
        write_file(dir / "place.rbxl");
        write_file(dir / "thumbnail.png");
        stage->place_created = true;
        stage->thumbnail_created = true;
        stage.reset();
        require(!fs::exists(dir / "place.rbxl") && !fs::exists(dir / "thumbnail.png") &&
                !fs::exists(dir / ".stage-test.tmp"), "Cancelled native staging files were left behind.");
    }
    {
        const auto dir = root.path / "delivered";
        auto stage = make_stage(dir);
        write_file(dir / "place.rbxl");
        write_file(dir / "thumbnail.png");
        stage->place_created = true;
        stage->thumbnail_created = true;
        stage->delivered = true;
        stage.reset();
        require(fs::exists(dir / "place.rbxl") && fs::exists(dir / "thumbnail.png") &&
                !fs::exists(dir / ".stage-test.tmp"), "Staging cleanup removed managed-owned output.");
    }
    {
        const auto dir = root.path / "unowned";
        auto stage = make_stage(dir);
        write_file(dir / "place.rbxl");
        stage.reset();
        require(fs::exists(dir / "place.rbxl"), "Staging cleanup removed a file it did not create.");
    }
    {
        const auto dir = root.path / "deferred";
        auto stage = make_stage(dir);
        write_file(dir / "place.rbxl");
        stage->place_created = true;
        auto pending_callback = stage;
        stage.reset();
        require(fs::exists(dir / "place.rbxl"), "An in-flight owner lost its snapshot prematurely.");
        pending_callback.reset();
        require(!fs::exists(dir / "place.rbxl"), "A cancelled deferred owner left its snapshot behind.");
    }
    {
        const auto dir = root.path / "renamed";
        auto stage = make_stage(dir);
        write_file(dir / "place.rbxl");
        stage->place_created = true;
        const auto original_directory = root.path / "renamed-original";
        fs::rename(dir, original_directory);
        fs::create_directory(dir);
        write_file(dir / "place.rbxl");
        stage.reset();
        require(fs::exists(dir / "place.rbxl") && !fs::exists(original_directory / "place.rbxl"),
                "Staging cleanup escaped its owned directory descriptor.");
    }
}
} // namespace

int main(int argc, char** argv) {
    try {
        require(argc == 4, "Expected three bundled Studio binary-place fixtures.");
        int framing = 0;
        for (int index = 1; index < argc; ++index) framing += framing_checks(argv[index]);
        framing += empty_snapshot_check(argv[1]);
        ownership_checks();
        std::cout << framing << " binary framing/nonempty checks across three bundled places; "
                     "5 staging ownership/cancellation cases passed (ASAN + UBSan).\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Current-place snapshot regression: " << error.what() << '\n';
        return 1;
    }
}
