using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;

namespace SapiensDesktop;

// Runs the production window and host. RSpec drives accessibility externally;
// stdin only changes geometry, as in the macOS fixture, or closes the window.
internal static class AccessibilityProbe
{
    [STAThread]
    static void Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var window = new MainWindow(args);
        var shellView = window.Controls.OfType<WebView2>().Single();
        // Native lifecycle observations keep a reload from reusing the old page.
        shellView.CoreWebView2InitializationCompleted += (_, e) => {
            if (!e.IsSuccess) { Console.WriteLine("NAVIGATION ERROR " + e.InitializationException); return; }
            shellView.CoreWebView2.NavigationStarting += (_, navigation) =>
                Console.WriteLine($"NAVIGATION START {navigation.NavigationId}");
            shellView.CoreWebView2.NavigationCompleted += (_, navigation) =>
                Console.WriteLine($"NAVIGATION END {navigation.NavigationId} {navigation.IsSuccess} {navigation.WebErrorStatus}");
        };
        var browserProcesses = new HashSet<int>();
        window.FormClosing += (_, _) => {
            foreach (var view in window.Controls.OfType<WebView2>())
                if (view.CoreWebView2 != null) browserProcesses.Add((int)view.CoreWebView2.BrowserProcessId);
        };
        window.Shown += async (_, _) => {
            var shell = window.Controls.OfType<WebView2>().Single();
            while (!window.IsDisposed && shell.Source?.Scheme != "http") await Task.Delay(50);
            if (window.IsDisposed) return;
            Console.WriteLine("TITLE: " + window.Text);
            Console.WriteLine("Sapiens4: " + shell.Source!.GetLeftPart(UriPartial.Authority));
            _ = Task.Run(() => {
                while (Console.ReadLine() is string line) {
                    var size = JsonSerializer.Deserialize<Dictionary<string, int>>(line)!;
                    window.BeginInvoke(() => {
                        int top = size.GetValueOrDefault("top");
                        window.ClientSize = new Size(size["width"], size["height"] + top);
                        shell.Dock = DockStyle.None;
                        shell.Bounds = new Rectangle(0, top, window.ClientSize.Width, window.ClientSize.Height - top);
                    });
                }
                window.BeginInvoke(() => window.Close());
            });
        };
        Application.Run(window);
        foreach (int pid in browserProcesses)
            try { using var process = System.Diagnostics.Process.GetProcessById(pid); process.WaitForExit(5000); }
            catch (ArgumentException) { } // WebView2 already exited.
    }
}
