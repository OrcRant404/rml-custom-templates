using System.Text.Json;
using System.Text.Json.Nodes;
using CustomTemplates.Core;

if (args.Length != 1 || !Path.IsPathFullyQualified(args[0]))
    throw new ArgumentException("Pass an absolute repository scratch directory.");
Directory.CreateDirectory(args[0]);
var suiteRoot = Path.Combine(args[0], Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(suiteRoot);
var tests = new (string Name, Action Body)[]
{
    ("imports own snapshot and persists explicit schema", Persistence),
    ("working copies cannot overwrite source or snapshot", Isolation),
    ("spaces and non-ASCII filenames round trip", UnicodeNames),
    ("invalid paths and empty files leave catalog unchanged", InvalidSources),
    ("duplicate content is rejected without extra snapshots", Duplicate),
    ("removing archives import and preserves working copies", Archive),
    ("corrupt JSON fails closed without overwriting evidence", CorruptCatalog),
    ("unsupported and missing schemas fail closed", InvalidSchemas),
    ("unsafe catalog filenames and duplicate IDs are rejected", InvalidMetadata),
    ("changed or missing snapshots never become working places", InvalidSnapshot),
    ("symbolic storage folders and files are rejected", SymbolicPaths),
    ("display name cannot become an escaping working path", SafeWorkingPath),
    ("concurrent catalog instances preserve all imports", Concurrency),
    ("failed atomic save cleans imported snapshot", FailedSave),
    ("schema-one migration preserves bytes IDs and snapshots", Migration),
    ("categories persist and deletion safely reassigns templates", Categories),
    ("metadata edits and replacements isolate originals and working copies", UpdateIsolation),
    ("updates reject foreign IDs categories and duplicate snapshots", InvalidUpdates),
    ("PNG previews are owned unique immutable copies", Thumbnails),
    ("invalid PNG previews leave no partial files or metadata", InvalidThumbnails),
    ("damaged missing or linked optional previews are unavailable", DamagedThumbnails),
    ("schema-two malformed metadata fails closed", MalformedVersionTwo),
    ("failed catalog writes roll back updates thumbnails and categories", UpdateRollback),
    ("archive collisions cannot overwrite retained revisions", ArchiveCollision),
    ("complete archive staging survives an interrupted commit", StagedArchiveRecovery),
    ("failed migration preserves the original schema-one catalog", MigrationRollback),
    ("save as creates independent equal-content templates", SaveAsDuplicate),
    ("document save links only resolve existing owned templates", DocumentLinks)
};
var failed = 0;
foreach (var test in tests)
{
    try { test.Body(); Console.WriteLine("PASS " + test.Name); }
    catch (Exception exception) { failed++; Console.Error.WriteLine("FAIL " + test.Name + "\n" + exception); }
}
Console.WriteLine($"{tests.Length - failed}/{tests.Length} tests passed. Scratch: {suiteRoot}");
return failed == 0 ? 0 : 1;

string NewCase()
{
    var result = Path.Combine(suiteRoot, Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(result);
    return result;
}

void SaveAsDuplicate()
{
    var (catalog, source, _) = NewCatalog();
    var original = catalog.Import(source, "Original");
    var copy = catalog.Import(source, "Save As Copy", allowDuplicate: true);
    Check(original.Id != copy.Id && original.FileName != copy.FileName, "Save As has a separate identity and snapshot");
    Check(original.Sha256 == copy.Sha256 && catalog.List().Count == 2, "same content is permitted for explicit Save As");
    copy = catalog.Update(copy.Id, copy.Name, copy.CategoryId, source, allowDuplicate: true);
    Check(copy.Sha256 == original.Sha256, "a later Save can retain content shared with the original");
    catalog.Update(copy.Id, copy.Name, copy.CategoryId, WriteOtherSource());
    Check(catalog.List().Single(entry => entry.Id == original.Id) == original, "updating copy preserves original");

    string WriteOtherSource()
    {
        var path = Path.Combine(Path.GetDirectoryName(source)!, "changed.rbxlx");
        File.WriteAllText(path, "<roblox version=\"4\"><Item class=\"Lighting\" /></roblox>");
        return path;
    }
}

void DocumentLinks()
{
    var (catalog, source, _) = NewCatalog();
    var first = catalog.Import(source);
    var second = catalog.Import(source, "Copy", allowDuplicate: true);
    var working = catalog.CreateWorkingCopy(first.Id);
    var links = new TemplateDocumentLinks();
    links.RememberWorkingCopy(working, first.Id);
    Check(links.Resolve("document-1", source, catalog.List()) is null, "an unrelated original path has no implicit owner");
    Check(links.Resolve("document-1", working, catalog.List()) == first, "opening a registered working copy links it");
    Check(links.Resolve("document-2", source, catalog.List()) is null, "other documents are isolated");
    links.Bind("new-unsaved-document", first.Id);
    Check(links.Resolve("new-unsaved-document", null, catalog.List()) == first,
        "a confirmed new template document resolves without a saved filename");
    Check(links.Resolve("new-unsaved-document", Path.Combine(Path.GetDirectoryName(source)!, "Saved Elsewhere.rbxl"), catalog.List()) == first,
        "normal Save As does not change the new document's template target");
    Check(links.Resolve("unrelated-unsaved-document", null, catalog.List()) is null,
        "another unsaved document cannot acquire the new document's template target");
    links.Bind("document-1", second.Id);
    Check(links.Resolve("document-1", working, catalog.List()) == second, "Save As changes only this document's save target");
    Check(links.Resolve("document-3", working, catalog.List()) == first, "another open of the old template retains its original target");
    catalog.Remove(second.Id);
    Check(links.Resolve("document-1", working, catalog.List()) is null, "a removed target cannot fall back to a different template");
    Check(links.Resolve("", working, catalog.List()) is null, "an absent document identity cannot acquire a target");
}

(TemplateCatalog Catalog, string Source, string Root) NewCatalog(string filename = "My place.rbxlx", string contents = "<roblox version=\"4\"><Item class=\"Workspace\" /></roblox>")
{
    var root = NewCase();
    var source = Path.Combine(root, filename);
    File.WriteAllText(source, contents);
    return (new TemplateCatalog(Path.Combine(root, "catalog")), source, root);
}

void Persistence()
{
    var (catalog, source, _) = NewCatalog();
    var entry = catalog.Import(source, "  Forest Base  ");
    Check(entry.Name == "Forest Base", "name is trimmed");
    Check(Guid.TryParseExact(entry.Id, "D", out _), "stable GUID ID");
    Check(entry.CreatedUtc.Offset == TimeSpan.Zero, "UTC timestamp");
    var copy = new TemplateCatalog(catalog.RootDirectory).List().Single();
    Check(copy == entry, "metadata survives new catalog instance");
    using var json = JsonDocument.Parse(File.ReadAllText(catalog.CatalogPath));
    Check(json.RootElement.GetProperty("schemaVersion").GetInt32() == 2, "explicit schema version");
    Check(entry.CategoryId == TemplateCatalog.DefaultCategoryId && entry.UpdatedUtc == entry.CreatedUtc, "default category and initial update time");
    Check(!File.ReadAllText(catalog.CatalogPath).Contains(source, StringComparison.Ordinal), "original source path not persisted");
}

void Isolation()
{
    foreach (var extension in new[] { ".rbxl", ".rbxlx" })
    {
        var (catalog, source, _) = NewCatalog("My place" + extension);
        var original = File.ReadAllText(source);
        var entry = catalog.Import(source);
        var snapshot = Path.Combine(catalog.RootDirectory, "templates", entry.FileName);
        var first = catalog.CreateWorkingCopy(entry.Id);
        var second = catalog.CreateWorkingCopy(entry.Id);
        Check(first != second && Path.GetDirectoryName(first) != Path.GetDirectoryName(second) &&
            first != snapshot && first != source && second != snapshot && second != source, "unique isolated open paths");
        Check(Path.GetFileName(first) == "My place (Copy)" + extension &&
            Path.GetFileName(second) == "My place (Copy)" + extension, "both open filenames clearly identify copies");
        Check(first.StartsWith(Path.Combine(catalog.RootDirectory, "working") + Path.DirectorySeparatorChar, StringComparison.Ordinal) &&
            second.StartsWith(Path.Combine(catalog.RootDirectory, "working") + Path.DirectorySeparatorChar, StringComparison.Ordinal),
            "ordinary saves target working storage");
        Check(File.ReadAllText(first) == original && File.ReadAllText(second) == original, "copies start with snapshot bytes");
        File.WriteAllText(first, "working change");
        Check(File.ReadAllText(source) == original && File.ReadAllText(snapshot) == original &&
            File.ReadAllText(second) == original, "saving one copy leaves source, snapshot and other open unchanged");
        File.WriteAllText(source, "source changed after import");
        Check(File.ReadAllText(catalog.CreateWorkingCopy(entry.Id)) == original &&
            File.ReadAllText(first) == "working change", "later opens use the snapshot independently of source and existing copies");
        if (OperatingSystem.IsWindows())
            Check((File.GetAttributes(first) & FileAttributes.ReadOnly) == 0 &&
                (File.GetAttributes(snapshot) & FileAttributes.ReadOnly) != 0, "copy writable and stored snapshot read-only");
        else
            Check((File.GetUnixFileMode(first) & UnixFileMode.UserWrite) != 0 &&
                (File.GetUnixFileMode(snapshot) & (UnixFileMode.UserWrite | UnixFileMode.GroupWrite | UnixFileMode.OtherWrite)) == 0,
                "copy writable and stored snapshot read-only");
    }
}

void UnicodeNames()
{
    var (catalog, source, _) = NewCatalog("雪の 島 café.RBXLX");
    var entry = catalog.Import(source);
    Check(entry.Name == "雪の 島 café", "Unicode display name");
    var working = catalog.CreateWorkingCopy(entry.Id);
    Check(Path.GetFileName(working) == "雪の 島 café (Copy).rbxlx", "Unicode working filename identifies a copy");
    Check(File.ReadAllText(working) == File.ReadAllText(source), "copy bytes");
    foreach (var longName in new[] { new string('雪', 120), string.Concat(Enumerable.Repeat("😀", 60)), new string('雪', 63) + "a😀" })
    {
        var (longCatalog, longSource, _) = NewCatalog();
        var longEntry = longCatalog.Import(longSource, longName);
        var longCopy = longCatalog.CreateWorkingCopy(longEntry.Id);
        var fileName = Path.GetFileName(longCopy);
        Check(fileName.EndsWith(" (Copy).rbxlx", StringComparison.Ordinal), "long Unicode names retain the copy suffix");
        var strictUtf8 = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
        Check(strictUtf8.GetByteCount(Path.GetFileNameWithoutExtension(fileName)) <= 200 &&
            strictUtf8.GetByteCount(fileName) < 255, "copy suffix stays within stem and filesystem limits without splitting Unicode runes");
        Check(longCatalog.List().Single().Name == longName, "full display name retained");
    }
}

void InvalidSources()
{
    var (catalog, source, root) = NewCatalog();
    foreach (var invalid in new[] { "", " ", "relative.rbxl", Path.Combine(root, "wrong.txt") })
        Throws<ArgumentException>(() => catalog.Import(invalid));
    Throws<FileNotFoundException>(() => catalog.Import(Path.Combine(root, "missing.rbxl")));
    var directory = Path.Combine(root, "directory.rbxl");
    Directory.CreateDirectory(directory);
    Throws<FileNotFoundException>(() => catalog.Import(directory));
    var empty = Path.Combine(root, "empty.rbxl");
    File.WriteAllText(empty, "");
    Throws<InvalidDataException>(() => catalog.Import(empty));
    Throws<ArgumentException>(() => catalog.Import(source, "\n"));
    Throws<ArgumentException>(() => catalog.Import(source, "invalid\nname"));
    Throws<ArgumentException>(() => catalog.Import(source, new string('a', 121)));
    Throws<ArgumentException>(() => new TemplateCatalog("relative"));
    Check(catalog.List().Count == 0 && !File.Exists(catalog.CatalogPath), "no partial entry");
    Check(Directory.GetFiles(Path.Combine(catalog.RootDirectory, "templates")).Length == 0, "no temporary import");
}

void Duplicate()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    var secondSource = Path.Combine(root, "other.rbxlx");
    File.Copy(source, secondSource);
    var exception = Throws<DuplicateTemplateException>(() => catalog.Import(secondSource, "Other name"));
    Check(exception.Existing == entry, "duplicate identifies existing template");
    Check(catalog.List().Count == 1, "one association");
    Check(Directory.GetFiles(Path.Combine(catalog.RootDirectory, "templates")).Length == 1, "one snapshot");
    File.WriteAllText(secondSource, "different bytes");
    var distinct = catalog.Import(secondSource, entry.Name);
    Check(distinct.Id != entry.Id && catalog.List().Count == 2, "same names allow distinct places");
}

void Archive()
{
    var (catalog, source, _) = NewCatalog();
    var entry = catalog.Import(source);
    var working = catalog.CreateWorkingCopy(entry.Id);
    Check(catalog.Remove(entry.Id), "removal returns true");
    Check(catalog.List().Count == 0 && !catalog.Remove(entry.Id), "association removed persistently");
    Check(File.Exists(Path.Combine(catalog.RootDirectory, "archived", entry.FileName)), "archive preserved");
    Check(!File.Exists(Path.Combine(catalog.RootDirectory, "templates", entry.FileName)), "not active snapshot");
    Check(File.Exists(working) && File.Exists(source), "working place and source preserved");
    Throws<KeyNotFoundException>(() => catalog.CreateWorkingCopy(entry.Id));
}

void CorruptCatalog()
{
    var (catalog, source, _) = NewCatalog();
    File.WriteAllText(catalog.CatalogPath, "{broken JSON");
    Throws<CatalogFormatException>(() => catalog.List());
    Throws<CatalogFormatException>(() => catalog.Import(source));
    Check(File.ReadAllText(catalog.CatalogPath) == "{broken JSON", "original corruption preserved");
    Check(Directory.GetFiles(Path.Combine(catalog.RootDirectory, "templates")).Length == 0, "no partial import");
}

void InvalidSchemas()
{
    var (catalog, _, _) = NewCatalog();
    foreach (var json in new[] { "null", "{}", "{\"templates\":[]}", "{\"schemaVersion\":1}",
        "{\"schemaVersion\":99,\"templates\":[]}", "{\"schemaVersion\":1,\"templates\":null}" })
    {
        File.WriteAllText(catalog.CatalogPath, json);
        Throws<CatalogFormatException>(() => catalog.List());
        Check(File.ReadAllText(catalog.CatalogPath) == json, "unsupported data preserved");
    }
}

void InvalidMetadata()
{
    var (catalog, source, _) = NewCatalog();
    catalog.Import(source);
    var good = File.ReadAllText(catalog.CatalogPath);
    var doc = JsonNode.Parse(good)!;
    doc["templates"]![0]!["fileName"] = "../../outside.rbxlx";
    File.WriteAllText(catalog.CatalogPath, doc.ToJsonString());
    Throws<CatalogFormatException>(() => catalog.List());
    doc = JsonNode.Parse(good)!;
    doc["templates"]!.AsArray().Add(doc["templates"]![0]!.DeepClone());
    File.WriteAllText(catalog.CatalogPath, doc.ToJsonString());
    Throws<CatalogFormatException>(() => catalog.List());
    File.WriteAllText(catalog.CatalogPath, good);
    Throws<ArgumentException>(() => catalog.CreateWorkingCopy("../../outside"));
    Throws<ArgumentException>(() => catalog.Remove(""));
}

void InvalidSnapshot()
{
    var (catalog, source, _) = NewCatalog();
    var entry = catalog.Import(source);
    var snapshot = Path.Combine(catalog.RootDirectory, "templates", entry.FileName);
    if (!OperatingSystem.IsWindows())
        File.SetUnixFileMode(snapshot, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    else
        File.SetAttributes(snapshot, FileAttributes.Normal);
    File.WriteAllText(snapshot, "tampered");
    Throws<InvalidDataException>(() => catalog.CreateWorkingCopy(entry.Id));
    File.Delete(snapshot);
    Throws<FileNotFoundException>(() => catalog.CreateWorkingCopy(entry.Id));
    Check(Directory.GetDirectories(Path.Combine(catalog.RootDirectory, "working")).Length == 0, "no unsafe copy");
}

void SymbolicPaths()
{
    if (OperatingSystem.IsWindows()) return;
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    var snapshot = Path.Combine(catalog.RootDirectory, "templates", entry.FileName);
    File.Delete(snapshot);
    File.CreateSymbolicLink(snapshot, source);
    Throws<IOException>(() => catalog.List());
    Throws<IOException>(() => catalog.CreateWorkingCopy(entry.Id));
    var linkedRoot = Path.Combine(root, "linked-root");
    Directory.CreateSymbolicLink(linkedRoot, catalog.RootDirectory);
    Throws<IOException>(() => new TemplateCatalog(linkedRoot));
    var secondRoot = Path.Combine(root, "second");
    Directory.CreateDirectory(secondRoot);
    Directory.CreateSymbolicLink(Path.Combine(secondRoot, "templates"), root);
    Throws<IOException>(() => new TemplateCatalog(secondRoot));
}

void SafeWorkingPath()
{
    var (catalog, source, _) = NewCatalog();
    var entry = catalog.Import(source, "../../escaped\\place: name");
    var working = catalog.CreateWorkingCopy(entry.Id);
    Check(working.StartsWith(Path.Combine(catalog.RootDirectory, "working") + Path.DirectorySeparatorChar, StringComparison.Ordinal), "copy inside working folder");
    Check(Path.GetFileName(working) == "-..-escaped-place- name (Copy).rbxlx", "display name sanitized as copy filename");
    Check(File.Exists(working), "copy exists");
    var untitled = catalog.Import(source, "...", allowDuplicate: true);
    Check(Path.GetFileName(catalog.CreateWorkingCopy(untitled.Id)) == "Untitled (Copy).rbxlx",
        "a name that sanitizes to empty still identifies the copy");
}

void Concurrency()
{
    var (catalog, _, root) = NewCatalog();
    Parallel.For(0, 8, index =>
    {
        var source = Path.Combine(root, "parallel-" + index + ".rbxlx");
        File.WriteAllText(source, "distinct " + index);
        new TemplateCatalog(catalog.RootDirectory).Import(source);
    });
    Check(catalog.List().Count == 8, "no lost updates across instances");
    using var document = JsonDocument.Parse(File.ReadAllText(catalog.CatalogPath));
    Check(document.RootElement.GetProperty("templates").GetArrayLength() == 8, "complete JSON written");
    Check(Directory.GetFiles(catalog.RootDirectory, ".catalog-*.tmp").Length == 0, "no save leftovers");
}

void FailedSave()
{
    var (catalog, source, _) = NewCatalog();
    Directory.CreateDirectory(catalog.CatalogPath);
    Throws<IOException>(() => catalog.Import(source));
    Check(Directory.GetFiles(Path.Combine(catalog.RootDirectory, "templates")).Length == 0, "rollback imported snapshot");
    Check(Directory.GetFiles(catalog.RootDirectory, ".catalog-*.tmp").Length == 0, "rollback temporary catalog");
}

(TemplateCatalog Catalog, TemplateEntry Entry, string OriginalJson, string Source) LegacyFixture()
{
    var (catalog, source, _) = NewCatalog();
    var entry = catalog.Import(source, "Legacy template");
    var legacyFileName = entry.Id + Path.GetExtension(entry.FileName);
    File.Move(Path.Combine(catalog.RootDirectory, "templates", entry.FileName),
        Path.Combine(catalog.RootDirectory, "templates", legacyFileName));
    entry = entry with { FileName = legacyFileName };
    var json = JsonSerializer.Serialize(new
    {
        schemaVersion = 1,
        templates = new[] { new { id = entry.Id, name = entry.Name, createdUtc = entry.CreatedUtc,
            fileName = entry.FileName, sha256 = entry.Sha256 } }
    }, new JsonSerializerOptions { WriteIndented = true });
    File.WriteAllText(catalog.CatalogPath, json);
    return (catalog, entry, json, source);
}

void Migration()
{
    var (catalog, original, json, source) = LegacyFixture();
    var migrated = new TemplateCatalog(catalog.RootDirectory).List().Single();
    Check(migrated.Id == original.Id && migrated.FileName == original.FileName &&
        migrated.Sha256 == original.Sha256 && migrated.CreatedUtc == original.CreatedUtc, "snapshot identity and metadata preserved");
    Check(migrated.CategoryId == TemplateCatalog.DefaultCategoryId && migrated.UpdatedUtc == migrated.CreatedUtc, "Personal assigned");
    Check(File.ReadAllText(catalog.CreateWorkingCopy(migrated.Id)) == File.ReadAllText(source), "migrated snapshot opens");
    var backup = Directory.GetFiles(catalog.RootDirectory, "catalog.schema1-*.json").Single();
    Check(File.ReadAllText(backup) == json, "exact original JSON backed up");
    using var document = JsonDocument.Parse(File.ReadAllText(catalog.CatalogPath));
    Check(document.RootElement.GetProperty("schemaVersion").GetInt32() == 2, "schema two committed");
    _ = catalog.ListCategories();
    Check(Directory.GetFiles(catalog.RootDirectory, "catalog.schema1-*.json").Length == 1, "migration runs once");
}

void Categories()
{
    var (catalog, source, _) = NewCatalog();
    Check(catalog.ListCategories().Single() == new TemplateCategory(TemplateCatalog.DefaultCategoryId, "Personal"), "stable default");
    var category = catalog.CreateCategory("  Islands  ");
    var entry = catalog.Import(source, categoryId: category.Id);
    Check(entry.CategoryId == category.Id, "import selected category");
    var renamed = catalog.RenameCategory(category.Id, "雪の島");
    Check(renamed.Id == category.Id && renamed.Name == "雪の島", "rename retains category identity");
    Check(new TemplateCatalog(catalog.RootDirectory).ListCategories().Contains(renamed), "category persists");
    Throws<ArgumentException>(() => catalog.CreateCategory("雪の島"));
    Throws<ArgumentException>(() => catalog.CreateCategory("personal"));
    foreach (var reserved in new[] { "ALL", "Blank", "Gameplay", "Themed" })
        Throws<ArgumentException>(() => catalog.CreateCategory(reserved));
    Throws<ArgumentException>(() => catalog.CreateCategory("bad\nname"));
    Throws<InvalidOperationException>(() => catalog.RemoveCategory(TemplateCatalog.DefaultCategoryId));
    Throws<InvalidOperationException>(() => catalog.RenameCategory(TemplateCatalog.DefaultCategoryId, "Elsewhere"));
    catalog.RemoveCategory(category.Id);
    var reassigned = catalog.List().Single();
    Check(reassigned.CategoryId == TemplateCatalog.DefaultCategoryId && reassigned.FileName == entry.FileName &&
        reassigned.Sha256 == entry.Sha256, "delete reassigns without touching the snapshot");
    Check(catalog.ListCategories().Count == 1 && File.Exists(catalog.CreateWorkingCopy(entry.Id)), "still opens after reassignment");
}

void UpdateIsolation()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    var originalBytes = File.ReadAllText(source);
    var working = catalog.CreateWorkingCopy(entry.Id);
    File.WriteAllText(working, "existing working changes");
    var category = catalog.CreateCategory("Building");
    var renamed = catalog.Update(entry.Id, "  Edited name  ", category.Id);
    Check(renamed.Name == "Edited name" && renamed.FileName == entry.FileName &&
        renamed.Sha256 == entry.Sha256 && renamed.CreatedUtc == entry.CreatedUtc, "metadata edit preserves snapshot identity");
    Check(renamed.UpdatedUtc >= renamed.CreatedUtc, "update time valid");
    var replacement = Path.Combine(root, "replacement.rbxl");
    File.WriteAllText(replacement, "replacement snapshot bytes");
    var replaced = catalog.Update(entry.Id, renamed.Name, category.Id, replacement);
    Check(replaced.Id == entry.Id && replaced.FileName != entry.FileName &&
        Path.GetExtension(replaced.FileName) == ".rbxl", "replacement retains entry ID and versions the file");
    Check(File.ReadAllText(Path.Combine(catalog.RootDirectory, "archived", entry.FileName)) == originalBytes, "previous snapshot archived intact");
    Check(File.ReadAllText(source) == originalBytes && File.ReadAllText(replacement) == "replacement snapshot bytes", "both sources unchanged");
    Check(File.ReadAllText(working) == "existing working changes", "existing working copy unchanged");
    Check(File.ReadAllText(catalog.CreateWorkingCopy(entry.Id)) == "replacement snapshot bytes", "new opens use replacement");
    var sameContent = catalog.Update(entry.Id, renamed.Name, category.Id, replacement);
    Check(sameContent.FileName != replaced.FileName, "same owned entry may replace its own identical content");
    Check(File.ReadAllText(Path.Combine(catalog.RootDirectory, "archived", replaced.FileName)) == "replacement snapshot bytes", "every snapshot revision retained");
    using var json = JsonDocument.Parse(File.ReadAllText(catalog.CatalogPath));
    Check(json.RootElement.GetProperty("revisions").GetArrayLength() == 3, "old metadata retained for rollback");
}

void InvalidUpdates()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    var second = Path.Combine(root, "second.rbxlx");
    File.WriteAllText(second, "different snapshot");
    catalog.Import(second);
    var unknown = Guid.NewGuid().ToString("D");
    var original = File.ReadAllText(catalog.CatalogPath);
    Throws<KeyNotFoundException>(() => catalog.Update(unknown, "Foreign", TemplateCatalog.DefaultCategoryId, source));
    Throws<KeyNotFoundException>(() => catalog.Update(entry.Id, "Foreign category", unknown));
    Throws<KeyNotFoundException>(() => catalog.Import(source, categoryId: unknown));
    Throws<DuplicateTemplateException>(() => catalog.Update(entry.Id, "Duplicate", TemplateCatalog.DefaultCategoryId, second));
    Throws<ArgumentException>(() => catalog.Update(entry.Id, "Bad path", TemplateCatalog.DefaultCategoryId, "relative.rbxl"));
    var empty = Path.Combine(root, "empty.rbxl");
    File.WriteAllText(empty, "");
    Throws<InvalidDataException>(() => catalog.Update(entry.Id, "Empty", TemplateCatalog.DefaultCategoryId, empty));
    if (!OperatingSystem.IsWindows())
    {
        var link = Path.Combine(root, "source-link.rbxlx");
        File.CreateSymbolicLink(link, source);
        Throws<IOException>(() => catalog.Import(link));
        Throws<IOException>(() => catalog.Update(entry.Id, "Link", TemplateCatalog.DefaultCategoryId, link));
    }
    Check(File.ReadAllText(catalog.CatalogPath) == original, "invalid updates preserve catalog bytes");
    Check(Directory.GetFiles(Path.Combine(catalog.RootDirectory, "templates")).Length == 2 &&
        Directory.GetFiles(Path.Combine(catalog.RootDirectory, "archived")).Length == 0, "no partial replacement or archive");
}

