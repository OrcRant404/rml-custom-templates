#ifndef CTPL_TEST_SOURCE
#define CTPL_TEST_SOURCE "../native/OwnWindowCapture.mm"
#endif
#include CTPL_TEST_SOURCE
#include <cassert>
#include <cstdio>
#include <filesystem>
#include <vector>

static std::string make_temporary_directory() {
    const auto parent = std::filesystem::canonical(std::filesystem::temp_directory_path());
    const auto pattern = (parent / "ctpl-capture-test-XXXXXX").string();
    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    char *directory = mkdtemp(writable.data());
    assert(directory);
    return directory;
}

static void image_case(CGRect viewport, bool wide) {
    constexpr size_t width = 1600, height = 1000;
    std::vector<unsigned char> source(width * height * 4);
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        auto* pixel = &source[(y * width + x) * 4];
        const bool inside = CGRectContainsPoint(viewport, CGPointMake(x + 0.5, y + 0.5));
        const bool trimmed = inside && (wide ?
            x < viewport.origin.x + 50 || x >= CGRectGetMaxX(viewport) - 50 :
            y < viewport.origin.y + 50 || y >= CGRectGetMaxY(viewport) - 50);
        pixel[0] = inside ? 0 : 255;
        pixel[1] = inside && !trimmed ? 255 : 0;
        pixel[2] = trimmed ? 255 : 0;
        pixel[3] = 255;
    }
    OwnedCF<CGColorSpaceRef> color(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    const auto flags = static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) |
        static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big);
    OwnedCF<CGContextRef> input(CGBitmapContextCreate(source.data(), width, height, 8, width * 4, color.get(), flags));
    OwnedCF<CGImageRef> image(CGBitmapContextCreateImage(input.get()));
    NSData* png = encode_viewport(image.get(), viewport);
    assert(png.length > 8 && png.length < kMaximumPngBytes);
    OwnedCF<CGImageSourceRef> decoder(CGImageSourceCreateWithData((__bridge CFDataRef)png, nullptr));
    OwnedCF<CGImageRef> decoded(CGImageSourceCreateImageAtIndex(decoder.get(), 0, nullptr));
    assert(CGImageGetWidth(decoded.get()) == 640 && CGImageGetHeight(decoded.get()) == 360);
    std::vector<unsigned char> output(640 * 360 * 4);
    OwnedCF<CGContextRef> bitmap(CGBitmapContextCreate(output.data(), 640, 360, 8, 640 * 4, color.get(), flags));
    CGContextDrawImage(bitmap.get(), CGRectMake(0, 0, 640, 360), decoded.get());
    for (size_t index = 0; index < output.size(); index += 4) {
        assert(output[index] == 0 && output[index + 1] == 255 && output[index + 2] == 0 && output[index + 3] == 255);
    }
    const std::string folder = make_temporary_directory();
    const std::string path = folder + "/cropped.png";
    auto staged = stage_png(png, path);
    assert(renameat(staged->directory, staged->temporary.c_str(), staged->directory, staged->destination.c_str()) == 0);
    staged->temporary.clear();
    struct stat status{};
    assert(lstat(path.c_str(), &status) == 0 && status.st_size == static_cast<off_t>(png.length));
    assert((status.st_mode & 0777) == 0600);
    assert(unlink(path.c_str()) == 0);
    staged.reset();
    assert(rmdir(folder.c_str()) == 0);
}
int main() {
    @autoreleasepool {
        image_case(CGRectMake(200, 200, 1200, 600), true);
        image_case(CGRectMake(400, 100, 600, 800), false);
        bool rejected = false;
        try { encode_viewport(nullptr, CGRectMake(0, 0, 10, 10)); }
        catch (const std::runtime_error&) { rejected = true; }
        assert(rejected);
        std::string reason;
        assert(!safe_output("relative.png", reason));
        std::string embedded_null = (std::filesystem::canonical(std::filesystem::temp_directory_path()) / "good.png").string();
        embedded_null.append("\0wrong.png", 10);
        assert(!safe_output(embedded_null, reason));
        std::puts("PASS: wide/portrait viewport isolation, center crop, PNG dimensions, private atomic staging, invalid crop/path");
    }
}
