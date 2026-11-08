using System.Runtime.InteropServices;

namespace NativeScreen.App;

/// <summary>
/// Moves a folder to the Recycle Bin without any dialog. A project closed a moment ago can still have a file open (a decoder
/// or a waveform read finishing), so it retries for a few seconds instead of showing an error dialog nobody may be there to
/// answer: an agent's delete_project would wait on it for good (spec/06 ADR-52).
/// </summary>
internal static partial class RecycleBin
{
    private const uint Delete = 0x0003;
    private const ushort AllowUndo = 0x0040;
    private const ushort NoConfirmation = 0x0010;
    private const ushort NoErrorUi = 0x0400;
    private const ushort Silent = 0x0004;

    public static async Task<bool> SendAsync(string path, int timeoutMs = 5000)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (true)
        {
            if (!Directory.Exists(path))
            {
                return true;
            }

            var operation = new FileOperation
            {
                Function = Delete,
                From = Path.GetFullPath(path) + "\0\0",
                Flags = AllowUndo | NoConfirmation | NoErrorUi | Silent
            };
            if (SHFileOperation(ref operation) == 0 && !operation.Aborted && !Directory.Exists(path))
            {
                return true;
            }

            if (Environment.TickCount64 > deadline)
            {
                return false;
            }

            await Task.Delay(250);
        }
    }

    /// <summary>The files in a folder another handle still holds, for the error an agent sees.</summary>
    public static List<string> FilesInUse(string path)
    {
        var busy = new List<string>();
        if (!Directory.Exists(path))
        {
            return busy;
        }

        foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
        {
            try
            {
                using var _ = new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException)
            {
                busy.Add(Path.GetRelativePath(path, file));
            }
            catch (UnauthorizedAccessException)
            {
                busy.Add(Path.GetRelativePath(path, file));
            }
        }

        return busy;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FileOperation
    {
        public nint Window;
        public uint Function;
        [MarshalAs(UnmanagedType.LPWStr)] public string From;
        [MarshalAs(UnmanagedType.LPWStr)] public string? To;
        public ushort Flags;
        [MarshalAs(UnmanagedType.Bool)] public bool Aborted;
        public nint NameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? ProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHFileOperationW")]
    private static extern int SHFileOperation(ref FileOperation operation);
}