string WritePng(string directory)
{
    var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".png");
    File.WriteAllBytes(path, Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII="));
    return path;
}

void Thumbnails()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    Check(catalog.GetThumbnailPath(entry.Id) is null, "initially no thumbnail");
    var png = WritePng(root);
    var original = File.ReadAllBytes(png);
    var first = catalog.SetThumbnail(entry.Id, png);
    var owned = catalog.GetThumbnailPath(entry.Id)!;
    Check(owned.StartsWith(Path.Combine(catalog.RootDirectory, "thumbnails") + Path.DirectorySeparatorChar, StringComparison.Ordinal) &&
        owned != png && File.ReadAllBytes(owned).SequenceEqual(original), "owned PNG copy");
    File.Delete(png);
    Check(catalog.GetThumbnailPath(entry.Id) == owned, "source deletion cannot remove owned thumbnail");
    var second = catalog.SetThumbnail(entry.Id, WritePng(root));
    Check(second.ThumbnailFileName != first.ThumbnailFileName && File.Exists(owned), "new filename avoids cache and retains prior PNG");
    Check(new TemplateCatalog(catalog.RootDirectory).GetThumbnailPath(entry.Id) is not null, "thumbnail survives restart");
    var capture = catalog.CreateThumbnailWorkingCopy(entry.Id);
    var otherCapture = catalog.CreateThumbnailWorkingCopy(entry.Id);
    var snapshot = Path.Combine(catalog.RootDirectory, "templates", entry.FileName);
    var placeBytes = File.ReadAllText(source);
    Check(capture != otherCapture && capture != source && capture != snapshot && otherCapture != source && otherCapture != snapshot &&
        Path.GetFileName(capture) == "My place (Copy).rbxlx" && File.ReadAllText(capture) == placeBytes,
        "capture uses a named isolated place copy");
    File.WriteAllText(capture, "capture-only change");
    Check(File.ReadAllText(source) == placeBytes && File.ReadAllText(snapshot) == placeBytes &&
        File.ReadAllText(otherCapture) == placeBytes, "capture saves cannot alter source, stored place or another capture");
    var replacement = Path.Combine(root, "new.rbxlx");
    File.WriteAllText(replacement, "new template");
    var replaced = catalog.Update(entry.Id, entry.Name, entry.CategoryId, replacement);
    Check(replaced.ThumbnailFileName == second.ThumbnailFileName && catalog.GetThumbnailPath(entry.Id) is not null &&
        File.Exists(owned), "replacement keeps the last good preview until a successful capture");
}

