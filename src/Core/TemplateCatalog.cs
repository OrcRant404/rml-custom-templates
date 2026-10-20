using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CustomTemplates.Core;

/// <summary>Owns immutable snapshots and PNGs; opening always makes a new writable copy.</summary>
public sealed class TemplateCatalog
{
    public const int SchemaVersion = 2;
    public const string DefaultCategoryId = "00000000-0000-0000-0000-000000000001";
    public const long MaximumThumbnailBytes = 8 * 1024 * 1024;
    private const long MaximumCatalogBytes = 8 * 1024 * 1024;
    private static readonly byte[] PngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
    private static readonly HashSet<string> ReservedCategories = new(StringComparer.OrdinalIgnoreCase)
        { "All", "Blank", "Gameplay", "Themed" };
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
    private readonly string _templates, _working, _archived, _thumbnails, _lockPath;

    public TemplateCatalog(string? rootDirectory = null)
    {
        rootDirectory ??= DefaultRootDirectory;
        if (string.IsNullOrWhiteSpace(rootDirectory) || !Path.IsPathFullyQualified(rootDirectory))
            throw new ArgumentException("The catalog root must be an absolute path.", nameof(rootDirectory));
        RootDirectory = Path.GetFullPath(rootDirectory);
        _templates = Path.Combine(RootDirectory, "templates");
        _working = Path.Combine(RootDirectory, "working");
        _archived = Path.Combine(RootDirectory, "archived");
        _thumbnails = Path.Combine(RootDirectory, "thumbnails");
        _lockPath = Path.Combine(RootDirectory, "catalog.lock");
        CatalogPath = Path.Combine(RootDirectory, "catalog.json");
        EnsureStorage();
    }

