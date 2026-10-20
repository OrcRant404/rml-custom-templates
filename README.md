# RML Custom Templates

Add local `.rbxl` and `.rbxlx` place files to the **Templates** page in RML-managed Roblox Studio.

[Downloads](https://github.com/OrcRant404/rml-custom-templates/releases) ·
[RML loader fork](https://github.com/OrcRant404/roblox-modloader) ·
[Validation](TESTING.md)

The current release supports **macOS ARM64** with the pinned Studio/RML builds below.
The native UI does **not** yet support Windows or Linux/Vinegar. Linux CI exercises
the portable catalog and document-link code only. Vinegar runs Windows Studio, so
a complete port needs a Windows x64 helper, Windows Studio bindings, and a new
viewport capture backend; the Mac `.dylib` cannot run there.

## Use

1. Open **Templates**. Your custom categories appear beside the Roblox categories.
2. Use **Add Template** to choose a saved `.rbxl` or `.rbxlx`, give it a name, and choose a category.
3. Open a card to start a new, unsaved place from that template. Studio's first **Save to File** asks where to save your project. An **OWNED** corner ribbon marks your templates.
4. Right-click an owned card to edit its name/category, replace its saved place, recapture the thumbnail, or remove it.
5. Use the category add control to create a category. Right-click a custom category to manage it.

Creating or replacing a template stores an internal copy of the selected file. The default thumbnail option opens a separate copy in Studio and captures its 3D viewport. A failed capture keeps the last good thumbnail. The original source and existing working copies are never changed by an update. Removed/replaced snapshots are retained in the archive.

With a place open, use Studio's **File** menu:

- **Save to Template** updates the owned template linked to this document. If there is no link yet, it opens the new-template dialog.
- **Save to Template As…** creates a separate template with a name and category, then links this document to the new template for later template saves. Equal-content copies are allowed.

These actions snapshot the current Edit place and its viewport without changing the place's filename or publishing it. The new-template dialog lets you use that viewport or choose a PNG. Opening one of your template cards establishes its save link automatically. Links last for the Studio session. Template saving requires one unambiguous Edit place in this Studio process and is disabled during Play.

You can also save while the Script Editor is active. With the 3D viewport hidden, the place is saved and the previous thumbnail is kept; Studio shows a notice. Switch to the place tab before saving to refresh its thumbnail.

Data is stored outside Studio at `~/Library/Application Support/RobloxCustomTemplates/`:

- `catalog.json`: categories, template metadata, and revision history.
- `templates/`: current immutable place snapshots.
- `thumbnails/`: authoritative local PNG previews.
- `working/`: separate staging copies used when opening or capturing templates.
- `archived/`: previous/removed snapshots.
- `captures/`: transient thumbnail staging files.
- `saves/`: transient current-place snapshot and viewport staging files.

Existing version-1 catalogs are migrated with a backup. Their templates move into **Personal**. Personal is the protected default category. Deleting another category moves its templates to Personal.

Staging files are retained. Opening a template creates an unsaved document; **Save to File** lets you choose its project location. **Save to Template** updates its linked template directly; the card editor also accepts a replacement place file. File-import capture uses a separate `CTPL-<request ID>` working file so it can identify the correct document even when templates have the same name.

Studio's ordinary **Save to File** saves your project separately. Use **Save to Template** explicitly when you want to replace the library's stored template.

Open template cards from the Templates page with one Studio window. Each successful open gets Studio's native `PlaceN` title and an empty file destination. The staging file stays separate from both the library snapshot and the project location you choose.

If Studio shows a lighting migration notice for an older place, continue, save that place through Studio, then replace the template from the saved file. Opening a capture copy alone does not update the stored snapshot. The mod preserves the lighting in the file you select.

A private, rebuildable image cache at `/Library/Caches/RobloxCustomTemplates-<user ID>/` lets the Templates page display PNGs without uploading them. The installer adds one signed asset alias to that cache. The authoritative place and thumbnail files stay in Application Support. An app update may require reinstalling the mod to restore its asset alias.

## Supported installation

Automatic capture requires macOS 14.4 or later. Keep the capture document open and the Studio window visible and unminimized until its thumbnail is saved. It captures only the verified Studio window and crops to the 3D viewport. A short settling delay is used; it does not guarantee every remote asset has loaded. You can recapture later or choose a PNG.

This mod targets macOS ARM64, Studio **0.741.19.7411056**, and RML revision **5d3090ad93ca8b212ca859fea5b1dca3e2e0fe1b**. The native helper checks the Studio version, scheduler vtable, and method bytes before enabling its hook. Other Studio builds require an updated mod. The mod extends the mounted Templates interface without replacing the bundled StartPage plugin. The helper supplies Qt editors and creates new places through Studio's native document machinery.

## Install the download

Install the matching [RML loader](https://github.com/OrcRant404/roblox-modloader/releases) first. Extract this mod's ZIP, close Studio, then run this from the extracted `rml-custom-templates` folder:

```sh
python3 scripts/install.py --app "/absolute/path/to/RobloxStudio.app"
```

The download includes the built mod. Open that same Studio app after installation. If you already use the RML manager, omitting `--app` selects its default managed installation; `rml-studio` is an optional local launch command, not a prerequisite.

## Build from source

Requires the matching RML Studio, .NET 10, Xcode command-line tools, and the local RML SDK source. Close Studio before installing.

For a Studio/SDK outside the default local paths, set `ROBLOX_STUDIO_APP` to the compatible app, `ROBLOX_MODLOADER_SOURCE` to the loader source checkout, and `RobloxModLoaderRuntime` to the app's `Contents/MacOS/RobloxModLoader/runtime` directory. If needed, set `RML_SPDLOG_INCLUDE` to a directory containing `spdlog/spdlog.h`.

```sh
./scripts/build
./scripts/test
./scripts/test-native
./scripts/test-capture
./scripts/test-current
./scripts/test-file-menu
./scripts/test-open
python3 scripts/install.py
rml-studio
```

The installer selects the default managed RML Studio, backs up the previous copy of this mod outside the app bundle, installs only `custom-templates`, and signs and verifies the app. It leaves other mods and template data in place. Pass `--app /absolute/path/RobloxStudio.app` to select another compatible installation.

Close and restart Studio after updating or disabling the mod. Do not use **Mods → Reload** for this mod: live unload/reload is not supported, and can leave inactive controls on the current Templates page until Studio restarts.

To disable the mod, close Studio and run `python3 scripts/install.py --uninstall` from this folder. The installer backs up the mod, removes it, and signs the app again. Template data remains in Application Support.

## Implementation and limits

The native helper owns the page controls and engine callbacks. A dedicated .NET thread handles the catalog and file operations through queued commands and cached JSON snapshots. Managed code does not run inside the page's engine jobs or button callbacks.

The current interface uses Studio's dark palette and bundled BuilderSans font roles, with square previews and card dimensions measured from the built-in template grid. Importing, opening fresh copies, updating, and current-place File menu saves were exercised in Studio, including unsaved Script Editor text and independent Save As copies. Validation and remaining limits are recorded in TESTING.md. The catalog checks file type, size, paths, and snapshot hashes; Studio validates the place contents when opening it. This is a local, version-specific mod; a short live test is not a guarantee of long-session stability. Native GUI objects retained by this RML SDK are reclaimed when Studio exits.

## License

MIT. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
