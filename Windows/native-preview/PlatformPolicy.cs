using System.Text.Json;

namespace Braintrust.NativePreview;

public sealed record PlatformDefinition(string Id, string Name, string Origin, string[] NavigationHosts)
{
    public string ProfileName => $"platform-{Id}-v1";
}

public static class PlatformPolicy
{
    public static IReadOnlyList<PlatformDefinition> Load(string path)
    {
        var platforms = JsonSerializer.Deserialize<PlatformDefinition[]>(File.ReadAllText(path),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
        if (platforms.Length != 3 || platforms.Select(p => p.Id).Distinct().Count() != 3)
            throw new InvalidDataException("The preview requires exactly three distinct platforms.");
        foreach (var platform in platforms)
        {
            if (string.IsNullOrEmpty(platform.Id) || platform.Id.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-'))
                throw new InvalidDataException("Invalid stable profile id.");
            if (platform.NavigationHosts is null || !IsAllowed(platform, platform.Origin))
                throw new InvalidDataException("Platform home must be an allowed HTTPS origin.");
        }
        return platforms;
    }

    // Exact host comparison: subdomains, lookalikes, credentials and nonstandard ports are not implicitly trusted.
    public static bool IsAllowed(PlatformDefinition platform, string? target) =>
        TryHttps(target, out var uri) && platform.NavigationHosts.Contains(uri!.IdnHost, StringComparer.OrdinalIgnoreCase);

    public static bool TryHttps(string? target, out Uri? uri)
    {
        if (Uri.TryCreate(target, UriKind.Absolute, out uri) && uri.Scheme == Uri.UriSchemeHttps &&
            uri.IsDefaultPort && string.IsNullOrEmpty(uri.UserInfo) && uri.HostNameType == UriHostNameType.Dns)
            return true;
        uri = null;
        return false;
    }

    // Neither UI diagnostics nor logs retain token-bearing paths, query strings or fragments.
    public static string DisplayOrigin(string? target) =>
        TryHttps(target, out var uri) ? uri!.GetLeftPart(UriPartial.Authority) : "非 HTTPS 或无效地址";
}
