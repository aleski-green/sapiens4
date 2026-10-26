using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace SapiensDesktop;

internal sealed class Host : IDisposable
{
    Process? process;
    readonly StringBuilder errors = new();
    internal string DataDirectory { get; }
    internal string RuntimeDirectory { get; }
    internal Uri? Origin { get; private set; }
    internal Host(string? dataDirectory = null, string? runtimeDirectory = null)
    {
        DataDirectory = Path.GetFullPath(dataDirectory ?? Environment.GetEnvironmentVariable("SAPIENS_DATA_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sapiens4"));
        RuntimeDirectory = Path.GetFullPath(runtimeDirectory ?? Environment.GetEnvironmentVariable("SAPIENS_RUNTIME_DIR") ?? Path.Combine(AppContext.BaseDirectory, "runtime"));
    }
    internal async Task<Uri> Start()
    {
        Directory.CreateDirectory(DataDirectory);
        string python = Environment.GetEnvironmentVariable("SAPIENS_PYTHON") ?? Path.Combine(RuntimeDirectory, "python", "python.exe");
        if (!File.Exists(python)) throw new FileNotFoundException("Python runtime is missing. Extract the complete Sapiens4 package, or set SAPIENS_PYTHON for a source checkout.", python);
        var start = new ProcessStartInfo(python) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = RuntimeDirectory, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        foreach (string arg in new[] { "-X", "utf8", "-m", "sapiens", "--port", "0", "--data-dir", DataDirectory, "--desktop" }) start.ArgumentList.Add(arg);
        start.Environment["PYTHONUTF8"] = "1";
        start.Environment["SAPIENS_DESKTOP_PID"] = Environment.ProcessId.ToString();
        var ready = new TaskCompletionSource<Uri>(TaskCreationOptions.RunContinuationsAsynchronously);
        process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => {
            if (e.Data?.StartsWith("Sapiens4: ") == true && Uri.TryCreate(e.Data[10..].Trim(), UriKind.Absolute, out var uri) && uri.Host == "127.0.0.1" && uri.Scheme == "http") ready.TrySetResult(uri);
        };
        process.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (errors) { errors.AppendLine(e.Data); if (errors.Length > 12000) errors.Remove(0, errors.Length - 12000); } };
        process.Exited += (_, _) => ready.TrySetException(new InvalidOperationException("Sapiens4 server stopped. " + errors.ToString()));
        process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
        var url = await ready.Task.WaitAsync(TimeSpan.FromSeconds(35));
        Origin = new Uri(url.GetLeftPart(UriPartial.Authority));
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        var health = await client.GetStringAsync(new Uri(Origin, "/api/health"));
        if (JsonDocument.Parse(health).RootElement.GetProperty("status").GetString() != "ok") throw new InvalidOperationException("Server readiness check failed");
        return url;
    }
    public void Dispose()
    {
        if (process == null) return;
        if (!process.HasExited)
        {
            try { process.StandardInput.WriteLine("stop"); process.StandardInput.Close(); } catch (IOException) { }
            if (!process.WaitForExit(10000)) process.Kill(entireProcessTree: true);
        }
        process.Dispose(); process = null;
    }
}
