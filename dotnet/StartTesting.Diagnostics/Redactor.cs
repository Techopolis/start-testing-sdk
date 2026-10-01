using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace StartTesting.Diagnostics;

public sealed class Redactor
{
    private readonly object gate = new();
    private readonly HashSet<string> keys = ["password", "passwd", "secret", "token", "apikey",
        "authorization", "cookie", "requestbody", "responsebody"];
    private readonly HashSet<string> values = [];
    private readonly List<Regex> patterns = [];
    private readonly List<Func<string, string>> custom = [];
    public ImmutableHashSet<string> SuppressedCategories { get; init; } = [];
    public ImmutableHashSet<string>? AllowedFields { get; init; }
    public ImmutableHashSet<string> DeniedFields { get; init; } = [];
    private static readonly TimeSpan Timeout = TimeSpan.FromMilliseconds(50);
    private static string Normalize(string key) => Regex.Replace(key.ToLowerInvariant(), "[^a-z0-9]", "", RegexOptions.None, Timeout);
    public void RegisterSensitiveKey(string key) { lock (gate) keys.Add(Normalize(key)); }
    public void RegisterSensitiveValue(string value)
    {
        ArgumentException.ThrowIfNullOrEmpty(value);
        lock (gate) values.Add(value);
    }
    public void RegisterPattern(string pattern) { lock (gate) patterns.Add(new(pattern, RegexOptions.None, Timeout)); }
    public void RegisterRedactor(Func<string, string> callback) { lock (gate) custom.Add(callback); }
    public string Text(string text)
    {
        lock (gate)
        {
            try
            {
                foreach (var redact in custom) text = redact(text);
                foreach (var value in values.OrderByDescending(v => v.Length)) text = text.Replace(value, "[REDACTED]");
                foreach (var pattern in patterns) text = pattern.Replace(text, "[REDACTED]");
                text = Regex.Replace(text, @"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+", "[REDACTED]", RegexOptions.None, Timeout);
                text = Regex.Replace(text, @"\bsk-[A-Za-z0-9_-]{8,}\b", "[REDACTED]", RegexOptions.None, Timeout);
                text = Regex.Replace(text, @"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", "[REDACTED]", RegexOptions.None, Timeout);
                var names = string.Join("|", keys.Select(k => string.Join("[-_ ]*", k.Select(c => Regex.Escape(c.ToString())))));
                text = Regex.Replace(text, "(?i)[\"']?\\b(?:" + names + ")[\"']?\\s*[:=]\\s*(?:\"[^\"\\n]*\"|'[^'\\n]*'|[^\\s,;&}]+)",
                    "[REDACTED]", RegexOptions.None, Timeout);
                return text.Length > 8192 ? text[..8192] : text;
            }
            catch (Exception) { return "[REDACTED]"; }
        }
    }
    public ImmutableDictionary<string, string> Fields(IReadOnlyDictionary<string, string>? source)
    {
        var result = ImmutableDictionary.CreateBuilder<string, string>();
        lock (gate)
        {
            foreach (var (key, value) in (source ?? ImmutableDictionary<string, string>.Empty).Take(64))
            {
                if (DeniedFields.Contains(key) || (AllowedFields is not null && !AllowedFields.Contains(key))) continue;
                result[Text(key)] = keys.Any(k => Normalize(key).Contains(k, StringComparison.Ordinal)) ? "[REDACTED]" : Text(value);
            }
        }
        return result.ToImmutable();
    }
}