void InvalidThumbnails()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    var png = WritePng(root);
    Throws<KeyNotFoundException>(() => catalog.SetThumbnail(Guid.NewGuid().ToString("D"), png));
    Throws<ArgumentException>(() => catalog.SetThumbnail(entry.Id, "relative.png"));
    Throws<ArgumentException>(() => catalog.SetThumbnail(entry.Id, source));
    Throws<FileNotFoundException>(() => catalog.SetThumbnail(entry.Id, Path.Combine(root, "missing.png")));
    foreach (var bytes in new[] { Array.Empty<byte>(), new byte[70], new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 },
        File.ReadAllBytes(png)[..^1] })
    {
        var invalid = Path.Combine(root, "bad.png");
        File.WriteAllBytes(invalid, bytes);
        Throws<InvalidDataException>(() => catalog.SetThumbnail(entry.Id, invalid));
    }
    var oversized = Path.Combine(root, "oversized.png");
    using (var stream = File.Create(oversized)) stream.SetLength(TemplateCatalog.MaximumThumbnailBytes + 1);
    Throws<InvalidDataException>(() => catalog.SetThumbnail(entry.Id, oversized));
    if (!OperatingSystem.IsWindows())
    {
        var link = Path.Combine(root, "linked.png");
        File.CreateSymbolicLink(link, png);
        Throws<IOException>(() => catalog.SetThumbnail(entry.Id, link));
    }
    Check(catalog.List().Single() == entry && Directory.GetFiles(Path.Combine(catalog.RootDirectory, "thumbnails")).Length == 0,
        "invalid previews leave no files or metadata");
}

