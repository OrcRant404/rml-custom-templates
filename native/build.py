#!/usr/bin/env python3
"""Build and stage the macOS Start Page helper beside CustomTemplates.dll."""

from pathlib import Path
import os
import platform
import shutil
import subprocess
import sys


SUPPORTED_STUDIO_BUILD = "0.741.19.7411056"
DEFAULT_STUDIO_APP = Path.home() / (
    "Library/Application Support/com.revolution.rml-launcher/studio/versions/"
    "version-5f7ed526d8884288/RobloxStudio.app"
)
DEFAULT_RML_SOURCE = Path.home() / "Projects/roblox-modloader"


def has_studio_build(executable: Path) -> bool:
    process = subprocess.Popen(["/usr/bin/strings", "-a", str(executable)], stdout=subprocess.PIPE)
    assert process.stdout is not None
    found = False
    for line in process.stdout:
        if line.rstrip(b"\r\n") == SUPPORTED_STUDIO_BUILD.encode("ascii"):
            found = True
            process.terminate()
            break
    process.stdout.close()
    process.wait()
    return found


def verify_rml_exports(library: Path) -> None:
    result = subprocess.run(["/usr/bin/nm", "-gU", str(library)], check=True, capture_output=True, text=True)
    required = (
        "__ZN3rml14task_schedulerEv",
        "__ZN3rml18has_task_schedulerEv",
        "__ZNK3RBX13TaskScheduler23get_vtable_for_job_kindEN3rml7JobKindE",
        "__ZN3RBX9DataModel8from_jobEPKNS_12DataModelJobE",
        "__ZN11vtable_hookC1EPPvm",
        "__ZN11vtable_hook4hookEmPv",
        "__ZN11vtable_hook6enableEv",
        "__ZNK11vtable_hook10is_enabledEv",
        "__ZN3rml6dotnet21RobloxInteropProvider8populateERNS0_12InteropTableE",
    )
    missing = [symbol for symbol in required if symbol not in result.stdout]
    if missing:
        raise SystemExit(f"The installed RML library is missing required engine-hook exports: {', '.join(missing)}")


def verify_data_model_layout(header: Path) -> None:
    source = header.read_text(encoding="utf-8")
    required_layout = (
        "Standalone = 3",
        "offsetof(DataModel, type) == 0x348",
    )
    missing = [declaration for declaration in required_layout if declaration not in source]
    if missing:
        raise SystemExit(
            "RML DataModel type layout differs from the version-pinned native reader: "
            + ", ".join(missing)
        )


def run(arguments: list[str]) -> None:
    print("+", " ".join(arguments))
    subprocess.run(arguments, check=True)

def spdlog_include(rml_source: Path) -> Path:
    override = os.environ.get("RML_SPDLOG_INCLUDE")
    candidates = [Path(override).expanduser()] if override else []
    candidates += [
        rml_source / "libs/third_party/spdlog/include",
        rml_source / "build/_deps/spdlog-src/include",
        rml_source / ".build/_deps/spdlog-src/include",
        Path.home() / ".nix-profile/include",
        Path("/opt/homebrew/include"),
        Path("/usr/local/include"),
    ]
    store = Path("/nix/store")
    if store.is_dir():
        candidates += sorted(store.glob("*-spdlog-*-dev/include"), reverse=True)
    for candidate in candidates:
        if (candidate / "spdlog/spdlog.h").is_file():
            return candidate
    raise SystemExit(
        "The RML reflection SDK requires spdlog headers. Set RML_SPDLOG_INCLUDE "
        "to the include directory containing spdlog/spdlog.h."
    )


