using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;

namespace SapiensDesktop;

internal sealed class Browser : IDisposable
{
    readonly Form form;
    readonly WebView2 shell;
    readonly Host host;
    internal Browser(Form form, WebView2 shell, Host host)
    {
        this.form = form; this.shell = shell; this.host = host;
        shell.LocationChanged += PositionGuest;
    }
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

    Task<string>? guestScript;

    async Task ApplyTheme(Tab tab)
    {
        tab.View.CoreWebView2.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
        await ApplyDocumentTheme(tab);
    }
    async Task ApplyDocumentTheme(Tab tab)
    {
        guestScript ??= File.ReadAllTextAsync(Path.Combine(host.RuntimeDirectory, ".build", "web", "guest.js"));
        string settings = JsonSerializer.Serialize(new { dark, background = ColorTranslator.ToHtml(background), foreground = ColorTranslator.ToHtml(foreground) });
        bool managed = await tab.View.CoreWebView2.ExecuteScriptAsync((await guestScript) + $";window.sapiensDocumentTheme({settings})") == "true";
        if (disposed || tab.View.IsDisposed) return;
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
            foreach (string key in tabs.Keys.Except(live).ToArray())
            {
                if (tabs[key].View.ContainsFocus) shell.Focus();
                tabs[key].View.Dispose(); tabs.Remove(key);
            }
            string? active = message.GetProperty("active").GetString();
            foreach (var entry in tabs)
            {
                bool visible = message.GetProperty("visible").GetBoolean() && entry.Key == owner + "/" + active;
                if (!visible && entry.Value.View.ContainsFocus) shell.Focus();
                entry.Value.View.Visible = visible;
            }
            PositionGuest(null, EventArgs.Empty);
        }
        finally { synchronization.Release(); }
    }
    void PositionGuest(object? sender, EventArgs e)
    {
        if (disposed || latest.ValueKind != JsonValueKind.Object || !latest.GetProperty("visible").GetBoolean() ||
            !tabs.TryGetValue(owner + "/" + latest.GetProperty("active").GetString(), out var current)) return;
        var rect = latest.GetProperty("rect");
        double scale = form.DeviceDpi / 96.0 * shell.ZoomFactor;
        int Coordinate(string name) => (int)Math.Clamp(rect.GetProperty(name).GetDouble() * scale, 0, 20000);
        Point origin = form.PointToClient(shell.PointToScreen(Point.Empty));
        current.View.Bounds = new Rectangle(origin.X + Coordinate("x"), origin.Y + Coordinate("y"), Coordinate("width"), Coordinate("height"));
        current.View.Visible = true; current.View.BringToFront();
    }
    public void Dispose() { disposed = true; shell.LocationChanged -= PositionGuest; foreach (var tab in tabs.Values) tab.View.Dispose(); tabs.Clear(); }
}
