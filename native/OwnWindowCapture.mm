#include "OwnWindowCapture.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

namespace {
constexpr std::size_t kWidth = 640, kHeight = 360;
constexpr std::size_t kMaximumDimension = 8192, kMaximumPixels = 32 * 1024 * 1024;
constexpr std::size_t kMaximumPngBytes = 8 * 1024 * 1024;
constexpr unsigned kMaximumPending = 2;
constexpr double kGeometryTolerance = 0.25;
std::atomic<unsigned> g_pending{0};

template<class T> class OwnedCF {
public:
    explicit OwnedCF(T value = nullptr) : value_(value) {}
    ~OwnedCF() { if (value_) CFRelease(value_); }
    OwnedCF(const OwnedCF&) = delete;
    OwnedCF& operator=(const OwnedCF&) = delete;
    T get() const { return value_; }
private:
    T value_;
};
using Image = std::shared_ptr<std::remove_pointer_t<CGImageRef>>;

struct Geometry {
    NSRect bounds{}, visible{}, window_frame{}, primary_frame{};
    CGRect window_quartz{}, viewport_quartz{};
    CGFloat backing_scale = 0;
    NSInteger window_id = 0;
};
struct Request {
    NSView* __strong view = nil;
    NSWindow* __strong window = nil;
    Geometry geometry;
    std::string path;
    std::function<void(bool, std::string)> completion;
    std::atomic<bool> finished{false};
    bool counted = false;
    ~Request() { if (counted) g_pending.fetch_sub(1, std::memory_order_acq_rel); }
};
using Context = std::shared_ptr<Request>;

struct StagedFile {
    int directory = -1;
    dev_t device = 0;
    ino_t inode = 0;
    std::string temporary, destination, parent;
    ~StagedFile() {
        if (directory >= 0) {
            if (!temporary.empty()) unlinkat(directory, temporary.c_str(), 0);
            close(directory);
        }
    }
};

bool near(double a, double b, double tolerance = kGeometryTolerance) {
    return std::isfinite(a) && std::isfinite(b) && std::abs(a - b) <= tolerance;
}
bool same_rect(CGRect a, CGRect b, double tolerance = kGeometryTolerance) {
    return near(a.origin.x, b.origin.x, tolerance) && near(a.origin.y, b.origin.y, tolerance) &&
        near(a.size.width, b.size.width, tolerance) && near(a.size.height, b.size.height, tolerance);
}
bool positive_rect(CGRect value) {
    return std::isfinite(value.origin.x) && std::isfinite(value.origin.y) &&
        std::isfinite(value.size.width) && std::isfinite(value.size.height) &&
        value.size.width > 0 && value.size.height > 0;
}
CGRect quartz_rect(NSRect value, NSRect primary) {
    return CGRectMake(value.origin.x, NSMaxY(primary) - NSMaxY(value), value.size.width, value.size.height);
}

bool geometry(NSView* view, NSWindow* window, Geometry& result, std::string& reason) {
    if (![view isKindOfClass:NSView.class] || ![window isKindOfClass:NSWindow.class] ||
        view.window != window || ![NSApp.windows containsObject:window]) {
        reason = "The viewport no longer belongs to this Studio window."; return false;
    }
    // Desktop-independent capture selects this process's exact window even
    // when another app has focus or covers it. Foreground/key-window state is
    // not document identity and may remain unset after a Studio modal closes.
    if (!window.visible || window.miniaturized || !window.screen || view.hiddenOrHasHiddenAncestor) {
        reason = "Keep the Studio viewport window open and unminimized while capturing."; return false;
    }
    if (!near(view.frameRotation, 0) || !near(view.boundsRotation, 0)) {
        reason = "The viewport uses an unsupported transform."; return false;
    }
    NSRect visible = NSIntersectionRect(view.bounds, view.visibleRect);
    if (visible.size.width < 160 || visible.size.height < 90 || !positive_rect(NSRectToCGRect(visible))) {
        reason = "The visible viewport is too small to capture."; return false;
    }
    NSScreen* primary = NSScreen.screens.firstObject;
    if (!primary || window.windowNumber <= 0 || !std::isfinite(window.backingScaleFactor) ||
        window.backingScaleFactor <= 0 || window.backingScaleFactor > 4) {
        reason = "Studio's native viewport geometry is unavailable."; return false;
    }
    result.bounds = view.bounds;
    result.visible = visible;
    result.window_frame = window.frame;
    result.primary_frame = primary.frame;
    result.backing_scale = window.backingScaleFactor;
    result.window_id = window.windowNumber;
    result.window_quartz = quartz_rect(window.frame, primary.frame);
    result.viewport_quartz = quartz_rect([window convertRectToScreen:[view convertRect:visible toView:nil]], primary.frame);
    if (!positive_rect(result.window_quartz) ||
        !CGRectContainsRect(CGRectInset(result.window_quartz, -0.25, -0.25), result.viewport_quartz)) {
        reason = "The viewport lies outside the verified Studio window."; return false;
    }
    return true;
}

bool valid(const Context& request, std::string& reason) {
    Geometry now;
    if (!geometry(request->view, request->window, now, reason)) return false;
    const auto& before = request->geometry;
    if (now.window_id != before.window_id || !near(now.backing_scale, before.backing_scale, 0.001) ||
        !same_rect(NSRectToCGRect(now.bounds), NSRectToCGRect(before.bounds)) ||
        !same_rect(NSRectToCGRect(now.visible), NSRectToCGRect(before.visible)) ||
        !same_rect(NSRectToCGRect(now.primary_frame), NSRectToCGRect(before.primary_frame)) ||
        !same_rect(now.window_quartz, before.window_quartz) || !same_rect(now.viewport_quartz, before.viewport_quartz)) {
        reason = "The Studio viewport moved or resized during capture."; return false;
    }
    return true;
}

void finish(const Context& request, bool success, std::string reason) {
    if (request->finished.exchange(true, std::memory_order_acq_rel)) return;
    auto completion = std::move(request->completion);
    try { completion(success, std::move(reason)); } catch (...) { }
}
// Objective-C blocks retain value parameters, but preserve reference parameters
// as references. Every argument used after this function returns must be owned.
void main_step(Context request, std::function<void()> action) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (request->finished.load(std::memory_order_acquire)) return;
            @try {
                try { action(); }
                catch (const std::exception& error) { finish(request, false, error.what()); }
                catch (...) { finish(request, false, "Own-window capture failed."); }
            } @catch (__unused NSException* error) {
                finish(request, false, "The native window changed during capture.");
            }
        }
    });
}
dispatch_queue_t worker_queue() {
    static dispatch_queue_t queue = dispatch_queue_create("CustomTemplates.own-window-capture", DISPATCH_QUEUE_SERIAL);
    return queue;
}
bool reject(std::function<void(bool, std::string)> completion, std::string reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        try { completion(false, reason); } catch (...) { }
    });
    return true;
}

