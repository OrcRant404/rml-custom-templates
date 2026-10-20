using System.Globalization;
using System.Text.Json;
using CustomTemplates.Core;
using RML.Core.Api;
using RML.Core.Modding;

namespace CustomTemplates;

[Mod("custom-templates", "0.3.1", Author = "OrcRant404",
    Description = "Local categories, snapshots and thumbnails on Studio's Templates page")]
public sealed class CustomTemplatesMod : ModBase
{
    private const int MaxCommandsPerPoll = 32;
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(50);
    private NativeBridge? _native;
    private TemplateCatalog? _catalog;
    private Thread? _worker;
    private ManualResetEventSlim? _stopSignal;
    private int _revision;
    private int _selectRevision;
    private string? _selectedCategoryId;
    private string _status = "Your templates are stored locally.";
    private bool _statusError;
    private CaptureRequest? _capture;
    private TemplateOpen? _templateOpen;
    private string? _lastOpenPath;
    private readonly TemplateDocumentLinks _documentLinks = new();
    private CurrentSave? _currentSave;
    private bool _currentSaveCommand;
    private bool _templateOpenCommand;

    public override int OnLoad()
    {
        if (_native is not null) return 0;
        try
        {
            var catalog = new TemplateCatalog();
            var native = new NativeBridge();
            var stopSignal = new ManualResetEventSlim(false);
            _catalog = catalog;
            _native = native;
            _stopSignal = stopSignal;
            _revision = 1;
            PublishCatalog(catalog.List());
            native.Start();
            _worker = new Thread(() => PollCommands(catalog, native, stopSignal))
            {
                IsBackground = true,
                Name = "Custom Templates catalog worker"
            };
            _worker.Start();
            Logger.Info("Custom Templates ready. Catalog work runs on its own .NET thread.");
            return 0;
        }
        catch { OnUnload(); throw; }
    }

    public override void OnUnload()
    {
        _stopSignal?.Set();
        if (_worker is { } worker && worker != Thread.CurrentThread) worker.Join();
        _worker = null;
        var native = _native;
        _native = null;
        try { native?.Dispose(); }
        finally
        {
            _capture = null;
            _templateOpen = null;
            _lastOpenPath = null;
            ClearCurrentSave();
            _catalog = null;
            _stopSignal?.Dispose();
            _stopSignal = null;
        }
        Logger.Info("Custom Templates unloaded.");
    }

    private void PollCommands(TemplateCatalog catalog, NativeBridge native, ManualResetEventSlim stopSignal)
    {
        while (!stopSignal.IsSet)
        {
            var processed = 0;
            try
            {
                for (; processed < MaxCommandsPerPoll; processed++)
                {
                    if (!native.TryPollCommand(out var json)) break;
                    ProcessCommand(json, catalog, native);
                }
                if (processed > 0) PublishCatalog(catalog.List());
            }
            catch (Exception exception)
            {
                SetStatus(exception.Message, isError: true);
                if (_currentSaveCommand)
                {
                    ClearCurrentSave();
                    native.ShowNotice(exception.Message);
                }
                if (_templateOpenCommand)
                {
                    _templateOpen = null;
                    native.ShowNotice(exception.Message);
                }
                Logger.Warn($"Custom Templates command failed: {exception.GetType().Name}.");
                TryPublishCatalog(catalog);
            }
            stopSignal.Wait(PollInterval);
        }
    }

