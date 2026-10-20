# Validation — October 19, 2026

Target: macOS ARM64, Roblox Studio 0.741.19.7411056, RML 5d3090ad93ca8b212ca859fea5b1dca3e2e0fe1b.

## Version 0.1 baseline — automated checks

- `./scripts/build`: managed build, native link, helper signing and signature verification passed.
- `./scripts/test`: all 14 catalog tests passed, including atomic saves, immutable snapshots, fresh copies, corruption, symlink/path handling, archive behavior, and concurrent catalog updates.
- `./scripts/test-native`: five checks against the actual native action queue passed, including rapid Remove → Open clicks, duplicate removal, stale confirmation, and Keep. These tests do not initialize or exercise Studio engine APIs.
- Installer install/uninstall, backups, and app signature verification passed. Packaging checks compare shipped payloads with the installed mod.

## Version 0.1 baseline — live Studio checks

The native UI and separate catalog-worker design was tested in an isolated copy with the existing RML Workspace and Developer Toolkit mods. It imported a local `.rbxlx`, displayed its card, confirmed removal, archived it, and imported it again. Opening a copy reached a responsive editor and the Studio MCP connection.

The first copy started with `TemplateMarker` at `(0,3,0)` and the original proof string. After editing and saving, the working file changed while both the original source and the stored template retained SHA-256 `792ac2c666e687dbeff27139a13d594a62f6da4f03ab3b871d28a1093dd0e9f3`. A second opening used a different working directory, matched that original hash, and loaded the original marker and proof. Both copies closed; Studio quit without another crash report.

The final build, including the confirmation-queue fix, was installed in the regular RML-managed Studio. The existing card persisted, Open copy loaded a responsive editor, MCP verified the original contents, and editing plus saving changed only the working file. Studio returned to Templates and completed a normal shutdown. It was then restarted to verify the page remains available.

## Version 0.2 automated checks

- Complete managed build: zero warnings/errors. Native helper compiled, linked, signed and verified.
- All 26 catalog tests passed: schema-1 migration, category rules, immutable update isolation, owned PNGs, malformed previews, staged archive recovery, and rollback after failed writes.
- All nine native action/ownership checks passed against the actual v2 Start Page source. These do not initialize Studio engine APIs.
- `./scripts/test-capture` passed five deferred callback lifetime cases under AddressSanitizer; six negative controls reproduced the former reference/lambda lifetime failures. Synthetic wide/portrait cropping, 640 x 360 PNG output, private staging, and invalid-input checks passed.
- The production GUI dispatcher passed deferred main/background submission, main-thread capture release, asynchronous ordering, and C++/Objective-C exception checks under AddressSanitizer. Its reference-parameter negative control reproduced the expected use-after-return failure.
- Release payloads contain no embedded developer home path. The native library uses the relocatable `@rpath/libCustomTemplatesUI.dylib` identity.
- Strict deep app signing passed with the private `/Library/Caches` asset alias, including after external PNG changes.
- Claude's UI harness checked category selection, reparenting, narrow layouts and resize recovery. Live evidence remains separate below.

## Version 0.2 live Studio checks

In the isolated RML Studio, schema-1 migration retained the original template and created an exact catalog backup. Creating, renaming and removing a category worked; removal reassigned its templates to Personal. Personal remained protected. Owned cards opened the Qt editor via both right-click and Edit; right-clicking Roblox's Baseplate did not open that editor. All displayed the original Roblox grid with the owned section appended below it. Only one category was highlighted at a time.

Manual PNG selection, the private `rbxasset://RMLCustomTemplates/` alias, left-aligned labels, cropped previews and diagonal OWNED ribbons rendered in Studio. Automatic capture used the exact CTPL request document, the verified QEngineWidget and its own ScreenCaptureKit window. The resulting image contained the real upright red scene without app chrome. Replacing that snapshot with the blue place refreshed the preview to the actual blue scene.

Both fixtures were saved through Studio with LightingStyle=Realistic and PrioritizeLightingQuality=true. The saved red snapshot reopened without the lighting migration notice and returned those settings through Studio MCP. The blue replacement and a second fresh opening did the same. This proves the tested snapshots were saved with current settings; it does not automate migration of arbitrary old imports.

Modern red file SHA-256: `26a4d04f5c73dc278bb5d4c08659cf4a737a914cf0b88dedead12962909edc78`.
Modern blue file SHA-256: `c4b70e100e5e3d4370e0244f022615a3cc758fd99104d4bc3b407496b5090852`.
The replaced red snapshot remained in the archive. The blue source, stored snapshot and a fresh working copy matched the blue hash. Editing and saving another working copy changed only that working file. A subsequent opening restored the original blue marker at (5,5,0) and proof string.