void DamagedThumbnails()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    catalog.SetThumbnail(entry.Id, WritePng(root));
    var owned = catalog.GetThumbnailPath(entry.Id)!;
    MakeWritable(owned);
    var changed = File.ReadAllBytes(owned);
    changed[42] ^= 1;
    File.WriteAllBytes(owned, changed);
    Check(catalog.GetThumbnailPath(entry.Id) is null, "hash mismatch unavailable");
    File.WriteAllText(owned, "malformed PNG");
    Check(catalog.GetThumbnailPath(entry.Id) is null, "malformed owned PNG unavailable");
    File.Delete(owned);
    Check(catalog.GetThumbnailPath(entry.Id) is null, "missing thumbnail unavailable");
    if (!OperatingSystem.IsWindows())
    {
        File.CreateSymbolicLink(owned, WritePng(root));
        Check(catalog.GetThumbnailPath(entry.Id) is null, "linked thumbnail unavailable");
    }
    Check(catalog.List().Count == 1 && File.Exists(catalog.CreateWorkingCopy(entry.Id)), "preview damage does not prevent opening");
}

void MalformedVersionTwo()
{
    var (catalog, source, _) = NewCatalog();
    var entry = catalog.Import(source);
    var good = File.ReadAllText(catalog.CatalogPath);
    Action<JsonNode>[] corruptions =
    [
        doc => doc["templates"]![0]!["categoryId"] = Guid.NewGuid().ToString("D"),
        doc => doc["templates"]![0]!.AsObject().Remove("updatedUtc"),
        doc => doc["templates"]![0]!["updatedUtc"] = DateTimeOffset.MinValue.ToString("O"),
        doc => doc["templates"]![0]!["fileName"] = Guid.NewGuid().ToString("D") + ".rbxlx",
        doc => doc["templates"]![0]!["thumbnailFileName"] = "../../escape.png",
        doc => doc["templates"]![0]!["thumbnailSha256"] = entry.Sha256,
        doc => doc["categories"]!.AsArray().Clear(),
        doc => doc["categories"]!.AsArray().Add(doc["categories"]![0]!.DeepClone()),
        doc => doc.AsObject().Remove("categories"),
        doc => doc["revisions"] = null
    ];
    foreach (var corrupt in corruptions)
    {
        var doc = JsonNode.Parse(good)!;
        corrupt(doc);
        var bytes = doc.ToJsonString();
        File.WriteAllText(catalog.CatalogPath, bytes);
        Throws<CatalogFormatException>(() => catalog.List());
        Check(File.ReadAllText(catalog.CatalogPath) == bytes, "malformed metadata evidence preserved");
    }
}

