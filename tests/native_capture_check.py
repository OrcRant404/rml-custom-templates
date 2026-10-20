#!/usr/bin/env python3
"""Run capture crop, deferred-callback, and GUI-dispatch lifetime regressions."""

from __future__ import annotations

from pathlib import Path
import os
import subprocess
import tempfile


repository = Path(__file__).resolve().parents[1]
native_source = repository / "native/OwnWindowCapture.mm"
lifetime_harness = repository / "tests/native_capture_lifetime.mm"
crop_harness = repository / "tests/native_capture_crop.mm"
gui_header = repository / "native/NativeGuiDispatch.hpp"
gui_harness = repository / "tests/native_gui_dispatch.mm"
native_include = repository / "native"
environment = dict(os.environ, ASAN_OPTIONS="detect_stack_use_after_return=1:halt_on_error=1")
flags = [
    "/usr/bin/clang++", "-x", "objective-c++", "-std=c++23", "-fobjc-arc", "-O1", "-g",
    "-fsanitize=address", "-fsanitize-address-use-after-scope", "-fno-omit-frame-pointer",
    "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-anon-enum-enum-conversion",
    "-I", str(native_include),
]
frameworks = [
    "-framework", "AppKit",
    "-framework", "ScreenCaptureKit",
    "-framework", "ImageIO",
]
gui_frameworks = ["-framework", "Foundation"]


def compile_case(harness: Path, source: Path, output: Path, nested: bool = False) -> None:
    arguments = flags + [f'-DCTPL_TEST_SOURCE="{source}"']
    if nested:
        arguments += ["-DCTPL_REPRO_NESTED"]
    subprocess.run(arguments + [str(harness)] + frameworks + ["-o", str(output)], check=True)


def run_case(executable: Path, case: str, expected_error: str | None = None) -> None:
    result = subprocess.run([str(executable), case], env=environment, capture_output=True, text=True)
    if expected_error is None:
        if result.returncode != 0:
            raise RuntimeError(result.stdout + result.stderr)
        print(result.stdout.strip())
        return

    marker = "ERROR: AddressSanitizer: " + expected_error
    if result.returncode == 0 or marker not in result.stderr:
        raise RuntimeError(result.stdout + result.stderr)
    print(f"PASS: negative {case} reproduced {expected_error}")


def compile_gui_case(header: Path, output: Path, broken: bool = False) -> None:
    arguments = flags + [f'-DCTPL_GUI_DISPATCH_HEADER="{header}"']
    if broken:
        arguments += ["-DCTPL_EXPECT_BROKEN"]
    subprocess.run(arguments + [str(gui_harness)] + gui_frameworks + ["-o", str(output)], check=True)


def run_gui_case(executable: Path, expected_error: str | None = None) -> None:
    result = subprocess.run([str(executable)], env=environment, capture_output=True, text=True)
    if expected_error is None:
        if result.returncode != 0:
            raise RuntimeError(result.stdout + result.stderr)
        print(result.stdout.strip())
        return

    marker = "ERROR: AddressSanitizer: " + expected_error
    if result.returncode == 0 or marker not in result.stderr:
        raise RuntimeError(result.stdout + result.stderr)
    print(f"PASS: negative GUI dispatch reproduced {expected_error}")


with tempfile.TemporaryDirectory(prefix="ctpl-native-capture-tests-") as folder:
    scratch = Path(folder)

    fixed = scratch / "fixed-lifetime"
    compile_case(lifetime_harness, native_source, fixed)
    for case in ("main", "reject", "screenshot", "image", "nested"):
        run_case(fixed, case)

    original = native_source.read_text(encoding="utf-8")
    source_before = original
    replacements = {
        "void main_step(Context request,": "void main_step(const Context& request,",
        "completion, std::string reason) {\n    dispatch_async":
            "completion, const std::string& reason) {\n    dispatch_async",
        "void prepare_output(Context request, Image image,":
            "void prepare_output(const Context& request, const Image& image,",
        "ScreenshotCompletion screenshot_completion(Context request,":
            "ScreenshotCompletion screenshot_completion(const Context& request,",
    }
    for before, after in replacements.items():
        if source_before.count(before) != 1:
            raise RuntimeError(f"Expected one pre-fix mutation point: {before}")
        source_before = source_before.replace(before, after)

    before_source = scratch / "reference-before.mm"
    before_source.write_text(source_before, encoding="utf-8")
    before = scratch / "before-lifetime-fixes"
    compile_case(lifetime_harness, before_source, before, nested=True)
    for case in ("main", "reject", "screenshot", "image"):
        run_case(before, case, "stack-use-after-return")
    run_case(before, "nested", "heap-use-after-free")

    image_source = scratch / "image-reference-before.mm"
    image_before_source = original.replace(
        "void prepare_output(Context request, Image image,",
        "void prepare_output(Context request, const Image& image,",
    )
    if image_before_source == original:
        raise RuntimeError("Expected one image ownership regression point.")
    image_source.write_text(image_before_source, encoding="utf-8")
    image_before = scratch / "before-image-fix"
    compile_case(lifetime_harness, image_source, image_before)
    run_case(image_before, "image", "stack-use-after-return")

    crop = scratch / "synthetic-crop"
    compile_case(crop_harness, native_source, crop)
    run_case(crop, "crop")

    gui_fixed = scratch / "fixed-gui-dispatch"
    compile_gui_case(gui_header, gui_fixed)
    run_gui_case(gui_fixed)

    original_header = gui_header.read_text(encoding="utf-8")
    fixed_signature = "inline void dispatch_gui(std::function<void()> task) {"
    reference_signature = "inline void dispatch_gui(const std::function<void()>& task) {"
    if original_header.count(fixed_signature) != 1:
        raise RuntimeError("Expected one value-owned GUI dispatcher signature.")
    broken_header = scratch / "NativeGuiDispatch-reference-before.hpp"
    broken_header.write_text(original_header.replace(fixed_signature, reference_signature), encoding="utf-8")
    gui_before = scratch / "before-gui-dispatch-fix"
    compile_gui_case(broken_header, gui_before, broken=True)
    run_gui_case(gui_before, "stack-use-after-return")

print("PASS: five capture lifetime cases, six capture negative controls, synthetic crop, and GUI dispatch lifetime guard")
