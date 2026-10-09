using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;

namespace SapiensDesktop;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length > 0 && args[0] == "--self-test") { DesktopTests.Run(args.Skip(1).FirstOrDefault()); return; }
        using var window = new MainWindow(args);
        Application.Run(window);
    }
}

internal sealed class MainWindow : Form
{
    readonly Host host;
    readonly WebView2 shell = new() { Dock = DockStyle.Fill };
    readonly Label status = new() { Text = "Starting Sapiens4…", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter };
    Browser? browser;
    bool closing;
    readonly string? smokeReport;
    internal MainWindow(string[] args)
    {
        Text = "Sapiens4"; Width = 1440; Height = 960; MinimumSize = new Size(860, 600); StartPosition = FormStartPosition.CenterScreen;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        string? Option(string name) { int index = Array.IndexOf(args, name); return index >= 0 && index + 1 < args.Length ? args[index + 1] : null; }
        host = new Host(Option("--data-dir"), Option("--runtime-dir"));
        smokeReport = Option("--smoke-report");
        Controls.Add(shell); Controls.Add(status);
        Shown += async (_, _) => await Start();
        FormClosed += (_, _) => { closing = true; browser?.Dispose(); shell.Dispose(); host.Dispose(); };
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
            string origin = JsonSerializer.Serialize(host.Origin!.GetLeftPart(UriPartial.Authority));
            await core.AddScriptToExecuteOnDocumentCreatedAsync($"if(location.origin==={origin}){{window.webkit={{messageHandlers:{{browser:{{postMessage:data=>chrome.webview.postMessage(data)}}}}}};}}");
            core.NavigationStarting += (_, e) => { if (!Navigation.Trusted(e.Uri, host.Origin)) e.Cancel = true; };
            core.NewWindowRequested += (_, e) => { e.Handled = true; if (Navigation.Guest(e.Uri, host.Origin)) _ = browser.Open(e.Uri); };
            core.WebMessageReceived += async (_, e) => {
                if (!Navigation.Trusted(e.Source, host.Origin) || !Navigation.Trusted(core.Source, host.Origin)) return;
                try { await browser.Sync(JsonDocument.Parse(e.WebMessageAsJson).RootElement.Clone()); }
                catch (Exception error) { if (!closing) Text = "Sapiens4 — " + error.Message; }
            };
            core.NavigationCompleted += async (_, e) => {
                status.Visible = false;
                if (!e.IsSuccess) { status.Text = "Cannot load Sapiens4: " + e.WebErrorStatus; status.Visible = true; }
                else if (smokeReport != null) await Smoke(smokeReport);
            };
            core.Navigate(url.ToString());
        }
        catch (Exception error)
        {
            status.Text = "Sapiens4 could not start.\n\n" + error.Message + "\n\nRequires Microsoft Edge WebView2 Runtime.\nData: " + host.DataDirectory;
            status.BringToFront();
            if (smokeReport != null) { File.WriteAllText(smokeReport, JsonSerializer.Serialize(new { ok = false, error = error.ToString() })); Close(); }
        }
    }
    async Task Smoke(string report)
    {
        try
        {
            for (int attempt = 0; attempt < 100 && await shell.CoreWebView2.ExecuteScriptAsync("document.querySelectorAll('.agent-row').length>0") != "true"; attempt++) await Task.Delay(100);
            string result = await shell.CoreWebView2.ExecuteScriptAsync("JSON.stringify({title:document.title,composer:!!document.querySelector('#message-input'),bridge:!!window.webkit?.messageHandlers?.browser,agents:document.querySelectorAll('.agent-row').length,text:document.body.innerText.slice(0,120)})");
            string decoded = JsonSerializer.Deserialize<string>(result)!;
            if (!JsonDocument.Parse(decoded).RootElement.GetProperty("composer").GetBoolean()) throw new Exception("Composer not rendered");
            if (JsonDocument.Parse(decoded).RootElement.GetProperty("agents").GetInt32() == 0) throw new Exception("Agent list not rendered");
            string file = Path.Combine(host.DataDirectory, "browser-smoke.html");
            File.WriteAllText(file, "<!doctype html><title>Windows browser smoke</title><h1>Windows browser smoke</h1><input aria-label='Test field' value='Unicode مرحبا'>");
            using var client = new HttpClient();
            var state = JsonDocument.Parse(await client.GetStringAsync(new Uri(host.Origin!, "/api/state"))).RootElement;
            string main = state.GetProperty("main_agent_id").GetString()!;
            for (int attempt = 0; attempt < 50 && await shell.CoreWebView2.ExecuteScriptAsync("typeof window.sapiensBrowserEvent") != "\"function\""; attempt++) await Task.Delay(100);
            await shell.CoreWebView2.ExecuteScriptAsync($"window.sapiensBrowserEvent({JsonSerializer.Serialize(new { owner = main, file })})");
            for (int attempt = 0; attempt < 100 && !browser!.HasGuestTitle("Windows browser smoke"); attempt++) await Task.Delay(100);
            if (!browser!.HasGuestTitle("Windows browser smoke")) throw new Exception("Native workspace browser did not load the local file. " + Text);
            int themeChecks = await DesktopTests.CheckThemes(browser, shell, host.DataDirectory);
            await DesktopTests.CheckGroupWorkspace(browser, shell, host, main);
            using var appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            if (appIcon == null) throw new Exception("Windows application icon is missing");
            await using (var image = File.Create(Path.ChangeExtension(report, ".png")))
                await shell.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image);
            File.WriteAllText(report, JsonSerializer.Serialize(new { ok = true, shell = JsonDocument.Parse(decoded).RootElement, nativeBrowser = true, groupBrowser = true, themeChecks, appIcon = true, origin = host.Origin, architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString() }));
        }
        catch (Exception error) { File.WriteAllText(report, JsonSerializer.Serialize(new { ok = false, error = error.ToString() })); }
        Close();
    }
}