def main() -> int:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("CustomTemplatesUI currently supports macOS arm64 only.")

    repository = Path(__file__).resolve().parents[1]
    studio_app = Path(os.environ.get("ROBLOX_STUDIO_APP", str(DEFAULT_STUDIO_APP))).expanduser().resolve()
    rml_source = Path(os.environ.get("ROBLOX_MODLOADER_SOURCE", str(DEFAULT_RML_SOURCE))).expanduser().resolve()
    studio_executable = studio_app / "Contents/MacOS/RobloxStudio"
    rml_library = studio_app / "Contents/MacOS/roblox_modloader.dylib"
    sdk_include = rml_source / "code/roblox_modloader/include"
    reflection_includes = [
        rml_source / "libs/third_party/g3d/include",
        rml_source / "libs/third_party/rbxg3d/include",
        rml_source / "libs/third_party/bullet/include",
        *[rml_source / "libs/third_party/luau" / part / "include" for part in ("VM", "Common", "Ast", "Compiler")],
        spdlog_include(rml_source),
    ]

    required_sdk_headers = (
        "RobloxModLoader/rml_export.hpp",
        "RobloxModLoader/hooking/vtable_hook.hpp",
        "RobloxModLoader/roblox/data_model.hpp",
        "RobloxModLoader/roblox/data_model_job.hpp",
        "RobloxModLoader/roblox/job_types.hpp",
        "RobloxModLoader/roblox/task_scheduler.hpp",
        "RobloxModLoader/roblox/task_scheduler.job.hpp",
    )
    for required in (studio_executable, rml_library, *(sdk_include / header for header in required_sdk_headers)):
        if not required.exists():
            raise SystemExit(f"Required Studio/RML SDK file is missing: {required}")
    if not has_studio_build(studio_executable):
        raise SystemExit(
            f"Unsupported Roblox Studio executable; expected build {SUPPORTED_STUDIO_BUILD}: {studio_executable}"
        )
    verify_rml_exports(rml_library)
    verify_data_model_layout(sdk_include / "RobloxModLoader/roblox/data_model.hpp")

    output_dir = repository / ".agent-work/native"
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / "libCustomTemplatesUI.dylib"
    source = repository / "native/CustomTemplatesUI.mm"

    run([
        "/usr/bin/clang++", "-x", "objective-c++", "-std=c++23", "-dynamiclib", "-fobjc-arc",
        "-fvisibility=hidden", "-Wl,-install_name,@rpath/libCustomTemplatesUI.dylib",
        "-ffile-prefix-map=" + str(repository) + "=/src/rml-custom-templates",
        "-ffile-prefix-map=" + str(rml_source) + "=/src/roblox-modloader",
        "-isystem", str(sdk_include),
        "-isystem", str(rml_source / "code/roblox_modloader/src"),
        "-DSPDLOG_USE_STD_FORMAT",
        *[argument for include in reflection_includes for argument in ("-isystem", str(include))],
        str(source), str(repository / "native/StartPageUI.mm"),
        str(repository / "native/TemplateDialogs.mm"), str(repository / "native/ThumbnailCapture.mm"),
        str(repository / "native/TemplateFileMenu.mm"), str(repository / "native/CurrentPlaceSnapshot.mm"),
        str(repository / "native/TemplateOpen.mm"),
        str(repository / "native/OwnWindowCapture.mm"),
        "-x", "none", str(rml_library),
        "-framework", "AppKit", "-framework", "UniformTypeIdentifiers",
        "-framework", "ScreenCaptureKit", "-framework", "ImageIO", "-o", str(output),
    ])
    run([
        "/usr/bin/install_name_tool", "-change", "@rpath/libroblox_modloader.dylib",
        "@loader_path/../../../../roblox_modloader.dylib", str(output),
    ])
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(output)])
    run(["/usr/bin/codesign", "--verify", "--strict", str(output)])

    # The installed mod loader uses this exact layout:
    # Contents/MacOS/RobloxModLoader/mods/custom-templates/dotnet/
    # Four parent traversals from dotnet reach Contents/MacOS.
    staged = repository / ".agent-work/payload/mods/custom-templates/dotnet"
    staged.mkdir(parents=True, exist_ok=True)
    shutil.copy2(output, staged / output.name)
    print(f"Built helper: {output}")
    print(f"Staged beside CustomTemplates.dll: {staged / output.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