    public static string DefaultRootDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        "Library", "Application Support", "RobloxCustomTemplates");
    public string RootDirectory { get; }
    public string CatalogPath { get; }

    public IReadOnlyList<TemplateEntry> List()
    {
        using var lease = AcquireLock();
        return ReadCatalog().Templates.ToArray();
    }
    public IReadOnlyList<TemplateCategory> ListCategories()
    {
        using var lease = AcquireLock();
        return ReadCatalog().Categories.ToArray();
    }
    public TemplateCategory CreateCategory(string name)
    {
        name = ValidateCategoryName(name);
        using var lease = AcquireLock();
        var catalog = ReadCatalog();
        EnsureCategoryNameAvailable(catalog, name);
        var category = new TemplateCategory(Guid.NewGuid().ToString("D"), name);
        catalog.Categories.Add(category);
        WriteCatalog(catalog);
        return category;
    }
    public TemplateCategory RenameCategory(string id, string name)
    {
        ValidateId(id);
        name = ValidateCategoryName(name);
        using var lease = AcquireLock();
        var catalog = ReadCatalog();
        var existing = FindCategory(catalog, id);
        if (id == DefaultCategoryId) throw new InvalidOperationException("The Personal category cannot be renamed.");
        EnsureCategoryNameAvailable(catalog, name, id);
        var category = existing with { Name = name };
        catalog.Categories[catalog.Categories.IndexOf(existing)] = category;
        WriteCatalog(catalog);
        return category;
    }
    public void RemoveCategory(string id)
    {
        ValidateId(id);
        using var lease = AcquireLock();
        var catalog = ReadCatalog();
        var category = FindCategory(catalog, id);
        if (id == DefaultCategoryId) throw new InvalidOperationException("The Personal category cannot be removed.");
        for (var index = 0; index < catalog.Templates.Count; index++)
        {
            var entry = catalog.Templates[index];
            if (entry.CategoryId != id) continue;
            catalog.Revisions.Add(entry);
            catalog.Templates[index] = entry with { CategoryId = DefaultCategoryId, UpdatedUtc = Now(entry) };
        }
        catalog.Categories.Remove(category);
        WriteCatalog(catalog);
    }

    public TemplateEntry Import(string sourcePath, string? name = null, string? categoryId = null, bool allowDuplicate = false)
    {
        ValidateSource(sourcePath);
        var displayName = ValidateName(name ?? Path.GetFileNameWithoutExtension(sourcePath));
        categoryId ??= DefaultCategoryId;
        ValidateId(categoryId);
        using var lease = AcquireLock();
        var catalog = ReadCatalog();
        _ = FindCategory(catalog, categoryId);
        var id = Guid.NewGuid().ToString("D");
        var fileName = VersionedName(id, Path.GetExtension(sourcePath).ToLowerInvariant());
        var destination = OwnedFile(_templates, fileName);
        var temporary = TemporaryFile(_templates);
        try
        {
            CopyToTemporary(sourcePath, temporary);
            var hash = HashFile(temporary);
            if (!allowDuplicate) RejectDuplicate(catalog, hash, Path.GetExtension(fileName));
            var now = DateTimeOffset.UtcNow;
            var entry = new TemplateEntry(id, displayName, now, fileName, hash, categoryId, now);
            File.Move(temporary, destination);
            try
            {
                SetSnapshotReadOnly(destination);
                catalog.Templates.Add(entry);
                WriteCatalog(catalog);
            }
            catch { DeleteSnapshot(destination); throw; }
            return entry;
        }
        finally { File.Delete(temporary); }
    }

    public TemplateEntry Update(string id, string name, string categoryId, string? replacementSourcePath = null, bool allowDuplicate = false)
    {
        ValidateId(id);
        name = ValidateName(name);
        ValidateId(categoryId);
        using var lease = AcquireLock();
        var catalog = ReadCatalog();
        var existing = FindEntry(catalog, id);
        _ = FindCategory(catalog, categoryId);
        var updated = existing with { Name = name, CategoryId = categoryId, UpdatedUtc = Now(existing) };
        if (replacementSourcePath is null)
        {
            if (name == existing.Name && categoryId == existing.CategoryId) return existing;
            catalog.Revisions.Add(existing);
            catalog.Templates[catalog.Templates.IndexOf(existing)] = updated;
            WriteCatalog(catalog);
            return updated;
        }
        ValidateSource(replacementSourcePath);
        var previous = VerifiedSnapshot(existing);
        var archived = OwnedFile(_archived, existing.FileName);
        var fileName = VersionedName(id, Path.GetExtension(replacementSourcePath).ToLowerInvariant());
        var destination = OwnedFile(_templates, fileName);
        var temporary = TemporaryFile(_templates);
        var copiedPrevious = false;
        var movedReplacement = false;
        try
        {
            CopyToTemporary(replacementSourcePath, temporary);
            var hash = HashFile(temporary);
            if (!allowDuplicate) RejectDuplicate(catalog, hash, Path.GetExtension(fileName), id);
            updated = updated with { FileName = fileName, Sha256 = hash };
            File.Move(temporary, destination);
            movedReplacement = true;
            SetSnapshotReadOnly(destination);
            // Keep the old catalog usable until the new catalog is committed.
            // A process exit before/after the atomic catalog rename can leave
            // an extra file, but never a catalog pointing at a retired snapshot.
            copiedPrevious = StageArchive(existing, previous, archived);
            catalog.Revisions.Add(existing);
            catalog.Templates[catalog.Templates.IndexOf(existing)] = updated;
            WriteCatalog(catalog);
        }
        catch
        {
            if (copiedPrevious) DeleteSnapshot(archived);
            if (movedReplacement) DeleteSnapshot(destination);
            throw;
        }
        finally { File.Delete(temporary); }
        RetireSnapshot(previous);
        return updated;
    }

    public string CreateWorkingCopy(string id)
    {
        ValidateId(id);
        using var lease = AcquireLock();
        var entry = FindEntry(ReadCatalog(), id);
        var source = VerifiedSnapshot(entry);
        var directory = Path.Combine(_working, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        RejectLinks(directory);
        const string suffix = " (Copy)";
        var destination = OwnedFile(directory, SafeFileStem(entry.Name, 200 - Encoding.UTF8.GetByteCount(suffix)) +
            suffix + Path.GetExtension(entry.FileName));
        try
        {
            File.Copy(source, destination, overwrite: false);
            SetWorkingCopyWritable(destination);
            return destination;
        }
        catch { Directory.Delete(directory, recursive: true); throw; }
    }
    public string CreateThumbnailWorkingCopy(string id) => CreateWorkingCopy(id);

    public TemplateEntry SetThumbnail(string id, string pngPath)
    {
        ValidateId(id);
        ValidateSourcePath(pngPath, ".png");
        using var lease = AcquireLock();
        var catalog = ReadCatalog();
        var existing = FindEntry(catalog, id);
        var fileName = VersionedName(id, ".png");
        var destination = OwnedFile(_thumbnails, fileName);
        var temporary = TemporaryFile(_thumbnails);
        try
        {
            CopyToTemporary(pngPath, temporary, MaximumThumbnailBytes);
            var bytes = ReadPng(temporary);
            var updated = existing with
            {
                ThumbnailFileName = fileName,
                ThumbnailSha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)),
                UpdatedUtc = Now(existing)
            };
            File.Move(temporary, destination);
            try
            {
                SetSnapshotReadOnly(destination);
                catalog.Revisions.Add(existing);
                catalog.Templates[catalog.Templates.IndexOf(existing)] = updated;
                WriteCatalog(catalog);
            }
            catch { DeleteSnapshot(destination); throw; }
            return updated;
        }
        finally { File.Delete(temporary); }
    }
    public string? GetThumbnailPath(string id)
    {
        ValidateId(id);
        using var lease = AcquireLock();
        var entry = ReadCatalog().Templates.SingleOrDefault(value => value.Id == id);
        if (entry?.ThumbnailFileName is null) return null;
        try
        {
            var file = OwnedFile(_thumbnails, entry.ThumbnailFileName);
            var bytes = ReadPng(file);
            return HashEquals(Convert.ToHexStringLower(SHA256.HashData(bytes)), entry.ThumbnailSha256!) ? file : null;
        }
        catch (IOException) { return null; }
        catch (InvalidDataException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
    public bool Remove(string id)
    {
        ValidateId(id);
        using var lease = AcquireLock();
        var catalog = ReadCatalog();
        var entry = catalog.Templates.SingleOrDefault(value => value.Id == id);
        if (entry is null) return false;
        var source = OwnedFile(_templates, entry.FileName);
        var archived = OwnedFile(_archived, entry.FileName);
        var copied = false;
        try
        {
            if (File.Exists(source))
            {
                copied = StageArchive(entry, source, archived);
            }
            catalog.Revisions.Add(entry);
            catalog.Templates.Remove(entry);
            WriteCatalog(catalog);
        }
        catch { if (copied) DeleteSnapshot(archived); throw; }
        if (File.Exists(source)) RetireSnapshot(source);
        return true;
    }

    private CatalogDocument ReadCatalog()
    {
        RejectLinks(CatalogPath);
        if (!File.Exists(CatalogPath)) return new CatalogDocument();
        try
        {
            byte[] bytes;
            using (var stream = File.OpenRead(CatalogPath))
            {
                if (stream.Length > MaximumCatalogBytes) throw new CatalogFormatException("The catalog exceeds the supported size.");
                bytes = new byte[checked((int)stream.Length)];
                stream.ReadExactly(bytes);
            }
            using var json = JsonDocument.Parse(bytes);
            if (json.RootElement.ValueKind != JsonValueKind.Object ||
                !json.RootElement.TryGetProperty("schemaVersion", out var schema) || !schema.TryGetInt32(out var version))
                throw new CatalogFormatException("The catalog schema version is missing.");
            if (version == 1) return MigrateSchemaOne(bytes);
            if (version != SchemaVersion) throw new CatalogFormatException($"Unsupported catalog schema version {version}.");
            var document = JsonSerializer.Deserialize<CatalogDocument>(bytes, JsonOptions)
                ?? throw new CatalogFormatException("The catalog is empty.");
            ValidateDocument(document);
            return document;
        }
        catch (CatalogFormatException) { throw; }
        catch (Exception exception) when (exception is JsonException or ArgumentException or NullReferenceException or InvalidOperationException)
        { throw new CatalogFormatException("The catalog is damaged. Its contents have been preserved.", exception); }
    }
    private CatalogDocument MigrateSchemaOne(byte[] original)
    {
        var legacy = JsonSerializer.Deserialize<LegacyDocument>(original, JsonOptions)
            ?? throw new CatalogFormatException("The catalog is empty.");
        if (legacy.Templates is null) throw new CatalogFormatException("The catalog template list is missing.");
        var document = new CatalogDocument();
        foreach (var entry in legacy.Templates)
        {
            if (entry is null) throw new CatalogFormatException("The catalog contains an empty template entry.");
            ValidateId(entry.Id);
            if (entry.FileName != entry.Id + Path.GetExtension(entry.FileName))
                throw new CatalogFormatException("The legacy catalog contains an unsafe template filename.");
            document.Templates.Add(new TemplateEntry(entry.Id, entry.Name, entry.CreatedUtc, entry.FileName,
                entry.Sha256, DefaultCategoryId, entry.CreatedUtc));
        }
        ValidateDocument(document);
        var backup = OwnedFile(RootDirectory, "catalog.schema1-" + Guid.NewGuid().ToString("N") + ".json");
        using (var stream = new FileStream(backup, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { stream.Write(original); stream.Flush(flushToDisk: true); }
        SetSnapshotReadOnly(backup);
        WriteCatalog(document);
        return document;
    }
    private void ValidateDocument(CatalogDocument document)
    {
        if (document.Templates is null || document.Categories is null || document.Revisions is null)
            throw new CatalogFormatException("The catalog lists are missing.");
        var categoryIds = new HashSet<string>(StringComparer.Ordinal);
        var categoryNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var category in document.Categories)
        {
            if (category is null) throw new CatalogFormatException("The catalog contains an empty category.");
            ValidateId(category.Id);
            if (!categoryIds.Add(category.Id) || !categoryNames.Add(category.Name) ||
                ValidateCategoryName(category.Name) != category.Name)
                throw new CatalogFormatException("The catalog contains invalid or duplicate categories.");
            if (category.Id == DefaultCategoryId && category.Name != "Personal")
                throw new CatalogFormatException("The default Personal category is invalid.");
        }
        if (!categoryIds.Contains(DefaultCategoryId)) throw new CatalogFormatException("The default Personal category is missing.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in document.Templates)
        {
            ValidateEntry(entry, historical: false);
            if (!ids.Add(entry.Id) || !categoryIds.Contains(entry.CategoryId))
                throw new CatalogFormatException("The catalog contains duplicate template IDs or an unknown category.");
        }
        foreach (var entry in document.Revisions) ValidateEntry(entry, historical: true);
    }
    private void ValidateEntry(TemplateEntry entry, bool historical)
    {
        if (entry is null) throw new CatalogFormatException("The catalog contains an empty template entry.");
        ValidateId(entry.Id);
        ValidateId(entry.CategoryId);
        if (ValidateName(entry.Name) != entry.Name || entry.CreatedUtc == default ||
            entry.UpdatedUtc == default || entry.UpdatedUtc < entry.CreatedUtc)
            throw new CatalogFormatException("The catalog contains invalid template metadata.");
        ValidateOwnedName(entry.Id, entry.FileName, thumbnail: false);
        _ = OwnedFile(_templates, entry.FileName);
        if (historical) _ = OwnedFile(_archived, entry.FileName);
        ValidateHash(entry.Sha256);
        if ((entry.ThumbnailFileName is null) != (entry.ThumbnailSha256 is null))
            throw new CatalogFormatException("Thumbnail filename and hash must be provided together.");
        if (entry.ThumbnailFileName is not null)
        {
            ValidateOwnedName(entry.Id, entry.ThumbnailFileName, thumbnail: true);
            ValidateHash(entry.ThumbnailSha256!);
            // Optional preview damage must not block place opens. The getter
            // checks links, PNG contents, existence and hash before returning it.
        }
    }
    private void WriteCatalog(CatalogDocument document)
    {
        RejectLinks(CatalogPath);
        var temporary = TemporaryFile(RootDirectory, ".catalog-");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, document, JsonOptions);
                if (stream.Length > MaximumCatalogBytes) throw new CatalogFormatException("The catalog exceeds the supported size.");
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, CatalogPath, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }
    private string VerifiedSnapshot(TemplateEntry entry)
    {
        var source = OwnedFile(_templates, entry.FileName);
        if (!File.Exists(source)) throw new FileNotFoundException("The imported template snapshot is missing.", source);
        if (!HashEquals(HashFile(source), entry.Sha256))
            throw new InvalidDataException("The imported template snapshot has changed. Reimport the place before opening it.");
        return source;
    }
    private static TemplateEntry FindEntry(CatalogDocument catalog, string id) =>
        catalog.Templates.SingleOrDefault(value => value.Id == id)
        ?? throw new KeyNotFoundException("The template is not in this catalog.");
    private static TemplateCategory FindCategory(CatalogDocument catalog, string id) =>
        catalog.Categories.SingleOrDefault(value => value.Id == id)
        ?? throw new KeyNotFoundException("The category is not in this catalog.");
    private static DateTimeOffset Now(TemplateEntry entry)
    {
        var now = DateTimeOffset.UtcNow;
        return now > entry.UpdatedUtc ? now : entry.UpdatedUtc;
    }
    private static string VersionedName(string id, string extension) => id + "-" + Guid.NewGuid().ToString("N") + extension;
    private static string TemporaryFile(string directory, string prefix = ".import-") =>
        OwnedFile(directory, prefix + Guid.NewGuid().ToString("N") + ".tmp");
    private static void EnsureCategoryNameAvailable(CatalogDocument catalog, string name, string? exceptId = null)
    {
        if (catalog.Categories.Any(value => value.Id != exceptId && value.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("A category with that name already exists.", nameof(name));
    }
    private static void RejectDuplicate(CatalogDocument catalog, string hash, string extension, string? exceptId = null)
    {
        var duplicate = catalog.Templates.FirstOrDefault(value => value.Id != exceptId &&
            HashEquals(value.Sha256, hash) && Path.GetExtension(value.FileName).Equals(extension, StringComparison.OrdinalIgnoreCase));
        if (duplicate is not null) throw new DuplicateTemplateException(duplicate);
    }
    private static void CopyToTemporary(string sourcePath, string temporary, long maximumBytes = long.MaxValue)
    {
        RejectLinks(sourcePath);
        using var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (source.Length == 0) throw new InvalidDataException("The source file is empty.");
        if (source.Length > maximumBytes) throw new InvalidDataException("The PNG exceeds the supported size.");
        using var target = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        var buffer = new byte[81920];
        int count;
        while ((count = source.Read(buffer)) != 0)
        {
            if (target.Position > maximumBytes - count) throw new InvalidDataException("The PNG exceeds the supported size.");
            target.Write(buffer, 0, count);
        }
        target.Flush(flushToDisk: true);
    }
    private static bool StageArchive(TemplateEntry entry, string source, string archived)
    {
        // Reuse a complete prior staging result after a process exit. Never
        // overwrite an archive containing different bytes.
        if (File.Exists(archived))
        {
            if (!HashEquals(HashFile(archived), entry.Sha256))
                throw new InvalidDataException("An existing archive does not match the previous snapshot.");
            SetSnapshotReadOnly(archived);
            return false;
        }
        var temporary = TemporaryFile(Path.GetDirectoryName(archived)!, ".archive-");
        try
        {
            CopyToTemporary(source, temporary);
            if (!HashEquals(HashFile(temporary), entry.Sha256))
                throw new InvalidDataException("The previous snapshot changed while being archived.");
            SetSnapshotReadOnly(temporary);
            File.Move(temporary, archived, overwrite: false);
            return true;
        }
        finally { DeleteSnapshot(temporary); }
    }
    private static byte[] ReadPng(string path)
    {
        RejectLinks(path);
        using var stream = File.OpenRead(path);
        if (stream.Length < 57 || stream.Length > MaximumThumbnailBytes) throw new InvalidDataException("The PNG has an unsupported size.");
        var bytes = new byte[checked((int)stream.Length)];
        stream.ReadExactly(bytes);
        if (!bytes.AsSpan(0, 8).SequenceEqual(PngSignature)) throw new InvalidDataException("The thumbnail must be a PNG image.");
        var offset = 8;
        var sawHeader = false;
        var sawData = false;
        var sawEnd = false;
        while (offset <= bytes.Length - 12)
        {
            var length = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(offset, 4));
            if (length > (uint)(bytes.Length - offset - 12)) throw new InvalidDataException("The PNG contains a truncated chunk.");
            var type = Encoding.ASCII.GetString(bytes, offset + 4, 4);
            var payload = bytes.AsSpan(offset + 8, (int)length);
            if (!sawHeader)
            {
                if (type != "IHDR" || length != 13) throw new InvalidDataException("The PNG header is missing.");
                var width = BinaryPrimitives.ReadUInt32BigEndian(payload[..4]);
                var height = BinaryPrimitives.ReadUInt32BigEndian(payload.Slice(4, 4));
                if (width is 0 or > 4096 || height is 0 or > 4096) throw new InvalidDataException("The PNG dimensions exceed the supported size.");
                sawHeader = true;
            }
            else if (type == "IHDR") throw new InvalidDataException("The PNG contains duplicate headers.");
            if (type == "IDAT") sawData = true;
            offset += checked((int)length + 12);
            if (type == "IEND")
            {
                if (length != 0 || offset != bytes.Length) throw new InvalidDataException("The PNG ending is invalid.");
                sawEnd = true;
                break;
            }
        }
        if (!sawHeader || !sawData || !sawEnd) throw new InvalidDataException("The PNG is incomplete.");
        return bytes;
    }

    private FileStream AcquireLock()
    {
        EnsureStorage();
        RejectLinks(_lockPath);
        var timeout = Environment.TickCount64 + 3000;
        while (true)
        {
            try { return new FileStream(_lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) when (Environment.TickCount64 < timeout) { Thread.Sleep(20); }
        }
    }
    private void EnsureStorage()
    {
        foreach (var directory in new[] { RootDirectory, _templates, _working, _archived, _thumbnails })
        { RejectLinks(directory); Directory.CreateDirectory(directory); }
    }
    private static void RejectLinks(string fullPath)
    {
        for (var current = new FileInfo(fullPath); current is not null;)
        {
            if (current.LinkTarget is not null) throw new IOException("Catalog storage cannot contain symbolic links.");
            current = current.Directory is { } parent ? new FileInfo(parent.FullName) : null;
        }
    }
    private static string OwnedFile(string directory, string fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName) || Path.GetFileName(fileName) != fileName ||
            fileName.Contains('/') || fileName.Contains('\\') || fileName is "." or "..")
            throw new CatalogFormatException("The catalog contains an unsafe filename.");
        var fullPath = Path.Combine(directory, fileName);
        RejectLinks(fullPath);
        return fullPath;
    }
    private static void ValidateOwnedName(string id, string fileName, bool thumbnail)
    {
        if (fileName is null || Path.GetFileName(fileName) != fileName || fileName.Contains('/') || fileName.Contains('\\'))
            throw new CatalogFormatException("The catalog contains an unsafe filename.");
        var extension = Path.GetExtension(fileName);
        if (thumbnail ? extension != ".png" : !IsPlaceExtension(extension))
            throw new CatalogFormatException("The catalog contains an unsupported owned filename.");
        var stem = Path.GetFileNameWithoutExtension(fileName);
        if (!thumbnail && stem == id) return; // Preserved schema-one snapshots.
        if (!stem.StartsWith(id + "-", StringComparison.Ordinal) ||
            !Guid.TryParseExact(stem[(id.Length + 1)..], "N", out var version) ||
            version.ToString("N") != stem[(id.Length + 1)..])
            throw new CatalogFormatException("The catalog contains an unsafe versioned filename.");
    }
    private static void ValidateSource(string sourcePath)
    {
        if (string.IsNullOrWhiteSpace(sourcePath) || !Path.IsPathFullyQualified(sourcePath))
            throw new ArgumentException("Choose an absolute path to an existing place file.", nameof(sourcePath));
        if (!IsPlaceExtension(Path.GetExtension(sourcePath)))
            throw new ArgumentException("Choose a .rbxl or .rbxlx place file.", nameof(sourcePath));
        ValidateSourcePath(sourcePath);
    }
    private static void ValidateSourcePath(string path, string? extension = null)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            throw new ArgumentException("Choose an absolute path to an existing file.", nameof(path));
        if (extension is not null && !Path.GetExtension(path).Equals(extension, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Choose a PNG image.", nameof(path));
        RejectLinks(path);
        if (!File.Exists(path)) throw new FileNotFoundException("The source file does not exist.", path);
    }
    private static bool IsPlaceExtension(string extension) =>
        extension.Equals(".rbxl", StringComparison.OrdinalIgnoreCase) || extension.Equals(".rbxlx", StringComparison.OrdinalIgnoreCase);
    private static string ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Give the template a name.", nameof(name));
        name = name.Trim().Normalize(NormalizationForm.FormC);
        if (name.Length > 120 || name.Any(char.IsControl))
            throw new ArgumentException("Use a name of at most 120 characters without control characters.", nameof(name));
        return name;
    }
    private static string ValidateCategoryName(string name)
    {
        name = ValidateName(name);
        if (ReservedCategories.Contains(name)) throw new ArgumentException("That name is reserved for a Studio category.", nameof(name));
        return name;
    }
    private static void ValidateId(string id)
    {
        if (!Guid.TryParseExact(id, "D", out var guid) || guid.ToString("D") != id)
            throw new ArgumentException("The catalog ID is invalid.", nameof(id));
    }
    private static void ValidateHash(string hash)
    {
        if (hash is null || hash.Length != 64 || hash.Any(character => !char.IsAsciiHexDigit(character)))
            throw new CatalogFormatException("The catalog contains an invalid asset hash.");
    }
    private static string SafeFileStem(string name, int maximumBytes)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var safe = new string(name.Select(character => invalid.Contains(character) ||
            character is '/' or '\\' or ':' ? '-' : character).ToArray()).Trim(' ', '.');
        var limited = new StringBuilder();
        var bytes = 0;
        foreach (var rune in safe.EnumerateRunes())
        {
            if (bytes + rune.Utf8SequenceLength > maximumBytes) break;
            limited.Append(rune);
            bytes += rune.Utf8SequenceLength;
        }
        safe = limited.ToString().Trim(' ', '.');
        return safe.Length == 0 ? "Untitled" : safe;
    }
    private static string HashFile(string file)
    {
        RejectLinks(file);
        using var stream = File.OpenRead(file);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }
    private static bool HashEquals(string first, string second) => first.Equals(second, StringComparison.OrdinalIgnoreCase);
    private static void SetSnapshotReadOnly(string file)
    {
        if (OperatingSystem.IsWindows()) File.SetAttributes(file, File.GetAttributes(file) | FileAttributes.ReadOnly);
        else File.SetUnixFileMode(file, UnixFileMode.UserRead);
    }
    private static void SetWorkingCopyWritable(string file)
    {
        if (OperatingSystem.IsWindows()) File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
        else File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
    private static void DeleteSnapshot(string file)
    {
        if (!File.Exists(file)) return;
        RejectLinks(file);
        SetWorkingCopyWritable(file);
        File.Delete(file);
    }
    private static void RetireSnapshot(string file)
    {
        // The committed catalog already uses the new snapshot (or removed the
        // entry), and a read-only archive exists. Cleanup failure may leave an
        // unreferenced extra file; rolling back now would invalidate the commit.
        try { DeleteSnapshot(file); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    private sealed class CatalogDocument
    {
        [JsonRequired] public int SchemaVersion { get; init; } = TemplateCatalog.SchemaVersion;
        [JsonRequired] public List<TemplateCategory> Categories { get; init; } = [new(DefaultCategoryId, "Personal")];
        [JsonRequired] public List<TemplateEntry> Templates { get; init; } = [];
        [JsonRequired] public List<TemplateEntry> Revisions { get; init; } = [];
    }
    private sealed class LegacyDocument
    {
        [JsonRequired] public int SchemaVersion { get; init; }
        [JsonRequired] public List<LegacyEntry> Templates { get; init; } = [];
    }
    private sealed record LegacyEntry(string Id, string Name, DateTimeOffset CreatedUtc, string FileName, string Sha256);
}
