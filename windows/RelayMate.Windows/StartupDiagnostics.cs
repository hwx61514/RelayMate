using System.Runtime.InteropServices;
using System.Text;

namespace RelayMate.Windows;

internal static class StartupDiagnostics
{
    private const uint MbIconError = 0x00000010;
    private const uint MbSetForeground = 0x00010000;
    private static int _installed;
    private static int _fatalReported;

    public static string LogPath
    {
        get
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var root = string.IsNullOrWhiteSpace(localAppData) ? Path.GetTempPath() : localAppData;
            return Path.Combine(root, "RelayMate", "logs", "startup.log");
        }
    }

    public static void Install()
    {
        if (Interlocked.Exchange(ref _installed, 1) != 0)
        {
            return;
        }

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            var exception = args.ExceptionObject as Exception
                ?? new Exception(args.ExceptionObject?.ToString() ?? "Unknown unhandled exception.");
            ReportFatal("AppDomain unhandled exception", exception);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log("Unobserved task exception", args.Exception);
        };

        Log(
            $"Process started. OS={Environment.OSVersion}; " +
            $"Architecture={RuntimeInformation.ProcessArchitecture}; " +
            $"Runtime={RuntimeInformation.FrameworkDescription}; " +
            $"BaseDirectory={AppContext.BaseDirectory}");
    }

    public static void Log(string message, Exception? exception = null)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            var builder = new StringBuilder()
                .Append('[')
                .Append(DateTimeOffset.Now.ToString("O"))
                .Append("] ")
                .AppendLine(message);
            if (exception is not null)
            {
                builder.AppendLine(exception.ToString());
            }
            File.AppendAllText(LogPath, builder.ToString(), Encoding.UTF8);
        }
        catch
        {
            // Diagnostics must never hide the original startup failure.
        }
    }

    public static void ReportFatal(string stage, Exception exception)
    {
        Log(stage, exception);
        if (Interlocked.Exchange(ref _fatalReported, 1) != 0)
        {
            return;
        }

        var message =
            $"RelayMate 无法启动。\n\n阶段：{stage}\n错误：{exception.Message}\n\n" +
            $"详细日志：\n{LogPath}";
        try
        {
            _ = MessageBox(IntPtr.Zero, message, "RelayMate 启动失败", MbIconError | MbSetForeground);
        }
        catch
        {
            // AppDomain logging above is still available if user32 cannot show a dialog.
        }
    }

    [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr windowHandle, string text, string caption, uint type);
}
