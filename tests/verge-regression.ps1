param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'network.ps1')

# A real local pipe replaces the core, not the discovery or HTTP transport code.
# Its random identity and temporary profiles are independent of the host PC.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
public sealed class CampusVergePipeFixture : IDisposable {
    readonly NamedPipeServerStream server;
    readonly Thread worker;
    volatile bool stopped;
    bool tun = true;
    public CampusVergePipeFixture(NamedPipeServerStream stream) {
        server = stream;
        worker = new Thread(Run); worker.IsBackground = true; worker.Start();
    }
    void Run() {
        while (!stopped) {
            try {
                server.WaitForConnection();
                using (var reader = new StreamReader(server, Encoding.UTF8, false, 4096, true)) {
                    var request = reader.ReadLine();
                    int length = 0; bool authorized = false;
                    string line;
                    while (!String.IsNullOrEmpty(line = reader.ReadLine())) {
                        if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                            length = Int32.Parse(line.Substring(15).Trim());
                        if (line == "Authorization: Bearer fixture-only") authorized = true;
                    }
                    var body = new char[length];
                    int count = 0;
                    while (count < length) {
                        int read = reader.Read(body, count, length - count);
                        if (read == 0) break;
                        count += read;
                    }
                    string response = ""; int status = 200;
                    if (!authorized) status = 401;
                    else if (request.StartsWith("PATCH /configs ")) {
                        tun = !new String(body).Contains("\"enable\":false"); status = 204;
                    } else if (request.StartsWith("GET /configs ")) {
                        response = "{\"mode\":\"rule\",\"tun\":{\"enable\":" +
                            (tun ? "true" : "false") + ",\"device\":\"Meta\"}}";
                    } else status = 404;
                    var bytes = Encoding.UTF8.GetBytes(response);
                    var header = Encoding.ASCII.GetBytes("HTTP/1.0 " + status +
                        " Test\r\nContent-Length: " + bytes.Length + "\r\nConnection: close\r\n\r\n");
                    server.Write(header, 0, header.Length);
                    if (bytes.Length > 0) server.Write(bytes, 0, bytes.Length);
                    server.Flush();
                    server.WaitForPipeDrain();
                }
            } catch { if (stopped) return; }
            finally { try { if (server.IsConnected) server.Disconnect(); } catch {} }
        }
    }
    public void Dispose() { stopped = true; server.Dispose(); worker.Join(1500); }
}
'@

function New-FixturePipe([string]$Name) {
    # The random test-only stub contains no user configuration. Restricted test tokens can read and write it.
    $rights = [IO.Pipes.PipeSecurity]::new()
    $rights.AddAccessRule([IO.Pipes.PipeAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','Allow'))
    $rights.AddAccessRule([IO.Pipes.PipeAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'ReadWrite','Allow'))
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $server = [IO.Pipes.NamedPipeServerStreamAcl]::Create($Name,'InOut',1,'Byte','Asynchronous',4096,4096,$rights)
    } else { $server = [IO.Pipes.NamedPipeServerStream]::new($Name,'InOut',1,'Byte','Asynchronous',4096,4096,$rights) }
    return [CampusVergePipeFixture]::new($server)
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('campus-verge-test-' + [guid]::NewGuid().ToString('N'))
$oldAppData = $env:APPDATA; $oldProfile = $env:USERPROFILE
$service = $null; $sidecar = $null
try {
    $env:APPDATA = Join-Path $temporary 'roaming'
    $env:USERPROFILE = Join-Path $temporary 'user'
    $vergeDir = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
    $legacyDir = Join-Path $env:USERPROFILE '.config\clash'
    New-Item -ItemType Directory -Path $vergeDir,$legacyDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyDir 'config.yaml') -Value 'external-controller: 127.0.0.1:1'
    $id = [guid]::NewGuid().ToString('N')
    $serviceName = 'verge-mihomo-production-' + $id
    $sidecarName = 'verge-mihomo-sidecar-release-' + $id
    $service = New-FixturePipe $serviceName
    $runtime = Join-Path $vergeDir 'clash-verge.yaml'
    Set-Content -LiteralPath $runtime -Value @(
        "external-controller: ''", ('external-controller-pipe: \\.\pipe\' + $sidecarName), 'secret: fixture-only')
    $controller = Get-LocalClashController
    Assert-True ($controller -and $controller.config_path -eq $runtime) 'An obsolete CFW config hides the active Verge controller.'
    Assert-True ($controller.pipe_name -eq $serviceName) 'Verge service mode must resolve the matching production pipe.'
    $status = Invoke-ClashApi $controller
    Assert-True ($status.tun.enable -and $status.tun.device -eq 'Meta') 'Service-pipe GET failed.'
    Invoke-ClashApi $controller 'PATCH' @{ tun = @{ enable = $false } } | Out-Null
    Assert-True (-not (Invoke-ClashApi $controller).tun.enable) 'Service-pipe PATCH must actually change the core state.'
    Write-Output 'PASS: An arbitrary user profile discovers the active Verge service pipe despite stale CFW settings.'
    Write-Output 'PASS: Pipe transport authenticates GET and PATCH with HTTP responses.'

    $service.Dispose(); $service = $null
    $sidecar = New-FixturePipe $sidecarName
    $controller = Get-LocalClashController -ConfigPath $runtime
    Assert-True ($controller -and $controller.pipe_name -eq $sidecarName) 'Ordinary sidecar mode must use its configured local pipe.'
    Write-Output 'PASS: The same config works in ordinary sidecar mode.'

    $unsafe = Join-Path $temporary 'remote.yaml'
    Set-Content -LiteralPath $unsafe -Value @('external-controller: 192.0.2.1:9999','secret: fixture-only')
    Assert-True ($null -eq (Get-LocalClashController -ConfigPath $unsafe)) 'Remote controllers must never receive a credential.'
    Write-Output 'PASS: Nonlocal controllers are rejected.'

    foreach ($case in @(
        @{description='Meta Tunnel'; operational='Up'; expected=$true},
        @{description='Meta Tunnel'; operational='Down'; expected=$false},
        @{description='Clash Tunnel'; operational='Up'; expected=$true},
        @{description='Tailscale Tunnel'; operational='Up'; expected=$false}
    )) {
        $adapter = [pscustomobject]@{Description=$case.description;OperationalStatus=$case.operational}
        Assert-True ((Test-ClashTunActive -Interfaces @($adapter)) -eq $case.expected) ('Incorrect adapter classification: ' + $case.description)
    }
    Write-Output 'PASS: Meta and legacy TUN are recognized without treating Tailscale as Clash.'
} finally {
    if ($service) { $service.Dispose() }
    if ($sidecar) { $sidecar.Dispose() }
    $env:APPDATA = $oldAppData; $env:USERPROFILE = $oldProfile
    # All files were created under the explicitly checked temporary test root.
    $absolute = [IO.Path]::GetFullPath($temporary)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test cleanup path.' }
    Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction SilentlyContinue
}