    private void ProcessCommand(string json, TemplateCatalog catalog, NativeBridge native)
    {
        _currentSaveCommand = false;
        _templateOpenCommand = false;
        var command = JsonSerializer.Deserialize<NativeCommand>(json, CommandJsonOptions)
            ?? throw new InvalidDataException("Studio sent an incomplete template command.");
        _currentSaveCommand = command.Type is "save_current_template" or "save_current_template_as" or
            "current_place_snapshot" or "current_place_snapshot_failed" or "save_current_snapshot";
        _templateOpenCommand = command.Type is "template_opened" or "template_open_failed";
        switch (command.Type)
        {
            case "save_current_template":
            case "save_current_template_as":
                BeginCurrentSave(command.Type == "save_current_template_as", Required(command.DocumentId, "open document"), catalog, native);
                break;
            case "current_place_snapshot":
                ReceiveCurrentSnapshot(command, catalog, native);
                break;
            case "current_place_snapshot_failed":
                if (_currentSave is null || _currentSave.RequestId != command.RequestId) break;
                ClearCurrentSave();
                SetStatus(command.Message ?? "Studio could not snapshot the open place.", true);
                native.ShowNotice(_status);
                break;
            case "save_current_snapshot":
                if (_currentSave is not { DocumentId: not null } currentSave || currentSave.RequestId != command.RequestId) break;
                CommitCurrentSave(currentSave, Required(command.Name, "template name"), command.CategoryId,
                    command.ThumbnailPath, command.CaptureThumbnail, null, catalog, native);
                break;
            case "import":
                ShowDialog("create", null, command.CategoryId, catalog, native);
                break;
            case "edit":
                ShowDialog("edit", Required(command.Id, "template"), null, catalog, native);
                break;
            case "category_new":
                ShowDialog("category_new", null, null, catalog, native);
                break;
            case "category_edit":
                ShowDialog("category_edit", Required(command.Id, "category"), null, catalog, native);
                break;
            case "save_category":
                var category = string.IsNullOrEmpty(command.Id)
                    ? catalog.CreateCategory(Required(command.Name, "category name"))
                    : catalog.RenameCategory(command.Id, Required(command.Name, "category name"));
                _revision++;
                SelectCategory(category.Id);
                SetStatus($"Category {category.Name} saved.");
                break;
            case "remove_category":
                catalog.RemoveCategory(Required(command.Id, "category"));
                _revision++;
                SelectCategory(TemplateCatalog.DefaultCategoryId);
                SetStatus("Category removed. Its templates are in Personal.");
                break;
            case "save_template":
                SaveTemplate(command, catalog, native);
                break;
            case "open":
                OpenTemplate(Required(command.Id, "template"), catalog, native);
                break;
            case "template_opened":
                if (_templateOpen is not { } opened || opened.RequestId != command.RequestId) break;
                if (command.Path != opened.Path)
                    throw new InvalidDataException("Studio returned a different template opening request.");
                _documentLinks.Bind(Required(command.StableDocumentId, "open document identity"), opened.Id);
                _templateOpen = null;
                SetStatus("A new place is ready. Save to File chooses where to keep it.");
                break;
            case "template_open_failed":
                if (_templateOpen is not { } failed || failed.RequestId != command.RequestId) break;
                _templateOpen = null;
                SetStatus(command.Message ?? "Studio could not create a new place from this template.", true);
                native.ShowNotice(_status);
                break;
            case "open_failed":
                if (command.Path != _lastOpenPath) break;
                if (_capture?.PlacePath == command.Path)
                {
                    native.CancelCapture();
                    _capture = null;
                }
                SetStatus(command.Message ?? "Studio could not open the working copy.", true);
                break;
            case "remove":
                var removeId = Required(command.Id, "template");
                if (_capture?.Id == removeId) { native.CancelCapture(); _capture = null; }
                if (!catalog.Remove(removeId)) throw new KeyNotFoundException("This owned template is no longer available.");
                _revision++;
                SetStatus("Template removed. Its snapshot is kept in the archive.");
                break;
            case "thumbnail_captured":
                FinishCapture(command, catalog);
                break;
            case "thumbnail_failed":
                if (_capture?.RequestId == command.RequestId)
                {
                    _capture = null;
                    SetStatus("Template saved. " + (command.Message ?? "Thumbnail capture failed. Edit the template to try again."), true);
                }
                break;
            case "dialog_cancelled":
                if (_currentSave?.RequestId == command.RequestId)
                {
                    ClearCurrentSave();
                    SetStatus("Template save cancelled.");
                }
                if (!string.IsNullOrWhiteSpace(command.Error))
                {
                    SetStatus(command.Error, true);
                    Logger.Warn(command.Error);
                }
                break;
            default:
                throw new InvalidDataException("Studio sent an unsupported template command.");
        }
    }