bool safe_output(const std::string& path, std::string& reason) {
    if (path.find('\0') != std::string::npos) {
        reason = "The thumbnail output path is invalid."; return false;
    }
    const std::filesystem::path output(path);
    if (!output.is_absolute() || output.extension() != ".png" || output.filename().empty()) {
        reason = "The thumbnail output must be an absolute PNG path."; return false;
    }
    for (const auto& component : output)
        if (component == "..") { reason = "The thumbnail output path is unsafe."; return false; }
    for (auto current = output.parent_path(); !current.empty();) {
        struct stat status{};
        if (lstat(current.c_str(), &status) != 0 || !S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
            reason = "Thumbnail staging must use existing folders without symbolic links."; return false;
        }
        if (current == output.parent_path() && status.st_uid != getuid()) {
            reason = "The thumbnail staging folder is not owned by this user."; return false;
        }
        const auto parent = current.parent_path();
        if (parent == current) break;
        current = parent;
    }
    struct stat existing{};
    if (lstat(path.c_str(), &existing) == 0) {
        if (!S_ISREG(existing.st_mode) || existing.st_uid != getuid() || existing.st_nlink != 1) {
            reason = "The thumbnail output is not a private regular file."; return false;
        }
    } else if (errno != ENOENT) { reason = "The thumbnail output cannot be inspected."; return false; }
    return true;
}

