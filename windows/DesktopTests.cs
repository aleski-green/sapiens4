using System.Text.Json;
using Microsoft.Web.WebView2.WinForms;

namespace SapiensDesktop;

internal static class DesktopTests
{
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

    static bool TitleBarMatches(WebView2 shell, bool dark)
    {
        IntPtr window = shell.FindForm()!.Handle;
        int result = DwmGetWindowAttribute(window, 20, out int enabled, sizeof(int));
        if (result < 0) result = DwmGetWindowAttribute(window, 19, out enabled, sizeof(int));
        // Caption/text color attributes are write-only; inspect the native mode here.
        if (result < 0 || enabled != (dark ? 1 : 0)) return false;
        using var icon = shell.FindForm()!.Icon?.ToBitmap();
        return icon != null && icon.GetPixel(icon.Width / 2, icon.Height / 16).ToArgb() ==
            (dark ? Color.FromArgb(23, 23, 23) : Color.White).ToArgb();
    }

    internal static async Task CheckGroupWorkspace(Browser browser, WebView2 shell, Host host, string main)
    {
        using var client = new HttpClient { BaseAddress = host.Origin };
        client.DefaultRequestHeaders.Add("X-Sapiens-Local", "1");
        async Task<JsonElement> Post(string route, object data)
        {
            using var response = await client.PostAsync(route, new StringContent(JsonSerializer.Serialize(data), System.Text.Encoding.UTF8, "application/json"));
            response.EnsureSuccessStatusCode();
            return JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
        }
        var member = await Post("/api/agents", new { name = "BrowserTest", role = "Local test fixture" });
        var group = await Post("/api/groups", new { name = "Browser smoke", lead = main, members = new[] { main, member.GetProperty("id").GetString()! } });
        string owner = group.GetProperty("id").GetString()!;
        string file = Path.Combine(host.DataDirectory, "workspaces", owner, "group مرحبا #1.html");
        File.WriteAllText(file, "<!doctype html><title>Group browser smoke</title><h1>Shared local document</h1>");
        await shell.CoreWebView2.ExecuteScriptAsync($"window.sapiensBrowserEvent({JsonSerializer.Serialize(new { owner, file })})");
        for (int attempt = 0; attempt < 100; attempt++)
        {
            var state = JsonDocument.Parse(await client.GetStringAsync("/api/state")).RootElement;
            var workspaces = state.GetProperty("preferences").GetProperty("workspaces");
            if (workspaces.TryGetProperty(owner, out var workspace) && browser.HasGuestTitle("Group browser smoke") &&
                workspace.GetProperty("tabs").EnumerateArray().Any(tab => tab.GetProperty("title").GetString() == "Group browser smoke"))
            {
                if (state.GetProperty("turns").GetArrayLength() != 0) throw new Exception("Browser fixture unexpectedly dispatched model work");
                return;
            }
            await Task.Delay(100);
        }
        throw new Exception("Group browser navigation was not rendered and persisted through the native bridge");
    }

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
        foreach (string url in new[] { "about:blank", new Uri(textFile).AbsoluteUri, new Uri(htmlFile).AbsoluteUri, original })
        {
            view.CoreWebView2.Navigate(url);
            await WaitFor(async () => await view.CoreWebView2.ExecuteScriptAsync($"location.href==={JsonSerializer.Serialize(url)} && document.readyState==='complete'") == "true", "Theme test navigation did not complete");
            foreach (bool dark in new[] { true, false, true })
            {
                string mode = dark ? "dark" : "light";
                await shell.CoreWebView2.ExecuteScriptAsync($"if(document.documentElement.dataset.theme!=={JsonSerializer.Serialize(mode)})document.querySelector('[data-theme-toggle]').click()");
                bool html = url.EndsWith(".html");
                string color = url == original ? "rgba(0, 0, 0, 0)" : html ? "rgb(18, 52, 86)" : dark ? "rgb(33, 33, 33)" : "rgb(255, 255, 255)";
                string ink = url == original ? "rgb(0, 0, 0)" : html ? "rgb(171, 205, 239)" : dark ? "rgb(236, 236, 236)" : "rgb(32, 32, 32)";
                await WaitFor(async () =>
                    TitleBarMatches(shell, dark) &&
                    view.DefaultBackgroundColor.ToArgb() == (dark && !html ? Color.FromArgb(33, 33, 33) : Color.White).ToArgb() &&
                    await view.CoreWebView2.ExecuteScriptAsync($"matchMedia('(prefers-color-scheme: dark)').matches==={dark.ToString().ToLowerInvariant()} && getComputedStyle(document.body).backgroundColor==={JsonSerializer.Serialize(color)} && getComputedStyle(document.body).color==={JsonSerializer.Serialize(ink)}") == "true",
                    $"Browser or native title bar theme mismatch: {url}, {mode}");
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
