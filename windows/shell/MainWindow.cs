using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;

namespace SapiensDesktop;

internal sealed class MainWindow : Form
{
    readonly Host host;
    readonly WebView2 shell = new() { Dock = DockStyle.Fill };
    readonly Label status = new() { Text = "Starting Sapiens4…", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter };
    Browser? browser;
    readonly WindowTheme windowTheme = new();
    bool closing;
    internal MainWindow(string[] args)
    {
        Text = "Sapiens4"; AccessibleName = "Sapiens4"; Width = 1440; Height = 960; MinimumSize = new Size(860, 600); StartPosition = FormStartPosition.CenterScreen;
        Icon = windowTheme.LightIcon;
        string? Option(string name) { int index = Array.IndexOf(args, name); return index >= 0 && index + 1 < args.Length ? args[index + 1] : null; }
        host = new Host(Option("--data-dir"), Option("--runtime-dir"));
        Controls.Add(shell); Controls.Add(status);
        Shown += async (_, _) => await Start();
        FormClosed += (_, _) => { closing = true; browser?.Dispose(); shell.Dispose(); host.Dispose(); windowTheme.Dispose(); };
    }
    async Task Start()
    {
        try
        {
            Uri url = await host.Start();
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(host.DataDirectory, "WebView2", "Shell"));
            await shell.EnsureCoreWebView2Async(environment);
            var core = shell.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.AreHostObjectsAllowed = false;
            browser = new Browser(this, shell, host);
            core.NavigationStarting += (_, e) => { if (!Navigation.Trusted(e.Uri, host.Origin)) e.Cancel = true; };
            core.NewWindowRequested += (_, e) => { e.Handled = true; if (Navigation.Guest(e.Uri, host.Origin)) _ = browser.Open(e.Uri); };
            core.WebMessageReceived += async (_, e) => {
                if (!Navigation.Trusted(e.Source, host.Origin) || !Navigation.Trusted(core.Source, host.Origin)) return;
                try {
                    using var document = JsonDocument.Parse(e.WebMessageAsJson);
                    windowTheme.Sync(this, document.RootElement);
                    await browser.Sync(document.RootElement.Clone());
                }
                catch (Exception error) { if (!closing) Text = "Sapiens4 — " + error.Message; }
            };
            core.NavigationCompleted += (_, e) => {
                status.Visible = false;
                if (!e.IsSuccess) { status.Text = "Cannot load Sapiens4: " + e.WebErrorStatus; status.Visible = true; }
            };
            core.Navigate(url.ToString());
        }
        catch (Exception error)
        {
            status.Text = "Sapiens4 could not start.\n\n" + error.Message + "\n\nRequires Microsoft Edge WebView2 Runtime.\nData: " + host.DataDirectory;
            status.BringToFront();
        }
    }
}