std::shared_ptr<StagedFile> stage_png(NSData* png, const std::string& output) {
    std::string reason;
    if (!safe_output(output, reason)) throw std::runtime_error(reason);
    auto result = std::make_shared<StagedFile>();
    const std::filesystem::path path(output);
    result->parent = path.parent_path().string();
    result->destination = path.filename().string();
    result->directory = open(result->parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat directory{};
    if (result->directory < 0 || fstat(result->directory, &directory) != 0 ||
        !S_ISDIR(directory.st_mode) || directory.st_uid != getuid())
        throw std::runtime_error("The thumbnail staging folder is unavailable.");
    result->device = directory.st_dev; result->inode = directory.st_ino;
    result->temporary = ".ctpl-" + std::string(NSUUID.UUID.UUIDString.UTF8String) + ".tmp";
    const int file = openat(result->directory, result->temporary.c_str(),
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) throw std::runtime_error("Could not create the cropped thumbnail.");
    bool ok = true;
    const auto* bytes = static_cast<const std::byte*>(png.bytes);
    std::size_t remaining = png.length;
    while (remaining) {
        const auto written = write(file, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = false; break; }
        bytes += written; remaining -= static_cast<std::size_t>(written);
    }
    if (ok && fsync(file) != 0) ok = false;
    if (close(file) != 0) ok = false;
    if (!ok) throw std::runtime_error("Could not save the cropped thumbnail.");
    return result;
}

NSData* encode_viewport(CGImageRef image, CGRect viewport) {
    const double target_ratio = static_cast<double>(kWidth) / kHeight;
    if (viewport.size.width / viewport.size.height > target_ratio) {
        const double width = viewport.size.height * target_ratio;
        viewport.origin.x += (viewport.size.width - width) / 2; viewport.size.width = width;
    } else {
        const double height = viewport.size.width / target_ratio;
        viewport.origin.y += (viewport.size.height - height) / 2; viewport.size.height = height;
    }
    // Round inward so no pixels outside the verified viewport are included.
    const double max_x = std::floor(CGRectGetMaxX(viewport)), max_y = std::floor(CGRectGetMaxY(viewport));
    viewport.origin.x = std::ceil(viewport.origin.x); viewport.origin.y = std::ceil(viewport.origin.y);
    viewport.size.width = max_x - viewport.origin.x; viewport.size.height = max_y - viewport.origin.y;
    if (viewport.size.width < 160 || viewport.size.height < 90)
        throw std::runtime_error("The cropped viewport is too small.");
    OwnedCF<CGImageRef> crop(CGImageCreateWithImageInRect(image, viewport));
    OwnedCF<CGColorSpaceRef> color(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    OwnedCF<CGContextRef> bitmap(CGBitmapContextCreate(nullptr, kWidth, kHeight, 8, kWidth * 4, color.get(),
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big)));
    if (!crop.get() || !color.get() || !bitmap.get()) throw std::runtime_error("Could not resize the viewport image.");
    CGContextSetInterpolationQuality(bitmap.get(), kCGInterpolationHigh);
    CGContextDrawImage(bitmap.get(), CGRectMake(0, 0, kWidth, kHeight), crop.get());
    OwnedCF<CGImageRef> resized(CGBitmapContextCreateImage(bitmap.get()));
    OwnedCF<CFMutableDataRef> bytes(CFDataCreateMutable(kCFAllocatorDefault, 0));
    if (!resized.get() || !bytes.get()) throw std::runtime_error("Could not encode the viewport image.");
    OwnedCF<CGImageDestinationRef> encoder(CGImageDestinationCreateWithData(bytes.get(), CFSTR("public.png"), 1, nullptr));
    if (!encoder.get()) throw std::runtime_error("The PNG encoder is unavailable.");
    CGImageDestinationAddImage(encoder.get(), resized.get(), nullptr);
    if (!CGImageDestinationFinalize(encoder.get()) || CFDataGetLength(bytes.get()) <= 0 ||
        static_cast<std::size_t>(CFDataGetLength(bytes.get())) > kMaximumPngBytes)
        throw std::runtime_error("The cropped PNG could not be encoded.");
    return [NSData dataWithBytes:CFDataGetBytePtr(bytes.get()) length:static_cast<NSUInteger>(CFDataGetLength(bytes.get()))];
}

// Keep each asynchronous hop in a function with value parameters. In
// particular, a block nested in a C++ lambda must not retain that lambda's this.
void stage_output(Context request, NSData* png) {
    dispatch_async(worker_queue(), ^{
        @autoreleasepool {
            try {
                if (request->finished.load(std::memory_order_acquire)) return;
                auto staged = stage_png(png, request->path);
                main_step(request, [request, staged] {
                    std::string reason;
                    struct stat directory{};
                    if (!valid(request, reason) || !safe_output(request->path, reason)) {
                        finish(request, false, reason); return;
                    }
                    if (lstat(staged->parent.c_str(), &directory) != 0 ||
                        directory.st_dev != staged->device || directory.st_ino != staged->inode) {
                        finish(request, false, "The thumbnail staging folder changed."); return;
                    }
                    if (renameat(staged->directory, staged->temporary.c_str(), staged->directory,
                            staged->destination.c_str()) != 0) {
                        finish(request, false, "Could not commit the cropped PNG."); return;
                    }
                    staged->temporary.clear();
                    finish(request, true, "");
                });
            } catch (const std::exception& error) {
                const std::string reason = error.what();
                main_step(request, [request, reason] { finish(request, false, reason); });
            } catch (...) {
                main_step(request, [request] { finish(request, false, "Could not write the cropped PNG."); });
            }
        }
    });
}

void prepare_output(Context request, Image image, CGRect crop) {
    dispatch_async(worker_queue(), ^{
        @autoreleasepool {
            try {
                if (request->finished.load(std::memory_order_acquire)) return;
                NSData* png = encode_viewport(image.get(), crop);
                main_step(request, [request, png] {
                    std::string reason;
                    if (!valid(request, reason)) { finish(request, false, reason); return; }
                    stage_output(request, png);
                });
            } catch (const std::exception& error) {
                const std::string reason = error.what();
                main_step(request, [request, reason] { finish(request, false, reason); });
            } catch (...) {
                main_step(request, [request] { finish(request, false, "Could not encode the cropped PNG."); });
            }
        }
    });
}

// This is the exact completion passed to ScreenCaptureKit. Keeping creation
// separate also lets the deferred ownership path be tested without a screenshot.
using ScreenshotCompletion = void (^)(CGImageRef, NSError*);
ScreenshotCompletion screenshot_completion(Context request, std::size_t width, std::size_t height, CGRect expected) {
    return ^(CGImageRef captured, NSError* error) {
        Image image(captured ? CGImageRetain(captured) : nullptr, [](CGImageRef value) { if (value) CGImageRelease(value); });
        main_step(request, [request, image, error, width, height, expected] {
            if (error || !image) { finish(request, false, "The own-window screenshot was unavailable."); return; }
            std::string reason;
            if (!valid(request, reason)) { finish(request, false, reason); return; }
            const auto actual_width = CGImageGetWidth(image.get()), actual_height = CGImageGetHeight(image.get());
            if (actual_width != width || actual_height != height || CGImageGetBitsPerPixel(image.get()) > 64) {
                finish(request, false, "The captured window image has unexpected dimensions."); return;
            }
            const double sx = static_cast<double>(width) / expected.size.width;
            const double sy = static_cast<double>(height) / expected.size.height;
            const auto& visible = request->geometry.viewport_quartz;
            CGRect crop = CGRectMake((visible.origin.x - expected.origin.x) * sx,
                (visible.origin.y - expected.origin.y) * sy, visible.size.width * sx, visible.size.height * sy);
            if (!CGRectContainsRect(CGRectMake(0, 0, width, height), crop)) {
                finish(request, false, "The captured viewport lies outside the window image."); return;
            }
            prepare_output(request, image, crop);
        });
    };
}

void begin_screenshot(Context request, SCShareableContent* content) {
    std::string reason;
    if (!valid(request, reason)) { finish(request, false, reason); return; }
    SCWindow* target = nil;
    for (SCWindow* window in content.windows)
        if (window.windowID == request->geometry.window_id && window.owningApplication.processID == getpid()) {
            target = window; break;
        }
    if (!target || !same_rect(target.frame, request->geometry.window_quartz, 1)) {
        finish(request, false, "The exact Studio window is not available for own-process capture."); return;
    }
    SCContentFilter* filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
    const CGRect frame = filter.contentRect;
    const CGRect expected = request->geometry.window_quartz;
    if (!positive_rect(frame) || !near(frame.size.width, expected.size.width, 1) ||
        !near(frame.size.height, expected.size.height, 1) ||
        (!same_rect(frame, expected, 1) && !(near(frame.origin.x, 0) && near(frame.origin.y, 0)))) {
        finish(request, false, "The capture content does not match the Studio window frame."); return;
    }
    const double scale = filter.pointPixelScale;
    if (!std::isfinite(scale) || scale <= 0 || scale > 4) {
        finish(request, false, "The Studio window capture scale is invalid."); return;
    }
    const auto width = static_cast<std::size_t>(std::ceil(frame.size.width * scale));
    const auto height = static_cast<std::size_t>(std::ceil(frame.size.height * scale));
    if (!width || !height || width > kMaximumDimension || height > kMaximumDimension ||
        width > kMaximumPixels / height) {
        finish(request, false, "The Studio window is too large to capture safely."); return;
    }
    SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
    config.width = width; config.height = height;
    config.showsCursor = NO;
    config.ignoreShadowsSingleWindow = YES;
    config.ignoreShadowsDisplay = YES;
    config.includeChildWindows = NO;
    config.scalesToFit = NO;
    config.preservesAspectRatio = YES;
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config
        completionHandler:screenshot_completion(request, width, height, expected)];
}
} // namespace

