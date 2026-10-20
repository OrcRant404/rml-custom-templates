namespace CustomTemplates.Core;

/// <summary>Process-local links between open documents and owned templates.</summary>
public sealed class TemplateDocumentLinks
{
    private readonly Dictionary<string, string> _documents = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _workingCopies = new(StringComparer.Ordinal);

    public void RememberWorkingCopy(string path, string templateId)
    {
        ValidateId(templateId);
        _workingCopies[NormalizePath(path) ?? throw new ArgumentException("A working copy needs an absolute path.")] = templateId;
    }

    public void Bind(string documentId, string templateId)
    {
        if (string.IsNullOrWhiteSpace(documentId)) throw new ArgumentException("A document identity is required.");
        ValidateId(templateId);
        _documents[documentId] = templateId;
    }

    public TemplateEntry? Resolve(string documentId, string? path, IReadOnlyList<TemplateEntry> ownedTemplates)
    {
        if (string.IsNullOrWhiteSpace(documentId)) return null;
        if (_documents.TryGetValue(documentId, out var id))
            return ownedTemplates.SingleOrDefault(entry => entry.Id == id);
        var normalized = NormalizePath(path);
        if (normalized is null || !_workingCopies.TryGetValue(normalized, out id)) return null;
        var entry = ownedTemplates.SingleOrDefault(entry => entry.Id == id);
        if (entry is not null) _documents[documentId] = entry.Id;
        return entry;
    }

    private static string? NormalizePath(string? path) => !string.IsNullOrWhiteSpace(path) && Path.IsPathFullyQualified(path)
        ? Path.GetFullPath(path) : null;

    private static void ValidateId(string id)
    {
        if (!Guid.TryParseExact(id, "D", out _)) throw new ArgumentException("A valid template ID is required.");
    }
}