The initial automatic-capture prototype crashed because deferred Objective-C blocks retained references to expired stack values. The final helper owns value copies across callbacks; AddressSanitizer regression tests and subsequent real captures passed. Qt widget grabbing returned invalid viewport pixels and was replaced by process-owned ScreenCaptureKit capture.

The original legacy smoke-test snapshot was replaced through the guarded catalog API with the already Studio-saved modern red fixture. Its prior file remains archived. Both modern test scenes now appear in Scene Tests. The saved catalog, place hashes and PNG hashes were read back, then the regular Studio was restarted and rendered both cards.

The payload was installed in the regular managed Studio and passed strict deep signing. Its pre-v2 backup remains in `.agent-work/install-backups/20261018T223213883413Z`. Startup paused inside Studio's local-plugin filesystem watcher until the user allowed a macOS permission prompt. The same pause returned after the next signed update and cleared after permission was granted again. Temporary clone-only diagnostic flags were removed.

The first Templates-page Add/Edit request exposed an RML GUI queue dependency on menu-bar setup. The helper now always queues GUI work onto the native main queue. In the regular Studio, Add Template opened before any place was opened. Right-clicking the blue card opened its Qt editor, and automatic recapture produced a new verified 640 x 360 blue scene PNG (`e869fbb696eb410ce6e792e734bd878d05ad85712317c8b488f1dad84d8e708e`). The capture copy opened without a migration notice; Studio MCP returned LightingStyle=Realistic, PrioritizeLightingQuality=true, and marker position (5,5,0).

QMenu failed to appear, and an AppKit NSMenu showed its options but failed to apply live selections. Both were replaced by a Qt child dialog with category buttons. In regular Studio, choosing Scene Tests in New Template updated the editor. In Edit Template, Escape and Cancel closed only the chooser and preserved Scene Tests; Return selected the focused category without saving the parent editor. Choosing Personal, saving, and reopening the blue card returned Personal. Choosing Scene Tests and saving again was read back from the catalog. The chooser pages lists longer than eight categories; paging was checked in a harness, not live Studio. After a clean regular-Studio restart, Scene Tests again displayed both red and blue cards with their saved previews and OWNED ribbons. Studio remains on that page.

## Version 0.2.1 — stock styling corrections

The custom page now uses the BuilderSans font roles in this pinned Studio's bundled Foundation typography. A checked enum converter applies the font, and fresh official TextBounds guide the final pill/title size. The SDK's dynamic GetStyled return is unsupported; that reader was removed during review before installation. No general FontFace layout or dynamic Variant-return ABI is assumed.

The native helper measures the live official card, image, title placement, gaps and inset, then uses the same geometry in All and custom categories. The measured regular-Studio card was 225 x 252 logical pixels with a 200 x 200 image (450 x 504 and 400 x 400 device pixels on the tested display). The extra date row is hidden to match Roblox's one-title card layout. The OWNED ribbon and right-click editing remain available.

Highlight repair now handles fill, transparency and text independently. It writes at most three differing properties on one identified live pill per tick while a custom category is selected. There is no lifetime repair limit. Returning to an official category restores or releases that ownership on the same live nodes.

A complete 0.2.1 managed/native build passed with zero managed warnings/errors, and the app passed strict deep signing. In regular Studio, All and Scene Tests showed matching square image/card dimensions and BuilderSans typography. All, Themed and Blank switched to custom categories without a second selected pill or white-on-white text. The empty Personal view was checked too. Right-clicking Blue Scene still opened the editor; Cancel returned without changing the template. A built-in Suburban copy opened during the tab check and was discarded without saving.

The final native regression run passed nine action/ownership checks and seven UI parity groups, including delayed rendering, font sizing, square geometry and 750 partial highlight repairs. The fake engine rejects GetStyled and unexpected reflected calls. Catalog, place snapshots and thumbnail hashes were unchanged after the live checks.

Screenshots are retained as custom-templates-all-v0.2.1.jpg (stock and custom cards together) and custom-templates-studio-v0.2.1.jpg (Scene Tests). This was a short live workflow; it does not establish long-session stability or other Studio builds/themes.

## Version 0.3 — current-place template saves

The File menu adds Save Template and Save Template As without changing Studio's ordinary save commands. Snapshot serialization uses the pinned Studio binary's verified DataModelSerialize wrapper, its native shared-pointer/string-stream types, and the process-global serializer populated by Studio startup. The helper does not read an assumed DataModel serializer field or call the normal Save, Save As, or publish action.

