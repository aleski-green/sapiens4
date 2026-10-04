using System.Text.Json;
using Microsoft.Web.WebView2.WinForms;

namespace SapiensDesktop;

internal static class DesktopTests
{
    internal static async Task<int> CheckThemes(Browser browser, WebView2 shell, string dataDirectory)
    {
        // Run only in an isolated --smoke-report workspace. Exercise the real shell toggle,
        // bridge, native profile and rendered document without reloading between themes.
        var view = browser.Views.First();
        int checks = 0;
        string original = view.CoreWebView2.Source;
        string textFile = Path.Combine(dataDirectory, "theme-smoke.txt");
        string htmlFile = Path.Combine(dataDirectory, "theme-smoke.html");
        File.WriteAllText(textFile, "Theme smoke: Unicode مرحبا");
        File.WriteAllText(htmlFile, "<!doctype html><title>Authored theme</title><style>body{background:#123456;color:#abcdef}</style><h1>Authored theme</h1>");
        async Task WaitFor(Func<Task<bool>> predicate, string error)
        {
            for (int attempt = 0; attempt < 100; attempt++) { if (await predicate()) return; await Task.Delay(100); }
            throw new Exception(error);
        }
        foreach (string url in new[] { "about:blank", new Uri(textFile).AbsoluteUri, new Uri(htmlFile).AbsoluteUri })
        {
            view.CoreWebView2.Navigate(url);
            await WaitFor(async () => await view.CoreWebView2.ExecuteScriptAsync($"location.href==={JsonSerializer.Serialize(url)} && document.readyState==='complete'") == "true", "Theme test navigation did not complete");
            foreach (bool dark in new[] { true, false, true })
            {
                string mode = dark ? "dark" : "light";
                await shell.CoreWebView2.ExecuteScriptAsync($"if(document.documentElement.dataset.theme!=={JsonSerializer.Serialize(mode)})document.querySelector('[data-theme-toggle]').click()");
                string color = url.EndsWith(".html") ? "rgb(18, 52, 86)" : dark ? "rgb(33, 33, 33)" : "rgb(255, 255, 255)";
                string ink = url.EndsWith(".html") ? "rgb(171, 205, 239)" : dark ? "rgb(236, 236, 236)" : "rgb(32, 32, 32)";
                await WaitFor(async () =>
                    browser.Views.All(v => v.DefaultBackgroundColor.ToArgb() == (dark ? Color.FromArgb(33, 33, 33) : Color.White).ToArgb()) &&
                    await view.CoreWebView2.ExecuteScriptAsync($"matchMedia('(prefers-color-scheme: dark)').matches==={dark.ToString().ToLowerInvariant()} && getComputedStyle(document.body).backgroundColor==={JsonSerializer.Serialize(color)} && getComputedStyle(document.body).color==={JsonSerializer.Serialize(ink)}") == "true",
                    $"Browser theme mismatch: {url}, {mode}");
                if (view.CoreWebView2.Settings.IsWebMessageEnabled || view.CoreWebView2.Settings.AreHostObjectsAllowed) throw new Exception("Guest bridge isolation changed");
                checks++;
            }
        }
        view.CoreWebView2.Navigate(original);
        return checks;
    }

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
