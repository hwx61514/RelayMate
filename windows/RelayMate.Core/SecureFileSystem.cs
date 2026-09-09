using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;

namespace RelayMate.Core;

public sealed record FileSnapshot(
    string Path,
    bool Existed,
    byte[]? Contents,
    string? WindowsSecurityDescriptor);

public static class SecureFileSystem
{
    // Preserve only the DACL. Restoring a SACL requires SeSecurityPrivilege, while
    // restoring owner/group can require WRITE_OWNER in a normal desktop process.

    public static FileSnapshot Snapshot(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return new FileSnapshot(path, false, null, null);
            }

            return new FileSnapshot(
                path,
                true,
                File.ReadAllBytes(path),
                GetSecurityDescriptor(path));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw RelayMateException.File(exception.Message);
        }
    }

    public static void Restore(FileSnapshot snapshot)
    {
        if (!snapshot.Existed)
        {
            if (File.Exists(snapshot.Path))
            {
                File.Delete(snapshot.Path);
            }
            return;
        }

        Write(snapshot.Contents ?? [], snapshot.Path);
        RestoreSecurityDescriptor(snapshot.Path, snapshot.WindowsSecurityDescriptor);
    }

    public static void Write(byte[] data, string path)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw RelayMateException.File($"无法确定 {path} 的父目录。");
        var directoryExisted = Directory.Exists(directory);
        Directory.CreateDirectory(directory);
        if (!directoryExisted)
        {
            ApplyPrivateDirectoryAcl(directory);
        }

        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temporary, data);
            ApplyPrivateFileAcl(temporary);
            if (File.Exists(path))
            {
                File.Replace(temporary, path, null, true);
            }
            else
            {
                File.Move(temporary, path);
            }
            ApplyPrivateFileAcl(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw RelayMateException.File(exception.Message);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    public static string Hash(string path)
    {
        var snapshot = Snapshot(path);
        using var sha256 = SHA256.Create();
        var marker = snapshot.Existed ? new byte[] { 1 } : new byte[] { 0 };
        sha256.TransformBlock(marker, 0, marker.Length, null, 0);
        var contents = snapshot.Contents ?? [];
        sha256.TransformFinalBlock(contents, 0, contents.Length);
        return Convert.ToHexStringLower(sha256.Hash ?? []);
    }

    private static string? GetSecurityDescriptor(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        try
        {
            var security = FileSystemAclExtensions.GetAccessControl(new FileInfo(path));
            return security.GetSecurityDescriptorSddlForm(AccessControlSections.Access);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            return null;
        }
    }

    private static void RestoreSecurityDescriptor(string path, string? descriptor)
    {
        if (!OperatingSystem.IsWindows() || string.IsNullOrWhiteSpace(descriptor))
        {
            return;
        }

        var security = new FileSecurity();
        security.SetSecurityDescriptorSddlForm(descriptor, AccessControlSections.Access);
        FileSystemAclExtensions.SetAccessControl(new FileInfo(path), security);
    }

    private static void ApplyPrivateFileAcl(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var identity = WindowsIdentity.GetCurrent().User;
        if (identity is null)
        {
            return;
        }

        var security = new FileSecurity();
        security.SetOwner(identity);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(identity, FileSystemRights.FullControl, AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(new FileInfo(path), security);
    }

    private static void ApplyPrivateDirectoryAcl(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var identity = WindowsIdentity.GetCurrent().User;
        if (identity is null)
        {
            return;
        }

        var security = new DirectorySecurity();
        security.SetOwner(identity);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(new DirectoryInfo(path), security);
    }
}
