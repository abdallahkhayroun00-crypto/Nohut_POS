# Windows CI only: runs the real start-windows.ps1 with Windows PowerShell 5.1,
# an isolated APPDATA/USERPROFILE and a throwaway RSA key. Never calls GitHub.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:RUNNER_TEMP) {
  throw 'Publisher lifecycle test runs only on an isolated GitHub Actions runner.'
}
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'start-windows.ps1'
$work = Join-Path $env:RUNNER_TEMP ('qrpub-' + [guid]::NewGuid())
$env:APPDATA = Join-Path $work 'AppData'
$env:USERPROFILE = Join-Path $work 'User'
$downloads = Join-Path $env:USERPROFILE 'Downloads'
New-Item -ItemType Directory -Path $env:APPDATA, $downloads -Force | Out-Null
$service = Join-Path $env:APPDATA 'NohutFalafel\QrPublisher'
$statusFile = Join-Path $service 'status.json'
$port = 18917
function Get-Status { Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json }
function Invoke-Start([switch]$Wait) {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"'), '-Port', $port, '-NoPrompt')
  if ($Wait) { return Start-Process powershell.exe -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden }
  return Start-Process powershell.exe -ArgumentList $argList -PassThru -WindowStyle Hidden
}
function Get-Health {
  try { return Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 } catch { return $null }
}
function Wait-Health {
  for ($i = 0; $i -lt 60; $i++) { $h = Get-Health; if ($h) { return $h }; Start-Sleep -Milliseconds 500 }
  throw ('Publisher never answered. Status: ' + (Get-Content -LiteralPath $statusFile -Raw))
}

# 1. No key and -NoPrompt: a clear key_missing, no file picker, exit 3.
$p = Invoke-Start -Wait
if ($p.ExitCode -ne 3 -or (Get-Status).state -ne 'key_missing') {
  throw "Expected key_missing/3, got $((Get-Status).state)/$($p.ExitCode)"
}
Write-Host 'OK key_missing without prompt'

# 2. GitHub's original key file name in Downloads: picked up, protected, started.
$pem = Join-Path $downloads 'nohut-qr-publisher.2026-11-28.private-key.pem'
node -e "process.stdout.write(require('crypto').generateKeyPairSync('rsa',{modulusLength:2048}).privateKey.export({type:'pkcs8',format:'pem'}))" | Set-Content -LiteralPath $pem -Encoding ascii
$running = Invoke-Start
$health = Wait-Health
$expected = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'server.mjs') -Raw), "const VERSION='([^']+)'").Groups[1].Value
if ($health.version -ne $expected) { throw "Version $($health.version) != $expected" }
if ((Get-Status).state -ne 'running') { throw "Status should be running: $((Get-Status).state)" }
if (-not (Test-Path -LiteralPath (Join-Path $service 'github-app-private-key.pem'))) { throw 'Key not copied to protected folder' }
Add-Type -AssemblyName System.Security
$vault = Join-Path $env:APPDATA 'NohutFalafel\qr-publisher-credentials.dpapi'
$plain = [Security.Cryptography.ProtectedData]::Unprotect(
  [Convert]::FromBase64String((Get-Content -LiteralPath $vault -Raw).Trim()), $null, 'CurrentUser')
$token = ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json).token
if ($token.Length -lt 32) { throw 'POS vault token missing' }
Write-Host "OK started $($health.version) on 127.0.0.1:$port"

# 3. A second start while running is a no-op (exit 0), not a second server.
$again = Invoke-Start -Wait
if ($again.ExitCode -ne 0 -or (Get-Status).state -ne 'running') { throw 'Second start was not idempotent' }
Write-Host 'OK idempotent start'

# 4. Shutdown needs the token; with it the publisher exits cleanly.
try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/shutdown" -TimeoutSec 3; throw 'Anonymous shutdown accepted' }
catch { if ($_.Exception.Response.StatusCode.value__ -ne 401) { throw } }
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/shutdown" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 5 | Out-Null
if (-not $running.WaitForExit(15000)) { throw 'Publisher did not stop' }
if ((Get-Status).state -ne 'stopped') { throw "Expected stopped, got $((Get-Status).state)" }
foreach ($log in @('publisher.log', 'publisher-error.log')) {
  $text = Get-Content -LiteralPath (Join-Path $service $log) -Raw -ErrorAction SilentlyContinue
  if ($text -and $text.Contains($token)) { throw "Token leaked into $log" }
}
Write-Host 'OK clean shutdown, no token in logs'

# 5. Port taken by another program: exit 98 and port_busy.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
$listener.Start()
try {
  $busy = Invoke-Start -Wait
  if ($busy.ExitCode -ne 98 -or (Get-Status).state -ne 'port_busy') {
    throw "Expected port_busy/98, got $((Get-Status).state)/$($busy.ExitCode)"
  }
} finally { $listener.Stop() }
Write-Host 'OK port_busy reported'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
