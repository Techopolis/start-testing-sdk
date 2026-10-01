using Microsoft.Extensions.Logging;
using StartTesting.Core;

namespace StartTesting.Auth;

public sealed class StartTestingLoggerProvider(StartTestingClient client, LogLevel minimum = LogLevel.Warning) : ILoggerProvider
{
    public ILogger CreateLogger(string categoryName) => new Logger(client, categoryName, minimum);
    public void Dispose() { }
    private sealed class Logger(StartTestingClient client, string category, LogLevel minimum) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => level != LogLevel.None && level >= minimum && (level >= LogLevel.Warning || client.FullLogsEnabled);
        public void Log<TState>(LogLevel level, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(level)) return;
            var type = level switch { LogLevel.Trace or LogLevel.Debug => EventType.Debug, LogLevel.Information => EventType.Info,
                LogLevel.Warning => EventType.Warning, LogLevel.Error => EventType.Error, _ => EventType.Critical };
            try { client.Record(formatter(state, exception), type, category, exception is null ? null : new Dictionary<string, string> { ["exception"] = exception.Message, ["stack_trace"] = exception.StackTrace ?? "" }); }
            catch (Exception) { /* Do not emit raw failed logging records. */ }
        }
    }
}