    private void BeginCurrentSave(bool saveAs, string documentId, TemplateCatalog catalog, NativeBridge native)
    {
        if (_currentSave is not null)
        {
            native.ShowNotice("Finish or cancel the template save already in progress before starting another.");
            return;
        }
        var requestId = Guid.NewGuid().ToString("D");
        var parent = Path.Combine(catalog.RootDirectory, "saves");
        if (new DirectoryInfo(parent).LinkTarget is not null) throw new IOException("Template save staging cannot contain symbolic links.");
        Directory.CreateDirectory(parent);
        if (new DirectoryInfo(parent).LinkTarget is not null) throw new IOException("Template save staging cannot contain symbolic links.");
        var directory = Path.Combine(parent, requestId);
        Directory.CreateDirectory(directory);
        var request = new CurrentSave(requestId, Path.Combine(directory, "place.rbxl"),
            Path.Combine(directory, "thumbnail.png"), saveAs, documentId);
        _currentSave = request;
        if (!native.SnapshotCurrentPlace(JsonSerializer.Serialize(new
        {
            requestId, documentId, path = request.Path, thumbnailPath = request.ThumbnailPath
        })))
        {
            ClearCurrentSave();
            throw new InvalidOperationException("Saving the open place as a template is unavailable in this Studio build.");
        }
        SetStatus("Saving the open place to a template snapshot…");
    }

    private void ReceiveCurrentSnapshot(NativeCommand command, TemplateCatalog catalog, NativeBridge native)
    {
        var request = _currentSave;
        if (request is null || request.DocumentId is not null || command.RequestId != request.RequestId || command.Path != request.Path) return;
        var documentId = Required(command.DocumentId, "open document identity");
        if (documentId != request.ExpectedDocumentId) throw new InvalidDataException("The open place changed before it could be saved as a template.");
        var stableDocumentId = Required(command.StableDocumentId, "open document identity");
        if (command.ThumbnailPath is not null && command.ThumbnailPath != request.ThumbnailPath)
            throw new InvalidDataException("Studio returned an unexpected thumbnail path.");
        request = request with { DocumentId = stableDocumentId, SourcePath = command.SourcePath,
            Name = string.IsNullOrWhiteSpace(command.Name) ? "Untitled Template" : command.Name,
            Message = command.Message };
        _currentSave = request;
        var linked = _documentLinks.Resolve(stableDocumentId, command.SourcePath, catalog.List());
        if (!request.SaveAs && linked is not null)
        {
            CommitCurrentSave(request, linked.Name, linked.CategoryId, null, true, linked, catalog, native);
            return;
        }
        var payload = JsonSerializer.Serialize(new
        {
            mode = "create", currentPlace = true, requestId = request.RequestId,
            name = linked is null ? request.Name : linked.Name + " Copy",
            categoryId = linked?.CategoryId ?? _selectedCategoryId ?? TemplateCatalog.DefaultCategoryId,
            thumbnailPath = File.Exists(request.ThumbnailPath) ? request.ThumbnailPath : null,
            sourcePath = request.Path, sourceLabel = request.Name,
            categories = catalog.ListCategories().Select(value => new { id = value.Id, name = value.Name }),
            defaultCategoryId = TemplateCatalog.DefaultCategoryId
        });
        if (!native.ShowDialog(payload)) throw new InvalidOperationException("The Qt template editor is unavailable in this Studio build.");
    }