The complete managed/native build passed with zero managed warnings/errors. All 28 catalog tests passed, including independent equal-content Save As entries and session-local document links. The existing nine action/ownership checks, seven UI parity groups, capture lifetime tests, crop tests, and GUI-dispatch tests passed again.

`./scripts/test-current` passed 31 binary-place framing/nonempty checks against three bundled places and five staging ownership/cancellation cases under AddressSanitizer and UndefinedBehaviorSanitizer. It extracts the production parser and staging code, including the exact empty 79-byte regression. These tests do not execute Studio's serializer.

`./scripts/test-file-menu` runs the production File menu module and real SDK Qt wrappers against Studio's Qt 5.15.9. Normal and AddressSanitizer runs passed ten groups covering placement, document-token encoding, enablement, menu rebuilding, connection failure, stop/start, window migration, ambiguity, and status feedback. Twelve exact RML export references and five native helper exports matched the installed binaries. The harness stubs only the command queue and document-token boundaries; it does not exercise engine serialization or final QApplication teardown.

Live testing exposed two integration faults before regular-Studio installation. The SDK omits scalar-bool return encoding, and its inline descriptor lookup used a private uninitialized pointer table in the mod. The helper now uses RML's exported initialized pointer table with descriptor-checked native bool calls. The native serializer wrapper also expects the complete DataModel, while the SDK job accessor supplies its Instance subobject. A guarded standard RTTI conversion now checks the pinned primary/secondary vtables, DataModel type information, offset-to-top and exact roundtrip before calling the wrapper. Empty output fails closed. Independent review verified these relationships against the executable.

In the corrected isolated Studio, Save Template created an internal 52,481-byte snapshot and a viewport PNG without changing the open filename. A later Save updated the same template ID. Save As created an independent ID with equal starting content; the next Save changed only that new template. Cancel preserved the entire catalog and removed transient place/PNG files. The commands were disabled on the Start Page and during a real Run playtest.

Fresh copies of both saved snapshots reopened in Studio. The first retained the unsaved green Part at (22,6,0), while the Save As copy retained its later blue Part at (33,6,0). Both retained the Script Editor text `print('CTPL_AFTER_UNSAVED')`, which had never been saved to the source fixture. Both opened without the lighting migration notice and returned LightingStyle=Soft and PrioritizeLightingQuality=true. Closing the original Edit place still produced Studio's ordinary save-changes prompt, and discarding only those scratch edits left the source fixture unchanged.

Verified original-template SHA-256: `cee2093491ac6b1ab71d14f2ec2655c95866dead94b1d1ce6978938406915896`.
Verified Save As SHA-256 after its later update: `cbda4c3b4327d05cc9d062962f9d899998b805425783fb46fea4dc518057cbf5`.
The seeded source fixture remained `d53c059ba2de8ba87e3bff70388ad353247138a8c70012b9d2f34aeef96f357f`. The user's already-open Init_Dark.rbxl also retained its original hash throughout these checks.

The final isolated run opened the original verified template from its card, immediately edited its Script Editor buffer, and used File > Save Template while the editor stayed active. This resolved the automatic working-copy link, updated the same template ID, left its existing PNG and the other template unchanged, and showed the expected hidden-viewport notice. The opened working file retained its original hash. Script-mode eligibility was also replayed against 1,183 records from a live widget dump: 17 positive/negative topology and identity cases passed with AddressSanitizer and UndefinedBehaviorSanitizer. That temporary harness simulates Qt query boundaries; the live menu/save result is separate evidence.

The tested build was installed in regular RML Studio and passed strict deep signing. Its installed native/managed files exactly matched the build payload. A new working copy opened from the saved card and returned `print('CTPL_SCRIPT_MODE_UNSAVED')` through Studio MCP. File > Save Template updated that linked entry with a new direct viewport PNG; Save Template As opened the Qt dialog with the current preview, and Cancel showed the explicit cancelled status. The three test-only cards were removed through the normal confirmation dialogs, preserving their snapshots in the archive. The library's initial empty template list, categories, and previous revision history were preserved. The user's Init_Dark.rbxl was reopened and remained unchanged.

## Version 0.3.1 — unsaved template places

The File menu commands are now **Save to Template** and **Save to Template As…**. Template-card opening creates an owned staging copy, identifies the exact newly adopted Edit document, and clears its native file destination using this pinned build's File New metadata operations. The document receives its cached native `PlaceN` title. A matching request and stable document ID establish the template-save link before the custom save actions are enabled again. Thumbnail-import capture retains its separate file-opening route.