bool ctpl_capture_owned_view(std::uintptr_t native_view_id, const std::string& output_path,
    std::function<void(bool, std::string)> completion) {
    if (!pthread_main_np() || !completion) return false;
    Context request;
    const auto fail = [&](const std::string& reason) {
        if (request && request->completion) {
            main_step(request, [request, reason] { finish(request, false, reason); });
            return true;
        }
        return reject(std::move(completion), reason);
    };
    @autoreleasepool {
        @try {
          try {
            if (@available(macOS 14.4, *)) {
                if (!native_view_id) return reject(std::move(completion), "The native viewport view is unavailable.");
                NSView* view = (__bridge NSView*)reinterpret_cast<void*>(native_view_id);
                NSWindow* window = [view isKindOfClass:NSView.class] ? view.window : nil;
                Geometry initial;
                std::string reason;
                if (!geometry(view, window, initial, reason) || !safe_output(output_path, reason))
                    return reject(std::move(completion), reason);
                request = Context(new Request(), [](Request* value) {
                    // Strong AppKit references are always released on main.
                    if (pthread_main_np()) delete value;
                    else dispatch_async(dispatch_get_main_queue(), ^{ delete value; });
                });
                request->view = view; request->window = window; request->geometry = initial;
                request->path = output_path;
                if (g_pending.fetch_add(1, std::memory_order_acq_rel) >= kMaximumPending) {
                    g_pending.fetch_sub(1, std::memory_order_acq_rel);
                    return reject(std::move(completion), "Another own-window capture is still pending.");
                }
                request->counted = true;
                request->completion = std::move(completion);
                const std::weak_ptr<Request> weak = request;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    if (auto pending = weak.lock()) finish(pending, false, "Own-window capture timed out.");
                });
                [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:
                    ^(SCShareableContent* content, NSError* error) {
                        main_step(request, [request, content, error] {
                            if (error || !content) { finish(request, false, "Own-process window enumeration was unavailable."); return; }
                            begin_screenshot(request, content);
                        });
                    }];
                return true;
            }
            return reject(std::move(completion), "Own-window capture requires macOS 14.4 or newer.");
          } catch (const std::exception& error) {
              return fail(error.what());
          } catch (...) {
              return fail("The native viewport is unavailable for capture.");
          }
        } @catch (__unused NSException* error) {
            return fail("The native viewport is unavailable for capture.");
        }
    }
}