void UpdateRollback()
{
    if (OperatingSystem.IsWindows() || Environment.UserName == "root") return;
    var (catalog, source, root) = NewCatalog();
    var category = catalog.CreateCategory("Rollback");
    var entry = catalog.Import(source, categoryId: category.Id);
    var png = WritePng(root);
    catalog.SetThumbnail(entry.Id, png);
    entry = catalog.List().Single();
    var replacement = Path.Combine(root, "replacement.rbxlx");
    File.WriteAllText(replacement, "replacement bytes");
    var bytes = File.ReadAllText(catalog.CatalogPath);
    var mode = File.GetUnixFileMode(catalog.RootDirectory);
    File.SetUnixFileMode(catalog.RootDirectory, UnixFileMode.UserRead | UnixFileMode.UserExecute);
    try
    {
        FailsIo(() => catalog.Update(entry.Id, "Changed", category.Id, replacement));
        FailsIo(() => catalog.Update(entry.Id, "Changed", category.Id));
        FailsIo(() => catalog.SetThumbnail(entry.Id, png));
        FailsIo(() => catalog.Remove(entry.Id));
        FailsIo(() => catalog.CreateCategory("Unsaved"));
        FailsIo(() => catalog.RenameCategory(category.Id, "Unsaved"));
        FailsIo(() => catalog.RemoveCategory(category.Id));
        FailsIo(() => catalog.Import(replacement));
    }
    finally { File.SetUnixFileMode(catalog.RootDirectory, mode); }
    Check(File.ReadAllText(catalog.CatalogPath) == bytes && catalog.List().Single() == entry, "all failed mutations preserve catalog");
    Check(File.ReadAllText(catalog.CreateWorkingCopy(entry.Id)) == File.ReadAllText(source), "original snapshot restored after failed replacement/remove");
    Check(Directory.GetFiles(Path.Combine(catalog.RootDirectory, "templates")).Length == 1 &&
        Directory.GetFiles(Path.Combine(catalog.RootDirectory, "archived")).Length == 0 &&
        Directory.GetFiles(Path.Combine(catalog.RootDirectory, "thumbnails")).Length == 1, "no leaked replacement or preview files");
    Check(Directory.GetFiles(catalog.RootDirectory, ".catalog-*.tmp").Length == 0, "no catalog temporary files");
}