The native lookup uses Studio's genuine component provider, place manager, session-ID vector, and document lookup. Exact method bytes, vtables, RTTI, constructor-proven session dependencies, source bytes, filename, window, and fresh Edit identity are checked before mutation. The first isolated attempt rejected an NSWorkspace metadata-only xattr change; content hashing now permits that change while rejecting altered bytes. The second stopped before mutation because an older document accessor returned null. The corrected session lookup was independently reviewed and matched the running document's exact type. A regression covers its actual 197-byte path-derived session ID.

Managed build and all 28 catalog checks passed. The existing nine native action checks, seven UI parity groups, and ten real-Qt File menu groups passed; the helper export check now includes `ctpl_open_template`. Current-place staging passed 31 framing and five sanitizer cases. `./scripts/test-open` passed 28 pinned method fingerprints and 53 source-ownership, correlation, and native-session checks under AddressSanitizer and UndefinedBehaviorSanitizer. Native build and strict signature verification passed. These offline checks do not execute the native document transition.

In isolated Studio, a scratch template opened as **Place1**. Ordinary **Save to File** displayed **Place1.rbxl** in the native Save As dialog. After cancellation, a blue marker edit at `(17,10,0)` was saved to a chosen project file; the stored template and staging bytes retained their original hashes. A later red edit at `(27,10,0)` followed by **Save to Template** updated the same template ID and refreshed its viewport PNG without changing that project file. Another ordinary Save wrote the already chosen project path without a dialog and left the template unchanged.

Reopening the updated card created **Place2**, preserved the red marker at `(27,10,0)`, and returned LightingStyle=Soft and PrioritizeLightingQuality=true without a migration notice. Its first normal Save again displayed a native Save As dialog, now with **Place2.rbxl**. **Save to Template As…** opened the separate-template dialog with the linked template's Copy name; Cancel preserved the catalog. Both scratch documents closed normally. The scratch card was removed through its confirmation dialog, preserving its snapshot in the archive.

The scratch template changed from SHA-256 `25c0f975c4dceebec56bcbaf51fd4866216bfe610c585b16a5b124aed5986253` to `7ad840c8e4158cc0955df1778958d697931046bffa7a4c081120b938fa8bd8a8` only after explicit Save to Template. The separately saved project changed from `76fdc374d48bef9821e60b89b3dfc9a3c7cd50849f1d98f39c0ef5597d7e9cbb` to `8d535467522c37ddcfdf5e6aa497ee975a69950f489f7abf1910fe822690d673` only after ordinary Save. The user's Init Dark metadata, stored snapshot, PNG, original download, and already-open working file were unchanged throughout these tests.

The tested build was installed in regular RML Studio. Its managed and native payloads matched the build exactly, and strict deep app signature verification passed. After the user allowed the renewed macOS folder-access prompt, the preserved Init Dark card opened as **Place1**. **Save to File** asked for **Place1.rbxl**; Cancel kept it unsaved. Both renamed File commands became available after viewport activation, and **Save to Template As…** opened with **Init Dark Copy**, confirming its document link. Cancel preserved the template. Studio MCP returned game.Name=Place1, PlaceId=0, LightingStyle=Soft, and PrioritizeLightingQuality=true. No lighting migration notice appeared. Final file hashes and template/category lists matched the pre-test baseline. Regular Studio remains open on the new unsaved Place1.

## Limits

These checks cover the stated workflow, not long-session stability. Both `.rbxlx` and binary `.rbxl` opening were exercised. Dark appearance was checked. Automatic capture uses a bounded geometry-settling delay rather than an engine frame/asset readiness signal; a late-loading scene may need recapture. A failed or cancelled capture retains its previous thumbnail. macOS 14.4+ is required for the process-owned capture API.

Some document opens produced a built-in MaterialManager `debug.profileEnd()` warning in Studio Output. Its cause was not isolated; the tested template contents, save/update actions, and reopening checks still passed. Rapid document switching during an in-flight native save was reviewed in code and identity/queue harnesses, not exercised as a live race.

Live mod unload/reload is unsupported; close Studio before updating or uninstalling. RML may report its assembly context as still rooted during shutdown; the native forwarding hook and callback storage intentionally remain resident until process exit. The catalog validates paths and snapshot integrity; Studio validates place contents on open. Lighting migration must be saved through Studio and supplied as the template replacement to persist it.
