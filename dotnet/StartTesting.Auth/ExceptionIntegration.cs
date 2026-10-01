using StartTesting.Core;

namespace StartTesting.Auth;

public sealed class ExceptionIntegration : IDisposable
{
    private readonly UnhandledExceptionEventHandler unhandled;
    private readonly EventHandler<UnobservedTaskExceptionEventArgs> task;
    public ExceptionIntegration(StartTestingClient client)
    {
        unhandled = (_, args) => {
            try { if (args.ExceptionObject is Exception error) client.RecordError(error, args.IsTerminating ? ErrorSeverity.Fatal : ErrorSeverity.Reportable); }
            catch (Exception) { }
        };
        task = (_, args) => { try { client.RecordError(args.Exception, ErrorSeverity.Reportable); } catch (Exception) { } };
        AppDomain.CurrentDomain.UnhandledException += unhandled;
        TaskScheduler.UnobservedTaskException += task;
    }
    public void Dispose()
    {
        AppDomain.CurrentDomain.UnhandledException -= unhandled;
        TaskScheduler.UnobservedTaskException -= task;
    }
}
