using System.Text.Json;
using Microsoft.Web.WebView2.WinForms;

namespace SapiensDesktop;

// Native browser actions and observations. All expectations live in RSpec.
internal static class DesktopProbe
{
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

    static object Caption(WebView2 shell)
    {
        IntPtr window = shell.FindForm()!.Handle;
        int result = DwmGetWindowAttribute(window, 20, out int enabled, sizeof(int));
        if (result < 0) result = DwmGetWindowAttribute(window, 19, out enabled, sizeof(int));
        using var icon = shell.FindForm()!.Icon?.ToBitmap();
        return new { result, enabled, icon = icon?.GetPixel(icon.Width / 2, icon.Height / 16).ToArgb() };
    }

    static async Task WaitFor(Func<Task<bool>> predicate, string operation)
    {
        for (int attempt = 0; attempt < 100; attempt++) { if (await predicate()) return; await Task.Delay(100); }
        throw new TimeoutException(operation);
    }

    internal static async Task<object> GroupWorkspace(Browser browser, WebView2 shell, Host host, string main)
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
        await shell.CoreWebView2.ExecuteScriptAsync("document.querySelector('[data-scope=groups]').click()");
        string selector = JsonSerializer.Serialize($".agent-row[data-agent='{owner}']");
        await WaitFor(async () => await shell.CoreWebView2.ExecuteScriptAsync($"!!document.querySelector({selector})") == "true", "Group list did not settle");
        await shell.CoreWebView2.ExecuteScriptAsync($"document.querySelector({selector}).click()");
        await shell.CoreWebView2.ExecuteScriptAsync($"window.sapiensBrowserEvent({JsonSerializer.Serialize(new { owner, file })})");
        JsonElement state = default;
        await WaitFor(async () => {
            state = JsonDocument.Parse(await client.GetStringAsync("/api/state")).RootElement;
            return state.GetProperty("preferences").GetProperty("workspaces").TryGetProperty(owner, out var workspace) &&
                browser.HasGuestTitle("Group browser smoke") && workspace.GetProperty("tabs").EnumerateArray().Any(tab => tab.GetProperty("title").GetString() == "Group browser smoke");
        }, "Group navigation did not settle");
        return new { rendered = browser.HasGuestTitle("Group browser smoke"), turns = state.GetProperty("turns").GetArrayLength(),
            tabs = state.GetProperty("preferences").GetProperty("workspaces").GetProperty(owner).GetProperty("tabs") };
    }

    internal static async Task<object[]> Themes(Browser browser, WebView2 shell, string dataDirectory)
    {
        var view = browser.Views.First();
        var observations = new List<object>();
        string original = view.CoreWebView2.Source;
        string textFile = Path.Combine(dataDirectory, "theme-smoke.txt"), htmlFile = Path.Combine(dataDirectory, "theme-smoke.html");
        File.WriteAllText(textFile, "Theme smoke: Unicode مرحبا");
        File.WriteAllText(htmlFile, "<!doctype html><title>Authored theme</title><style>body{background:#123456;color:#abcdef}</style><h1>Authored theme</h1>");
        foreach (var page in new[] { (kind:"blank", url:"about:blank"), (kind:"text", url:new Uri(textFile).AbsoluteUri), (kind:"html", url:new Uri(htmlFile).AbsoluteUri), (kind:"original", url:original) })
        {
            view.CoreWebView2.Navigate(page.url);
            await WaitFor(async () => await view.CoreWebView2.ExecuteScriptAsync($"location.href==={JsonSerializer.Serialize(page.url)} && document.readyState==='complete'") == "true", "Theme navigation did not settle");
            foreach (bool dark in new[] { true, false, true })
            {
                string mode = dark ? "dark" : "light";
                await shell.CoreWebView2.ExecuteScriptAsync($"if(document.documentElement.dataset.theme!=={JsonSerializer.Serialize(mode)})document.querySelector('[data-theme-toggle]').click()");
                await WaitFor(async () => await view.CoreWebView2.ExecuteScriptAsync($"matchMedia('(prefers-color-scheme: dark)').matches==={dark.ToString().ToLowerInvariant()}") == "true", "Theme transition did not settle");
                string rendered = await view.CoreWebView2.ExecuteScriptAsync("({dark:matchMedia('(prefers-color-scheme: dark)').matches,background:getComputedStyle(document.body).backgroundColor,ink:getComputedStyle(document.body).color})");
                observations.Add(new { page.kind, mode, caption = Caption(shell), background = view.DefaultBackgroundColor.ToArgb(),
                    rendered = JsonDocument.Parse(rendered).RootElement, webMessage = view.CoreWebView2.Settings.IsWebMessageEnabled, hostObjects = view.CoreWebView2.Settings.AreHostObjectsAllowed });
            }
        }
        view.CoreWebView2.Navigate(original);
        return observations.ToArray();
    }

    internal static void Navigation(string input, string report)
    {
        var cases = JsonDocument.Parse(File.ReadAllText(input)).RootElement;
        var origin = new Uri(cases.GetProperty("origin").GetString()!);
        var result = new {
            trusted = cases.GetProperty("trusted").EnumerateArray().Select(url => SapiensDesktop.Navigation.Trusted(url.GetString()!, origin)).ToArray(),
            guest = cases.GetProperty("guest").EnumerateArray().Select(url => SapiensDesktop.Navigation.Guest(url.GetString()!, origin)).ToArray()
        };
        File.WriteAllText(report, JsonSerializer.Serialize(result));
    }
}