    private void CommitCurrentSave(CurrentSave request, string name, string? categoryId, string? thumbnailPath,
        bool automaticThumbnail, TemplateEntry? existing, TemplateCatalog catalog, NativeBridge native)
    {
        var entry = existing is null
            ? catalog.Import(request.Path, name, categoryId, allowDuplicate: true)
            : catalog.Update(existing.Id, existing.Name, existing.CategoryId, request.Path, allowDuplicate: true);
        if (_capture?.Id == entry.Id) { native.CancelCapture(); _capture = null; }
        _documentLinks.Bind(Required(request.DocumentId, "open document identity"), entry.Id);
        _revision++;
        SelectCategory(entry.CategoryId);
        SetStatus($"Saved template {entry.Name}.");
        try
        {
            var png = !string.IsNullOrWhiteSpace(thumbnailPath) ? thumbnailPath
                : automaticThumbnail && File.Exists(request.ThumbnailPath) ? request.ThumbnailPath : null;
            if (png is not null) catalog.SetThumbnail(entry.Id, png);
            else if (automaticThumbnail) SetStatus($"Saved template {entry.Name}. " +
                (request.Message ?? "The viewport thumbnail could not be captured."), true);
        }
        catch (Exception exception) { SetStatus($"Template saved. Thumbnail could not be changed: {exception.Message}", true); }
        finally { ClearCurrentSave(); }
        if (_statusError) native.ShowNotice(_status);
    }

