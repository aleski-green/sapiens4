using System.Diagnostics;

var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("SAPIENS_CONTRACT_RUBY")!) {
    UseShellExecute = false
};
start.ArgumentList.Add(Environment.GetEnvironmentVariable("SAPIENS_CONTRACT_PROVIDER")!);
foreach (var argument in args) start.ArgumentList.Add(argument);
using var process = Process.Start(start)!;
process.WaitForExit();
return process.ExitCode;
