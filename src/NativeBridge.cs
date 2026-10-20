using System.Runtime.InteropServices;
using System.Text;

namespace CustomTemplates;

/// <summary>Thin managed bridge to the adjacent macOS helper library.</summary>
internal sealed class NativeBridge : IDisposable
{
    private const string LibraryName = "libCustomTemplatesUI.dylib";
    private const int InitialCommandCapacity = 4096;
    private const int MaximumCommandCapacity = 4 * 1024 * 1024;

    private readonly IntPtr _library;
    private readonly StartFunction _start;
    private readonly StopFunction _stop;
    private readonly PollCommandFunction _pollCommand;
    private readonly PublishCatalogFunction _publishCatalog;
    private readonly OpenFileFunction _openFile;
    private readonly PublishCatalogFunction _openTemplate;
    private readonly PublishCatalogFunction _showDialog;
    private readonly PublishCatalogFunction _requestThumbnail;
    private readonly StopFunction _cancelCapture;
    private readonly PublishCatalogFunction _snapshotCurrent;
    private readonly PublishCatalogFunction _showNotice;
    private bool _started;
    private bool _disposed;

    public NativeBridge()
    {
        var assemblyPath = typeof(NativeBridge).Assembly.Location;
        var assemblyDirectory = Path.GetDirectoryName(assemblyPath);
        if (string.IsNullOrEmpty(assemblyDirectory))
            throw new InvalidOperationException("Could not locate the CustomTemplates assembly directory.");

        var nativePath = Path.Combine(assemblyDirectory, LibraryName);
        if (!File.Exists(nativePath))
            throw new FileNotFoundException(
                $"The native bridge must be installed beside CustomTemplates.dll: {nativePath}", nativePath);

        // The native vtable hook stays installed and forwards after Stop. Keep its
        // code image resident for the Studio process lifetime.
        _library = NativeLibrary.Load(nativePath);
        _start = GetExport<StartFunction>(_library, "ctpl_start");
        _stop = GetExport<StopFunction>(_library, "ctpl_stop");
        _pollCommand = GetExport<PollCommandFunction>(_library, "ctpl_poll_command");
        _publishCatalog = GetExport<PublishCatalogFunction>(_library, "ctpl_publish_catalog");
        _openFile = GetExport<OpenFileFunction>(_library, "ctpl_open_file");
        _openTemplate = GetExport<PublishCatalogFunction>(_library, "ctpl_open_template");
        _showDialog = GetExport<PublishCatalogFunction>(_library, "ctpl_show_dialog");
        _requestThumbnail = GetExport<PublishCatalogFunction>(_library, "ctpl_capture_thumbnail");
        _cancelCapture = GetExport<StopFunction>(_library, "ctpl_cancel_capture");
        _snapshotCurrent = GetExport<PublishCatalogFunction>(_library, "ctpl_snapshot_current");
        _showNotice = GetExport<PublishCatalogFunction>(_library, "ctpl_show_notice");
    }

    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_started)
            return;
        if (!_start())
            throw new InvalidOperationException("The native Templates UI could not start for this Studio session.");
        _started = true;
    }

    public bool TryPollCommand(out string command)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        var capacity = InitialCommandCapacity;
        var buffer = Marshal.AllocHGlobal(capacity);
        try
        {
            var length = _pollCommand(buffer, capacity);
            if (length == 0)
            {
                command = string.Empty;
                return false;
            }

            if (length < 0)
            {
                var required = -(long)length;
                if (required <= capacity || required > MaximumCommandCapacity)
                    throw new InvalidDataException("The native template command exceeds the supported size.");

                // A negative result reports the complete buffer size including NUL.
                var requiredCapacity = checked((int)required);
                var replacement = Marshal.AllocHGlobal(requiredCapacity);
                Marshal.FreeHGlobal(buffer);
                buffer = replacement;
                capacity = requiredCapacity;
                length = _pollCommand(buffer, capacity);
                if (length <= 0)
                {
                    command = string.Empty;
                    if (length == 0)
                        return false;
                    throw new InvalidDataException("The native template command changed while being read.");
                }
            }

            if (length >= capacity)
                throw new InvalidDataException("The native template command length is invalid.");

            var bytes = new byte[length];
            Marshal.Copy(buffer, bytes, 0, length);
            command = Encoding.UTF8.GetString(bytes);
            return true;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public bool PublishCatalog(string json)
        => SendJson(json, _publishCatalog);

    public bool ShowDialog(string json) => SendJson(json, _showDialog);
    public bool OpenTemplate(string json) => SendJson(json, _openTemplate);
    public bool RequestThumbnail(string json) => SendJson(json, _requestThumbnail);
    public bool SnapshotCurrentPlace(string json) => SendJson(json, _snapshotCurrent);
    public void ShowNotice(string message) => SendJson(System.Text.Json.JsonSerializer.Serialize(new { message }), _showNotice);
    public void ShowStatus(string message) => SendJson(System.Text.Json.JsonSerializer.Serialize(new { message, quiet = true }), _showNotice);
    public void CancelCapture()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _cancelCapture();
    }

    private bool SendJson(string json, PublishCatalogFunction function)
    {
        ArgumentNullException.ThrowIfNull(json);
        ObjectDisposedException.ThrowIf(_disposed, this);

        var utf8Json = Marshal.StringToCoTaskMemUTF8(json);
        try
        {
            return function(utf8Json);
        }
        finally
        {
            Marshal.FreeCoTaskMem(utf8Json);
        }
    }

    public bool OpenWorkingCopy(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ObjectDisposedException.ThrowIf(_disposed, this);

        var extension = Path.GetExtension(path);
        if (!extension.Equals(".rbxl", StringComparison.OrdinalIgnoreCase) &&
            !extension.Equals(".rbxlx", StringComparison.OrdinalIgnoreCase))
            return false;

        var absolutePath = Path.GetFullPath(path);
        if (!File.Exists(absolutePath))
            return false;

        var utf8Path = Marshal.StringToCoTaskMemUTF8(absolutePath);
        try
        {
            return _openFile(utf8Path);
        }
        finally
        {
            Marshal.FreeCoTaskMem(utf8Path);
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;
        _started = false;
        // Stop is safe when Start did not complete and releases native UI/picker
        // state. Do not unload the library: its forwarding hook is process-resident.
        _stop();
    }

    private static T GetExport<T>(IntPtr library, string name) where T : Delegate
    {
        var address = NativeLibrary.GetExport(library, name);
        return Marshal.GetDelegateForFunctionPointer<T>(address);
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private delegate bool StartFunction();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void StopFunction();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int PollCommandFunction(IntPtr buffer, int capacity);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private delegate bool PublishCatalogFunction(IntPtr utf8Json);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private delegate bool OpenFileFunction(IntPtr utf8Path);
}
