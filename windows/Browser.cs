using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;

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
        if (uri.IsFile) return uri.IsLoopback; // Local drives only, never UNC shares.
        if (uri.Scheme is not ("http" or "https")) return false;
        return origin == null || uri.Port != origin.Port || !uri.IsLoopback;
    }
}

internal sealed class Browser(Form form, WebView2 shell, Host host) : IDisposable
{
    sealed class Tab(string owner, string id, WebView2 view)
    {
        internal string Owner = owner, Id = id, Seq = "", Error = "";
        internal WebView2 View = view;
        internal bool Loading;
    }
    readonly Dictionary<string, Tab> tabs = new();
    readonly SemaphoreSlim synchronization = new(1);
    JsonElement latest;
    string owner = "";
    bool disposed;
    bool dark;
    Color background = Color.White, foreground = Color.FromArgb(32, 32, 32);

    string DocumentTheme => $$"""
        (() => {
          // Authored HTML keeps its own styles; only browser-owned blank/text pages get a canvas.
          if (location.href !== 'about:blank' && !['text/plain','application/json','application/xml','text/xml'].includes(document.contentType)) return false;
          let style = document.getElementById('sapiens-document-theme');
          if (!style) { style = document.createElement('style'); style.id = 'sapiens-document-theme'; document.documentElement.append(style); }
          style.textContent = {{JsonSerializer.Serialize($"html,body{{background:{ColorTranslator.ToHtml(background)};color:{ColorTranslator.ToHtml(foreground)};color-scheme:{(dark ? "dark" : "light")}}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}")}};
          return true;
        })();
        """;

    async Task ApplyTheme(Tab tab)
    {
        tab.View.CoreWebView2.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
        await ApplyDocumentTheme(tab);
    }
    async Task ApplyDocumentTheme(Tab tab)
    {
        bool managed = await tab.View.CoreWebView2.ExecuteScriptAsync(DocumentTheme) == "true";
        if (disposed || tab.View.IsDisposed) return;
        // Unstyled HTML assumes black text on a white canvas. Its own CSS/color-scheme
        // paints over this fallback when the page supports a dark appearance.
        tab.View.DefaultBackgroundColor = managed ? background : Color.White;
    }

