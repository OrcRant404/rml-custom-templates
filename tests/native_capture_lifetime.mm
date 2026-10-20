#ifndef CTPL_TEST_SOURCE
#define CTPL_TEST_SOURCE "../native/OwnWindowCapture.mm"
#endif
#include CTPL_TEST_SOURCE
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <thread>
#include <vector>

namespace {
std::atomic<unsigned> completions{0}, deleted{0}, images_deleted{0};
std::weak_ptr<Request> lifetime;
std::string staging_folder;
const std::string marker(4096, 'V');

std::string make_temporary_directory(const char *name) {
    const auto parent = std::filesystem::canonical(std::filesystem::temp_directory_path());
    const auto pattern = (parent / (std::string(name) + "-XXXXXX")).string();
    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    char *directory = mkdtemp(writable.data());
    assert(directory);
    return directory;
}

Context tracked_request() {
    Context request(new Request(), [](Request* value) { ++deleted; delete value; });
    request->path = marker;
    request->completion = [](bool ok, std::string reason) {
        assert(pthread_main_np());
        assert(!ok && !reason.empty());
        ++completions;
    };
    lifetime = request;
    return request;
}
Image tracked_image() {
    OwnedCF<CGColorSpaceRef> color(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    OwnedCF<CGContextRef> bitmap(CGBitmapContextCreate(nullptr, 640, 360, 8, 640 * 4, color.get(),
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big)));
    assert(bitmap.get());
    CGContextSetRGBFillColor(bitmap.get(), 0, 1, 0, 1);
    CGContextFillRect(bitmap.get(), CGRectMake(0, 0, 640, 360));
    return Image(CGBitmapContextCreateImage(bitmap.get()), [](CGImageRef image) { ++images_deleted; CGImageRelease(image); });
}
__attribute__((noinline)) void schedule_main() {
    Context request = tracked_request();
    const std::weak_ptr<Request> weak = request;
    main_step(request, [weak] {
        const auto alive = weak.lock();
        assert(alive && alive->path == marker);
        finish(alive, false, "main done");
    });
}
__attribute__((noinline)) void schedule_rejection() {
    std::string reason(4096, 'R');
    reject([](bool ok, std::string result) {
        assert(pthread_main_np() && !ok && result == std::string(4096, 'R'));
        ++completions;
    }, reason);
}
__attribute__((noinline)) void schedule_screenshot() {
    Context request = tracked_request();
    ScreenshotCompletion callback = screenshot_completion(request, 640, 360, CGRectMake(0, 0, 640, 360));
    dispatch_async(worker_queue(), ^{ callback(nullptr, nil); });
}
__attribute__((noinline)) void schedule_image() {
    Context request = tracked_request();
    Image image = tracked_image();
    prepare_output(request, image, CGRectMake(0, 0, 640, 360));
}
__attribute__((noinline)) void schedule_staging() {
    Context request = tracked_request();
    staging_folder = make_temporary_directory("ctpl-lifetime-test");
    request->path = staging_folder + "/cropped.png";
    @autoreleasepool {
        Image image = tracked_image();
        NSData* png = encode_viewport(image.get(), CGRectMake(0, 0, 640, 360));
#ifdef CTPL_REPRO_NESTED
        // The exact pre-fix pattern: an Objective-C block reaches a C++
        // lambda's captured members through a lambda object already destroyed.
        std::function<void()> expired_action = [request, png] {
            dispatch_async(worker_queue(), ^{
                assert(!request->path.empty() && png.length > 8);
                auto staged = stage_png(png, request->path);
                main_step(request, [request, staged] { finish(request, false, "nested done"); });
            });
        };
        expired_action();
#else
        stage_output(request, png);
#endif
    }
}
void clobber_stack() {
    volatile char overwrite[16384];
    for (size_t index = 0; index < sizeof(overwrite); ++index) overwrite[index] = static_cast<char>(index);
}
}

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string test = argv[1];
    @autoreleasepool {
        dispatch_suspend(worker_queue());
        if (test == "main") schedule_main();
        else if (test == "reject") schedule_rejection();
        else if (test == "screenshot") schedule_screenshot();
        else if (test == "image") schedule_image();
        else if (test == "nested") schedule_staging();
        else assert(false);
        // All caller-local shared_ptr/string/Image/lambda objects have now left
        // scope. No deferred callback could have run on the suspended worker.
        clobber_stack();
        assert(completions == 0);
        dispatch_resume(worker_queue());
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (completions.load() == 0 && std::chrono::steady_clock::now() < deadline)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
        assert(completions == 1);
        dispatch_sync(worker_queue(), ^{});
        // Drain main dispatch releases and verify that the deferred ownership
        // does not leak its request, image, or staged file after completion.
        for (unsigned pass = 0; pass < 5; ++pass) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
        assert(completions == 1);
        if (test != "reject") assert(lifetime.expired() && deleted == 1);
        if (test == "image" || test == "nested") assert(images_deleted == 1);
        if (!staging_folder.empty()) {
            assert(std::filesystem::is_empty(staging_folder));
            assert(rmdir(staging_folder.c_str()) == 0);
        }
        std::printf("PASS: %s deferred ownership after caller scope ends\n", test.c_str());
    }
}
