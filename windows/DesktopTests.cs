using System.Text.Json;

namespace SapiensDesktop;

internal static class DesktopTests
{
    internal static void Run(string? report)
    {
        int tests = 0;
        try
        {
            var origin = new Uri("http://127.0.0.1:4174");
            void Check(bool value) { if (!value) throw new Exception($"Navigation test {tests + 1} failed"); tests++; }
            Check(Navigation.Trusted("http://127.0.0.1:4174/workspace/", origin));
            foreach (string url in new[] { "http://127.0.0.1:4175/workspace/", "http://localhost:4174/workspace/", "http://127.0.0.1:4174/other", "https://example.com/workspace/", "file:///C:/workspace/", "http://user@127.0.0.1:4174/workspace/" }) Check(!Navigation.Trusted(url, origin));
            foreach (string url in new[] { "https://example.com", "http://example.com", "file:///C:/test%20file.html", "about:blank" }) Check(Navigation.Guest(url, origin));
            foreach (string url in new[] { "javascript:alert(1)", "shell:AppsFolder", "file://server/share/test", "https://user:pass@example.com", "http://127.0.0.1:4174/workspace/", "http://localhost:4174/workspace/", "http://[::1]:4174/workspace/" }) Check(!Navigation.Guest(url, origin));
            if (report != null) File.WriteAllText(report, JsonSerializer.Serialize(new { ok = true, tests }));
            Environment.ExitCode = 0;
        }
        catch (Exception error) { if (report != null) File.WriteAllText(report, JsonSerializer.Serialize(new { ok = false, tests, error = error.Message })); Environment.ExitCode = 1; }
    }
}