    internal Task Open(string url) => Report(new { owner, open = url });
    async Task Report(object value)
    {
        if (disposed || shell.IsDisposed || shell.CoreWebView2 == null) return;
        await shell.CoreWebView2.ExecuteScriptAsync($"window.sapiensBrowserEvent?.({JsonSerializer.Serialize(value)})");
    }
    async Task Observe(Tab tab)
    {
        if (disposed || tab.View.IsDisposed || tab.Seq.Length == 0) return;
        var core = tab.View.CoreWebView2;
        await Report(new { owner = tab.Owner, id = tab.Id, seq = tab.Seq, url = core.Source,
            title = core.DocumentTitle, loading = tab.Loading, error = tab.Error,
            can_back = core.CanGoBack, can_forward = core.CanGoForward });
    }
    async Task<Tab> Create(string owner, string id)
    {
        var view = new WebView2 { Visible = false, DefaultBackgroundColor = background };
        form.Controls.Add(view);
        // Per-owner profiles keep websites separate from the trusted app and other Sapis.
        string profile = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(owner)));
        var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(host.DataDirectory, "WebView2", "Guests", profile));
        await view.EnsureCoreWebView2Async(environment);
        var core = view.CoreWebView2;
        core.Settings.IsWebMessageEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        var tab = new Tab(owner, id, view);
        await ApplyTheme(tab);
        core.DOMContentLoaded += async (_, _) => { if (!disposed && !view.IsDisposed) await ApplyDocumentTheme(tab); };
        core.NavigationStarting += async (_, e) => {
            if (!Navigation.Guest(e.Uri, host.Origin)) { e.Cancel = true; tab.Error = "Navigation blocked: use an HTTP(S) URL or a local file."; tab.Loading = false; }
            else { tab.Loading = true; tab.Error = ""; }
            await Observe(tab);
        };
        core.NavigationCompleted += async (_, e) => { tab.Loading = false; if (!e.IsSuccess) tab.Error = e.WebErrorStatus.ToString(); await Observe(tab); };
        core.DocumentTitleChanged += async (_, _) => await Observe(tab);
        core.HistoryChanged += async (_, _) => await Observe(tab);
        core.NewWindowRequested += async (_, e) => { e.Handled = true; if (Navigation.Guest(e.Uri, host.Origin)) await Report(new { owner = tab.Owner, open = e.Uri }); };
        core.ProcessFailed += async (_, e) => { tab.Loading = false; tab.Error = "Browser process failed: " + e.ProcessFailedKind; await Observe(tab); };
        return tab;
    }
    internal async Task Sync(JsonElement message)
    {
        if (disposed) return;
        if (message.TryGetProperty("pickFile", out var pick) && pick.ValueKind == JsonValueKind.True)
        {
            string selectedOwner = message.GetProperty("owner").GetString()!;
            using var dialog = new OpenFileDialog { Title = "Open in Sapiens4", CheckFileExists = true };
            if (message.TryGetProperty("directory", out var directory) && Directory.Exists(directory.GetString())) dialog.InitialDirectory = directory.GetString();
            if (dialog.ShowDialog(form) == DialogResult.OK) await Report(new { owner = selectedOwner, file = dialog.FileName });
            return;
        }
        latest = message;
        await synchronization.WaitAsync();
        try
        {
            if (disposed) return;
            message = latest;
            bool nextDark = message.TryGetProperty("dark", out var mode) && mode.ValueKind == JsonValueKind.True;
            Color Palette(string name, Color fallback)
            {
                if (message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String)
                {
                    string hex = value.GetString()!;
                    if (System.Text.RegularExpressions.Regex.IsMatch(hex, "^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$")) return ColorTranslator.FromHtml(hex);
                }
                return fallback;
            }
            Color nextBackground = Palette("background", nextDark ? Color.FromArgb(33, 33, 33) : Color.White);
            Color nextForeground = Palette("foreground", nextDark ? Color.FromArgb(236, 236, 236) : Color.FromArgb(32, 32, 32));
            bool themeChanged = dark != nextDark || background != nextBackground || foreground != nextForeground;
            dark = nextDark; background = nextBackground; foreground = nextForeground;
            owner = message.GetProperty("owner").GetString() ?? "";
            var live = new HashSet<string>();
            foreach (var workspace in message.GetProperty("workspaces").EnumerateObject())
            {
                foreach (var spec in workspace.Value.GetProperty("tabs").EnumerateArray())
                {
                    string id = spec.GetProperty("id").GetString()!;
                    string key = workspace.Name + "/" + id;
                    live.Add(key);
                    if (!tabs.TryGetValue(key, out var tab)) { tab = await Create(workspace.Name, id); tabs[key] = tab; }
                    else if (themeChanged) await ApplyTheme(tab);
                    if (disposed) return;
                    if (spec.TryGetProperty("zoom", out var zoom)) tab.View.ZoomFactor = Math.Clamp(zoom.GetDouble(), .25, 5);
                    if (spec.TryGetProperty("command", out var command))
                    {
                        string seq = command.GetProperty("seq").GetString()!;
                        if (tab.Seq != seq)
                        {
                            tab.Seq = seq;
                            var core = tab.View.CoreWebView2;
                            switch (command.GetProperty("action").GetString())
                            {
                                case "navigate":
                                    string url = spec.GetProperty("url").GetString()!;
                                    if (Navigation.Guest(url, host.Origin)) core.Navigate(url);
                                    else { tab.Error = "Unsupported destination"; await Observe(tab); }
                                    break;
                                case "reload": core.Reload(); break;
                                case "back": if (core.CanGoBack) core.GoBack(); else await Observe(tab); break;
                                case "forward": if (core.CanGoForward) core.GoForward(); else await Observe(tab); break;
                            }
                        }
                    }
                }
            }
            foreach (string key in tabs.Keys.Except(live).ToArray()) { tabs[key].View.Dispose(); tabs.Remove(key); }
            string? active = message.GetProperty("active").GetString();
            foreach (var entry in tabs)
                entry.Value.View.Visible = message.GetProperty("visible").GetBoolean() && entry.Key == owner + "/" + active;
            if (message.GetProperty("visible").GetBoolean() && tabs.TryGetValue(owner + "/" + active, out var current))
            {
                var rect = message.GetProperty("rect");
                double scale = form.DeviceDpi / 96.0 * shell.ZoomFactor;
                int Coordinate(string name) => (int)Math.Clamp(rect.GetProperty(name).GetDouble() * scale, 0, 20000);
                current.View.Bounds = new Rectangle(Coordinate("x"), Coordinate("y"), Coordinate("width"), Coordinate("height"));
                current.View.Visible = true; current.View.BringToFront();
            }
        }
        finally { synchronization.Release(); }
    }
    internal bool HasGuestTitle(string title) => tabs.Values.Any(t => !t.View.IsDisposed && t.View.CoreWebView2.DocumentTitle == title);
    internal IEnumerable<WebView2> Views => tabs.Values.Select(tab => tab.View);
    public void Dispose() { disposed = true; foreach (var tab in tabs.Values) tab.View.Dispose(); tabs.Clear(); }
}
