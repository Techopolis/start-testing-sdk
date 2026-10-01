using Microsoft.Extensions.Logging;
using StartTesting.Core;

namespace StartTesting.Auth;

// Feeds the app's ILogger output to the SDK. Categories outside the app's own code,
// such as Microsoft.* and System.*, are recorded for reports but never raise a prompt.
public sealed class StartTestingLoggerProvider(StartTestingClient client, LogLevel minimum = LogLevel.Warning,
    IEnumerable<string>? ownCategories = null) : ILoggerProvider
{
    private readonly string[] own = [.. ownCategories ?? []];
    // With no list given, everything except the runtime's own categories counts as the app's.
    public bool IsOwn(string category) => own.Length > 0
        ? own.Any(prefix => category.StartsWith(prefix, StringComparison.Ordinal))
        : !category.StartsWith("Microsoft.", StringComparison.Ordinal) && !category.StartsWith("System.", StringComparison.Ordinal);
    public ILogger CreateLogger(string categoryName) => new Logger(client, categoryName, minimum, IsOwn(categoryName));
    public void Dispose() { }
    private sealed class Logger(StartTestingClient client, string category, LogLevel minimum, bool own) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => level != LogLevel.None && level >= minimum && (level >= LogLevel.Warning || client.CapturesFullLogs);
        public void Log<TState>(LogLevel level, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(level)) return;
            var type = level switch { LogLevel.Trace or LogLevel.Debug => EventType.Debug, LogLevel.Information => EventType.Info,
                LogLevel.Warning => EventType.Warning, LogLevel.Error => EventType.Error, _ => EventType.Critical };
            try
            {
                string message = formatter(state, exception);
                client.Record(message, type, category, exception is null ? null : new Dictionary<string, string> { ["exception"] = exception.Message, ["stack_trace"] = exception.StackTrace ?? "" });
                if (own && level >= LogLevel.Error) client.NoticeLoggedError(category, message);
            }
            catch (Exception) { /* Do not emit raw failed logging records. */ }
        }
    }
}
