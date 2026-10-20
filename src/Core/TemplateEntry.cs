using System.Text.Json.Serialization;

namespace CustomTemplates.Core;

/// <summary>A catalog association. FileName is relative to the owned templates folder.</summary>
public sealed record TemplateEntry(string Id, string Name, DateTimeOffset CreatedUtc, string FileName, string Sha256,
    [property: JsonRequired] string CategoryId = TemplateCatalog.DefaultCategoryId,
    [property: JsonRequired] DateTimeOffset UpdatedUtc = default,
    string? ThumbnailFileName = null, string? ThumbnailSha256 = null);

public sealed record TemplateCategory(string Id, string Name);

public sealed class CatalogFormatException(string message, Exception? inner = null) : IOException(message, inner);

public sealed class DuplicateTemplateException(TemplateEntry existing)
    : InvalidOperationException($"This place is already imported as '{existing.Name}'.")
{
    public TemplateEntry Existing { get; } = existing;
}
