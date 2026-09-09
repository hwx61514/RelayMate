using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace RelayMate.Windows;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        StartupDiagnostics.Install();
        StartupDiagnostics.Log("Custom WinUI entry point started.");

        try
        {
            // Windows App SDK single-file SxS activation reads this variable before
            // loading WinUI native components from the extracted bundle directory.
            Environment.SetEnvironmentVariable(
                "MICROSOFT_WINDOWSAPPRUNTIME_BASE_DIRECTORY",
                AppContext.BaseDirectory,
                EnvironmentVariableTarget.Process);

            StartupDiagnostics.Log("Initializing C#/WinRT wrappers.");
            WinRT.ComWrappersSupport.InitializeComWrappers();

            StartupDiagnostics.Log("Starting WinUI dispatcher.");
            Application.Start(_ =>
            {
                var dispatcherQueue = DispatcherQueue.GetForCurrentThread();
                var synchronizationContext = new DispatcherQueueSynchronizationContext(dispatcherQueue);
                SynchronizationContext.SetSynchronizationContext(synchronizationContext);
                new App();
            });
            StartupDiagnostics.Log("WinUI dispatcher exited normally.");
        }
        catch (Exception exception)
        {
            StartupDiagnostics.ReportFatal("WinUI program entry point", exception);
            throw;
        }
    }
}