void ArchiveCollision()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    var archived = Path.Combine(catalog.RootDirectory, "archived", entry.FileName);
    File.WriteAllText(archived, "retained evidence");
    var replacement = Path.Combine(root, "new.rbxlx");
    File.WriteAllText(replacement, "new bytes");
    var before = File.ReadAllText(catalog.CatalogPath);
    Throws<InvalidDataException>(() => catalog.Update(entry.Id, entry.Name, entry.CategoryId, replacement));
    Check(File.ReadAllText(archived) == "retained evidence" && File.ReadAllText(catalog.CatalogPath) == before, "archive never overwritten");
    Check(Directory.GetFiles(Path.Combine(catalog.RootDirectory, "templates")).Length == 1 &&
        File.ReadAllText(catalog.CreateWorkingCopy(entry.Id)) == File.ReadAllText(source), "new snapshot rolled back");
}

void MigrationRollback()
{
    if (OperatingSystem.IsWindows() || Environment.UserName == "root") return;
    var (catalog, entry, json, _) = LegacyFixture();
    var mode = File.GetUnixFileMode(catalog.RootDirectory);
    File.SetUnixFileMode(catalog.RootDirectory, UnixFileMode.UserRead | UnixFileMode.UserExecute);
    try { FailsIo(() => catalog.List()); }
    finally { File.SetUnixFileMode(catalog.RootDirectory, mode); }
    Check(File.ReadAllText(catalog.CatalogPath) == json, "unbacked migration cannot replace original catalog");
    Check(File.Exists(Path.Combine(catalog.RootDirectory, "templates", entry.FileName)), "snapshot untouched");
    Check(catalog.List().Single().Id == entry.Id, "migration succeeds once storage writable");
}

