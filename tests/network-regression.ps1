param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'

# Import function definitions without running the watchdog or touching the desktop.
function Import-WatchdogFunction([string]$Name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepoRoot 'watchdog.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if (-not $definition) { throw "Missing watchdog function: $Name" }
    . ([scriptblock]::Create($definition.Extent.Text.Replace("function $Name", "function global:$Name")))
}

Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class CampusProbeFixture : IDisposable {
    readonly TcpListener listener;
    readonly Thread worker;
    volatile bool stopped;
    public string Body = "<html>Campus login required</html>";
    public int Status = 200;
    public volatile int FailuresRemaining;
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    public CampusProbeFixture() {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        worker = new Thread(Run); worker.IsBackground = true; worker.Start();
    }
    void Run() {
        while (!stopped) {
            try {
                using (var client = listener.AcceptTcpClient()) {
                    client.ReceiveTimeout = 500;
                    using (var stream = client.GetStream()) {
                        try { stream.Read(new byte[4096], 0, 4096); } catch { continue; }
                        var bytes = Encoding.UTF8.GetBytes(Body);
                        int status = Status;
                        if (FailuresRemaining > 0) { FailuresRemaining--; status = 503; }
                        var header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status +
                            " Test\r\nContent-Length: " + bytes.Length +
                            "\r\nLocation: http://127.0.0.1/login\r\nConnection: close\r\n\r\n");
                        stream.Write(header, 0, header.Length);
                        stream.Write(bytes, 0, bytes.Length);
                    }
                }
            } catch { if (stopped) return; }
        }
    }
    public void Dispose() { stopped = true; listener.Stop(); worker.Join(1500); }
}
'@

$networkFile = Join-Path $RepoRoot 'network.ps1'
if (Test-Path -LiteralPath $networkFile) { . $networkFile }
Import-WatchdogFunction 'Test-Internet'
$fixture = New-Object CampusProbeFixture
try {
    $ProbeTimeoutMs = 500
    $ProbeTargets = @(@{ ip = '127.0.0.1'; port = $fixture.Port })
    $HttpProbeTargets = @(@{
        url = "http://127.0.0.1:$($fixture.Port)/connecttest.txt"
        status = 200
        body = 'Microsoft Connect Test'
    })
    if (Test-Internet) {
        throw 'REGRESSION: an accepting TCP socket / captive portal was reported as online.'
    }
    Write-Output 'PASS: TCP acceptance and a captive portal cannot prove internet access.'
    $fixture.Body = 'Microsoft Connect Test'
    if (-not (Test-Internet)) { throw 'A verified HTTP response must be online.' }
    Write-Output 'PASS: the expected HTTP response proves internet access.'
    $fixture.Status = 302
    if (Test-Internet) { throw 'A redirect to the login page must be offline.' }
    Write-Output 'PASS: a captive-portal redirect stays offline.'
    $fixture.Status = 204; $fixture.Body = ''
    $HttpProbeTargets = @(
        @{ url = 'http://127.0.0.1:1/unavailable'; status = 204; body = '' },
        @{ url = "http://127.0.0.1:$($fixture.Port)/generate_204"; status = 204; body = '' }
    )
    if (-not (Test-Internet)) { throw 'An unavailable probe must fall back to another target.' }
    Write-Output 'PASS: a second probe works when the first is unavailable.'
    $fixture.FailuresRemaining = 2
    $HttpProbeTargets = @($HttpProbeTargets[1])
    if (-not (Wait-InternetHttp -Targets $HttpProbeTargets -TimeoutMs 500 -TimeoutSec 6)) {
        throw 'A temporarily unavailable restarted proxy must be allowed to settle.'
    }
    Write-Output 'PASS: proxy startup can settle before declaring restored internet access.'
} finally { $fixture.Dispose() }
