namespace SapiensDesktop;

internal static class Navigation
{
    internal static bool Trusted(string value, Uri? origin) => origin != null && Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == origin.Scheme && uri.Host == origin.Host && uri.Port == origin.Port && uri.UserInfo.Length == 0 &&
        (uri.AbsolutePath == "/workspace/" || uri.AbsolutePath == "/workspace");
    internal static bool Guest(string value, Uri? origin)
    {
        if (value == "about:blank") return true;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.UserInfo.Length > 0) return false;
        if (uri.IsFile) return uri.IsLoopback;
        if (uri.Scheme is not ("http" or "https")) return false;
        return origin == null || uri.Port != origin.Port || !uri.IsLoopback;
    }
}