void StagedArchiveRecovery()
{
    var (catalog, source, root) = NewCatalog();
    var entry = catalog.Import(source);
    var active = Path.Combine(catalog.RootDirectory, "templates", entry.FileName);
    var archived = Path.Combine(catalog.RootDirectory, "archived", entry.FileName);
    File.Copy(active, archived);
    var replacement = Path.Combine(root, "replacement.rbxlx");
    File.WriteAllText(replacement, "replacement bytes");
    var updated = catalog.Update(entry.Id, entry.Name, entry.CategoryId, replacement);
    Check(updated.FileName != entry.FileName && File.ReadAllText(archived) == File.ReadAllText(source),
        "matching staged archive reused without overwriting");
    Check(!File.Exists(active) && File.ReadAllText(catalog.CreateWorkingCopy(entry.Id)) == "replacement bytes",
        "recovered commit retires the previous active file");
    File.Copy(Path.Combine(catalog.RootDirectory, "templates", updated.FileName),
        Path.Combine(catalog.RootDirectory, "archived", updated.FileName));
    Check(catalog.Remove(entry.Id) && catalog.List().Count == 0, "removal also reuses complete staging");
}

static void MakeWritable(string path)
{
    if (OperatingSystem.IsWindows()) File.SetAttributes(path, FileAttributes.Normal);
    else File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
}

static void FailsIo(Action action)
{
    try { action(); }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return; }
    throw new Exception("Expected an I/O failure");
}

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

static T Throws<T>(Action action) where T : Exception
{
    try { action(); }
    catch (T expected) { return expected; }
    throw new Exception("Expected " + typeof(T).Name);
}
