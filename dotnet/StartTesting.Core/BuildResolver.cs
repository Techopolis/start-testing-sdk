using System.Runtime.InteropServices;
using System.Text.Json;

namespace StartTesting.Core;

public static class BuildResolver
{
    public static BuildInfo Resolve(AppEnvironment environment = AppEnvironment.Auto,
        Distribution distribution = Distribution.Unknown, string? metadataPath = null,
        Func<string, string?>? environmentVariable = null)
    {
        environmentVariable ??= System.Environment.GetEnvironmentVariable;
        Dictionary<string, string> metadata = [];
        if (metadataPath is not null)
        {
            if (new FileInfo(metadataPath).Length > 16384) throw new ArgumentException("Metadata too large");
            metadata = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllBytes(metadataPath))
                ?? throw new ArgumentException("Metadata must be an object");
        }
        string Value(string name, string fallback = "unknown") =>
            environmentVariable("START_TESTING_" + name.ToUpperInvariant())
            ?? metadata.GetValueOrDefault(name, fallback);
        T Parse<T>(string value) where T : struct, Enum => JsonSerializer.Deserialize<T>(
            JsonSerializer.Serialize(value), Wire.Options);
        if (distribution == Distribution.Unknown) distribution = Parse<Distribution>(Value("distribution"));
        if (environment == AppEnvironment.Auto)
        {
            environment = Parse<AppEnvironment>(Value("environment"));
            if (environment is AppEnvironment.Auto or AppEnvironment.Unknown)
                environment = distribution switch
                {
                    Distribution.Testflight or Distribution.GithubPrerelease or Distribution.MsixFlight => AppEnvironment.Beta,
                    Distribution.GithubRelease or Distribution.AppStore or Distribution.MicrosoftStore => AppEnvironment.Production,
                    Distribution.Debug or Distribution.Xcode => AppEnvironment.Development,
                    _ => AppEnvironment.Unknown
                };
        }
        return new(environment, distribution, Value("version"), Value("build"), Value("commit", ""),
            RuntimeInformation.OSDescription, System.Environment.OSVersion.VersionString,
            RuntimeInformation.OSArchitecture.ToString());
    }
}