    private void ClearCurrentSave()
    {
        var request = _currentSave;
        _currentSave = null;
        if (request is null) return;
        foreach (var path in new[] { request.Path, request.ThumbnailPath })
        {
            try { File.Delete(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private void ShowDialog(string mode, string? id, string? categoryId, TemplateCatalog catalog, NativeBridge native)
    {
        var categories = catalog.ListCategories();
        var entry = mode == "edit" ? catalog.List().SingleOrDefault(value => value.Id == id)
            ?? throw new KeyNotFoundException("Only your own saved templates can be edited.") : null;
        var category = mode == "category_edit" ? categories.SingleOrDefault(value => value.Id == id)
            ?? throw new KeyNotFoundException("This custom category is no longer available.") : null;
        if (categoryId is not null && !categories.Any(value => value.Id == categoryId)) categoryId = null;
        var payload = JsonSerializer.Serialize(new
        {
            mode, id,
            name = entry?.Name ?? category?.Name ?? "",
            categoryId = entry?.CategoryId ?? categoryId ?? TemplateCatalog.DefaultCategoryId,
            thumbnailPath = entry is null ? null : catalog.GetThumbnailPath(entry.Id),
            @protected = category?.Id == TemplateCatalog.DefaultCategoryId,
            categories = categories.Select(value => new { id = value.Id, name = value.Name }),
            defaultCategoryId = TemplateCatalog.DefaultCategoryId
        });
        if (!native.ShowDialog(payload)) throw new InvalidOperationException("The Qt template editor is unavailable in this Studio build.");
    }

    private void SaveTemplate(NativeCommand command, TemplateCatalog catalog, NativeBridge native)
    {
        var name = Required(command.Name, "template name");
        TemplateEntry entry;
        try
        {
            if (string.IsNullOrEmpty(command.Id))
                entry = catalog.Import(Required(command.Path, "place file"), name, command.CategoryId);
            else
                entry = catalog.Update(command.Id, name, command.CategoryId ?? TemplateCatalog.DefaultCategoryId,
                    string.IsNullOrWhiteSpace(command.Path) ? null : command.Path);
        }
        catch (DuplicateTemplateException exception)
        {
            SelectCategory(exception.Existing.CategoryId);
            SetStatus(exception.Message);
            return;
        }
        // A successful edit supersedes any earlier capture for this entry,
        // including when the user has now turned automatic capture off.
        if (_capture?.Id == entry.Id) { native.CancelCapture(); _capture = null; }
        _revision++;
        SelectCategory(entry.CategoryId);
        SetStatus($"Saved {entry.Name}.");
        if (!string.IsNullOrWhiteSpace(command.ThumbnailPath))
        {
            try
            {
                catalog.SetThumbnail(entry.Id, command.ThumbnailPath);
                SetStatus($"Saved {entry.Name} with the selected thumbnail.");
            }
            catch (Exception exception)
            {
                SetStatus($"Template saved. Thumbnail could not be changed: {exception.Message}", true);
            }
        }
        else if (command.CaptureThumbnail)
        {
            try { StartCapture(entry, catalog, native); }
            catch (Exception exception)
            {
                SetStatus($"Template saved. Thumbnail capture could not start: {exception.Message}", true);
            }
        }
    }

    private void OpenTemplate(string id, TemplateCatalog catalog, NativeBridge native)
    {
        if (_templateOpen is not null)
        {
            SetStatus("Wait for the template already opening.");
            return;
        }
        if (_capture is not null)
        {
            native.CancelCapture();
            _capture = null;
        }
        var requestId = Guid.NewGuid().ToString("D");
        var copy = catalog.CreateWorkingCopy(id);
        var path = Path.Combine(Path.GetDirectoryName(copy)!, "CTPL-OPEN-" + requestId + Path.GetExtension(copy));
        File.Move(copy, path);
        _templateOpen = new(id, requestId, path);
        try
        {
            if (!native.OpenTemplate(JsonSerializer.Serialize(new { id, requestId, path })))
                throw new IOException("Studio could not start a new place from this template.");
        }
        catch { _templateOpen = null; throw; }
        SetStatus("Opening a new place from your saved template…");
    }

    private void StartCapture(TemplateEntry entry, TemplateCatalog catalog, NativeBridge native)
    {
        native.CancelCapture();
        _capture = null;
        var requestId = Guid.NewGuid().ToString("D");
        var placePath = catalog.CreateWorkingCopy(entry.Id);
        // Studio may expose a basename rather than the full document path to
        // Qt. A per-request filename prevents collisions across equal names.
        var capturePlacePath = Path.Combine(Path.GetDirectoryName(placePath)!,
            "CTPL-" + requestId + Path.GetExtension(placePath));
        File.Move(placePath, capturePlacePath);
        placePath = capturePlacePath;
        // Captures are transient, isolated from snapshots and final PNGs. The
        // core validates and copies the completed PNG into owned storage.
        var directory = Path.Combine(catalog.RootDirectory, "captures", requestId);
        foreach (var folder in new[] { Path.GetDirectoryName(directory)!, directory })
            if (new DirectoryInfo(folder).LinkTarget is not null)
                throw new IOException("Thumbnail staging cannot contain symbolic links.");
        Directory.CreateDirectory(directory);
        foreach (var folder in new[] { Path.GetDirectoryName(directory)!, directory })
            if (new DirectoryInfo(folder).LinkTarget is not null)
                throw new IOException("Thumbnail staging cannot contain symbolic links.");
        var path = Path.Combine(directory, "viewport.png");
        if (!native.OpenWorkingCopy(placePath))
        {
            SetStatus("Template saved, but Studio could not open its thumbnail copy.", true);
            return;
        }
        _lastOpenPath = placePath;
        _documentLinks.RememberWorkingCopy(placePath, entry.Id);
        _capture = new(entry.Id, requestId, path, placePath, entry.Sha256);
        // Verified in the Qt widget tree of the supported Studio build. The
        // Start Page engine widget has a different name and cannot match.
        if (!native.RequestThumbnail(JsonSerializer.Serialize(new
        {
            id = entry.Id, requestId, path, placePath,
            viewportName = "QEngineWidget", viewportClass = "RBX::Studio::QEngineWidget"
        })))
        {
            _capture = null;
            SetStatus("Template saved, but automatic thumbnail capture is unavailable.", true);
            return;
        }
        SetStatus("Template saved. Opening its copy to capture the 3D viewport…");
    }

    private void FinishCapture(NativeCommand command, TemplateCatalog catalog)
    {
        var request = _capture;
        if (request is null || request.RequestId != command.RequestId || request.Id != command.Id ||
            !string.Equals(request.Path, command.Path, StringComparison.Ordinal)) return;
        _capture = null;
        var entry = catalog.List().SingleOrDefault(value => value.Id == request.Id);
        if (entry is null || entry.Sha256 != request.SnapshotSha256) return;
        catalog.SetThumbnail(request.Id, request.Path);
        _revision++;
        SetStatus($"Saved {entry.Name} with its new thumbnail.");
        // Cleanup must not hide a successfully committed thumbnail from UI.
        try { File.Delete(request.Path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void SelectCategory(string id) { _selectedCategoryId = id; _selectRevision++; }
    private void SetStatus(string status, bool isError = false)
    {
        _status = status;
        _statusError = isError;
        _native?.ShowStatus(status);
    }
    private static string Required(string? value, string field) => !string.IsNullOrWhiteSpace(value)
        ? value : throw new ArgumentException($"Choose a valid {field}.");

    private void PublishCatalog(IReadOnlyList<TemplateEntry> entries)
    {
        var catalog = _catalog ?? throw new InvalidOperationException("The catalog is unavailable.");
        var snapshot = JsonSerializer.Serialize(new
        {
            revision = _revision, selectRevision = _selectRevision,
            selectedCategoryId = _selectedCategoryId,
            categories = catalog.ListCategories().Select(value => new { id = value.Id, name = value.Name }),
            templates = entries.Select(entry => new
            {
                id = entry.Id, name = entry.Name, categoryId = entry.CategoryId, owned = true,
                date = entry.UpdatedUtc.ToLocalTime().ToString("MMM d yyyy", CultureInfo.CurrentCulture),
                thumbnailPath = catalog.GetThumbnailPath(entry.Id),
                thumbnailUri = CacheThumbnail(catalog, entry)
            }),
            status = _status, statusError = _statusError
        });
        if (_native is null || !_native.PublishCatalog(snapshot))
            throw new InvalidOperationException("The native UI rejected the catalog snapshot.");
    }

    private void TryPublishCatalog(TemplateCatalog catalog)
    {
        try { PublishCatalog(catalog.List()); }
        catch (Exception exception) { Logger.Error($"Could not publish the template catalog: {exception.GetType().Name}."); }
    }

    private static string CacheThumbnail(TemplateCatalog catalog, TemplateEntry entry)
    {
        var source = catalog.GetThumbnailPath(entry.Id);
        if (source is null || entry.ThumbnailFileName is null) return "";
        // The installer creates this private cache and its signed asset alias.
        // The authoritative PNG remains in the user's catalog.
        var cache = Path.Combine("/Library/Caches", "RobloxCustomTemplates-" + GetUserId());
        if (new DirectoryInfo(cache).LinkTarget is not null) return "";
        if (!Directory.Exists(cache))
        {
            if (!OperatingSystem.IsMacOS()) return "";
            Directory.CreateDirectory(cache, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        var destination = Path.Combine(cache, entry.ThumbnailFileName);
        if (new FileInfo(destination).LinkTarget is not null) return "";
        if (!File.Exists(destination))
        {
            var temporary = Path.Combine(cache, ".copy-" + Guid.NewGuid().ToString("N"));
            try { File.Copy(source, temporary); File.Move(temporary, destination, overwrite: true); }
            finally { File.Delete(temporary); }
        }
        return "rbxasset://RMLCustomTemplates/" + entry.ThumbnailFileName;
    }

    [System.Runtime.InteropServices.DllImport("libc", EntryPoint = "getuid")]
    private static extern uint GetUserId();

    private static readonly JsonSerializerOptions CommandJsonOptions = new() { PropertyNameCaseInsensitive = true, MaxDepth = 8 };
    private sealed class NativeCommand
    {
        public string? Type { get; init; }
        public string? Path { get; init; }
        public string? Id { get; init; }
        public string? Name { get; init; }
        public string? CategoryId { get; init; }
        public string? RequestId { get; init; }
        public string? ThumbnailPath { get; init; }
        public string? Message { get; init; }
        public string? Error { get; init; }
        public string? DocumentId { get; init; }
        public string? StableDocumentId { get; init; }
        public string? SourcePath { get; init; }
        public bool CaptureThumbnail { get; init; } = true;
    }
    private sealed record CaptureRequest(string Id, string RequestId, string Path, string PlacePath, string SnapshotSha256);
    private sealed record TemplateOpen(string Id, string RequestId, string Path);
    private sealed record CurrentSave(string RequestId, string Path, string ThumbnailPath, bool SaveAs, string ExpectedDocumentId,
        string? DocumentId = null, string? SourcePath = null, string Name = "Untitled Template", string? Message = null);
}
