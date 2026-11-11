using System.Runtime.InteropServices;

namespace NativeScreen.Media;

/// <summary>
/// Free space for recordings (spec/06 ADR-83): a recording does not start with less than 2 GB free on the projects volume,
/// and stops by itself under 500 MB. The free space is what this user may still write (quotas included).
/// </summary>
public static partial class DiskSpace
{
    public const long MinimumToStart = 2_000_000_000;

    public const long MinimumToKeepRecording = 500_000_000;

    /// <summary>
    /// Bytes this user can still write on the volume holding <paramref name="path"/>, from the nearest folder that exists. Null
    /// when it cannot be read (a network share may not say), so the caller lets the recording go on.
    /// </summary>
    public static long? FreeBytes(string path)
    {
        try
        {
            var folder = Path.GetFullPath(path);
            while (!Directory.Exists(folder))
            {
                var parent = Path.GetDirectoryName(folder);
                if (string.IsNullOrEmpty(parent) || parent == folder)
                {
                    return null;
                }

                folder = parent;
            }

            // Not DriveInfo: this also works for a share and for a folder mounted onto another volume.
            return GetDiskFreeSpaceExW(folder.EndsWith('\\') ? folder : folder + "\\", out var available, out _, out _) ? (long)available : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetDiskFreeSpaceExW(string directory, out ulong freeBytesAvailable, out ulong totalBytes, out ulong totalFreeBytes);
}
