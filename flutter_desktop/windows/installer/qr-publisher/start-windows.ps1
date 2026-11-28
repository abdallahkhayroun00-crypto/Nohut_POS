# Nohut QR Publisher • Windows local service
# Requires Node.js 22+ and the existing GitHub App private key from Downloads.
# Generates a private random access code and stores it in Windows DPAPI for POS.
# -NoPrompt: used by POS auto-start, the Startup shortcut and Setup. Never
# opens the file picker; a missing key is reported in status.json instead.
param([string]$PrivateKeyFile = "",[int]$Port = 18787,[switch]$NoPrompt,[string]$NodeExecutable = "")
$ErrorActionPreference = 'Stop'
if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid port.' }
$base = Join-Path $env:APPDATA 'NohutFalafel'
$service = Join-Path $base 'QrPublisher'
New-Item -ItemType Directory -Path $service -Force | Out-Null
$statusFile = Join-Path $service 'status.json'
# POS reads status.json for honest, secret-free status (state, time, message).
function Write-Status([string]$State, [string]$Message) {
  $value = [ordered]@{ state = $State; at = (Get-Date).ToUniversalTime().ToString('o'); message = $Message; port = $Port }
  [IO.File]::WriteAllText($statusFile, ($value | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}
function Stop-With([string]$State, [string]$Message, [int]$Code) {
  Write-Status $State $Message
  Write-Host $Message
  exit $Code
}
trap {
  Write-Status 'failed' ([string]$_.Exception.Message)
  break
}
Write-Status 'starting' 'Başlatılıyor.'
# POS uses -NoProfile, so fnm may not be active in PATH.
# Query node --version rather than node -p to avoid PowerShell quoting issues.
$nodeCandidates = New-Object 'System.Collections.Generic.List[string]'
# An explicit path is useful for isolated installer/lifecycle tests. It is
# still subject to the same executable and Node 22+ version checks.
if (-not [string]::IsNullOrWhiteSpace($NodeExecutable)) {
  if (-not [IO.Path]::IsPathRooted($NodeExecutable) -or
      [IO.Path]::GetFileName($NodeExecutable) -ne 'node.exe' -or
      -not (Test-Path -LiteralPath $NodeExecutable -PathType Leaf)) {
    Stop-With 'node_missing' 'Belirtilen Node.js yolu geçersiz.' 2
  }
  $nodeCandidates.Add($NodeExecutable)
}
foreach ($onPath in @(Get-Command node.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
  if ($onPath.Source) { $nodeCandidates.Add($onPath.Source) }
}
$programFilesNode = Join-Path $env:ProgramFiles 'nodejs\node.exe'
if (Test-Path -LiteralPath $programFilesNode -PathType Leaf) {
  $nodeCandidates.Add($programFilesNode)
}
$fnmRoots = @(
  $env:FNM_DIR,
  (Join-Path $env:APPDATA 'fnm'),
  (Join-Path $env:LOCALAPPDATA 'fnm'),
  (Join-Path $env:USERPROFILE '.fnm')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
foreach ($root in $fnmRoots) {
  $versionsDir = Join-Path $root 'node-versions'
  if (-not (Test-Path -LiteralPath $versionsDir -PathType Container)) { continue }
  foreach ($versionDir in Get-ChildItem -LiteralPath $versionsDir -Directory -ErrorAction SilentlyContinue) {
    $exe = Join-Path $versionDir.FullName 'installation\node.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { $nodeCandidates.Add($exe) }
  }
}
$availableNodes = @()
foreach ($candidate in ($nodeCandidates | Select-Object -Unique)) {
  try {
    # Avoid PowerShell 5.1 native stderr/pipeline semantics and stale
    # LASTEXITCODE. Inspect the actual child process result directly.
    $probeInfo = New-Object System.Diagnostics.ProcessStartInfo
    $probeInfo.FileName = $candidate
    $probeInfo.Arguments = '--version'
    $probeInfo.UseShellExecute = $false
    $probeInfo.CreateNoWindow = $true
    $probeInfo.RedirectStandardOutput = $true
    $probeInfo.RedirectStandardError = $true
    $probe = [Diagnostics.Process]::Start($probeInfo)
    try {
      $stdout = $probe.StandardOutput.ReadToEndAsync()
      $stderr = $probe.StandardError.ReadToEndAsync()
      if (-not $probe.WaitForExit(5000)) {
        $probe.Kill()
        $probe.WaitForExit()
        continue
      }
      $nodeVersion = $stdout.GetAwaiter().GetResult().Trim()
      $match = [regex]::Match($nodeVersion,'^v([0-9]+)\.([0-9]+)\.([0-9]+)$')
      if ($probe.ExitCode -eq 0 -and $match.Success) {
        $availableNodes += [pscustomobject]@{
          Path = $candidate
          Version = [version]($match.Groups[1].Value + '.' + $match.Groups[2].Value + '.' + $match.Groups[3].Value)
        }
      }
    } finally { $probe.Dispose() }
  } catch { continue }
}
$selectedNode = $availableNodes | Where-Object { $_.Version.Major -ge 22 } |
  Sort-Object Version -Descending | Select-Object -First 1
if (-not $selectedNode) {
  Stop-With 'node_missing' 'Node.js 22 veya üstü bulunamadı. Ücretsiz Node.js LTS kurun, sonra POS içinden Hizmeti Başlat.' 2
}
$nodePath = $selectedNode.Path
Write-Host ('QR Publisher Node: ' + $selectedNode.Version.ToString() + ' (' + $nodePath + ')')
if ([string]::IsNullOrWhiteSpace($PrivateKeyFile)) {
  $existingKey = Join-Path $env:APPDATA 'NohutFalafel\QrPublisher\github-app-private-key.pem'
  if (Test-Path -LiteralPath $existingKey -PathType Leaf) {
    $PrivateKeyFile = $existingKey
  }
}
if ([string]::IsNullOrWhiteSpace($PrivateKeyFile)) {
  # Accept GitHub's original generated filename in the protected folder,
  # including the user's existing nohut-qr-publisher.2026-11-20.private-key.pem.
  # Prefer a protected local key, then Downloads, and finally the file picker.
  $protectedFolder = Join-Path $env:APPDATA 'NohutFalafel\QrPublisher'
  $candidateFiles = @()
  foreach ($folder in @($protectedFolder,(Join-Path $env:USERPROFILE 'Downloads'))) {
    if (Test-Path -LiteralPath $folder -PathType Container) {
      $candidateFiles += @(Get-ChildItem -LiteralPath $folder -Filter 'nohut-qr-publisher*.pem' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    }
  }
  if ($candidateFiles.Count -gt 0) { $PrivateKeyFile = $candidateFiles[0].FullName }
}
# If the key is neither in the protected folder nor Downloads, allow a
# one-time Windows file selection. The PEM never goes into the GitHub repo.
if (([string]::IsNullOrWhiteSpace($PrivateKeyFile) -or -not (Test-Path -LiteralPath $PrivateKeyFile -PathType Leaf)) -and $NoPrompt) {
  Stop-With 'key_missing' 'GitHub App anahtarı (.pem) bulunamadı. POS içinden Anahtar Dosyasını Seç ile bir kez seçin.' 3
}
if ([string]::IsNullOrWhiteSpace($PrivateKeyFile) -or -not (Test-Path -LiteralPath $PrivateKeyFile -PathType Leaf)) {
  Add-Type -AssemblyName System.Windows.Forms
  $picker = New-Object System.Windows.Forms.OpenFileDialog
  $picker.Title = 'Nohut QR Publisher - GitHub App Private Key (.pem) Seç'
  $picker.Filter = 'GitHub App Private Key (*.pem)|*.pem'
  $picker.Multiselect = $false
  $picker.CheckFileExists = $true
  if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $PrivateKeyFile = $picker.FileName
  }
}
if ([string]::IsNullOrWhiteSpace($PrivateKeyFile) -or -not (Test-Path -LiteralPath $PrivateKeyFile -PathType Leaf)) {
  Stop-With 'key_missing' 'Anahtar dosyası seçilmedi. GitHub App anahtarını (.pem) bir kez seçin.' 3
}
$keyText = Get-Content -LiteralPath $PrivateKeyFile -Raw -Encoding UTF8
if ($keyText -notmatch '-----BEGIN (RSA )?PRIVATE KEY-----') {
  throw 'Seçilen dosya GitHub App private key (.pem) değil.'
}
$localKey = Join-Path $service 'github-app-private-key.pem'
if ((Resolve-Path -LiteralPath $PrivateKeyFile).Path -ne $localKey) {
  Copy-Item -LiteralPath $PrivateKeyFile -Destination $localKey -Force
}
# This private directory belongs to the current Windows user, not POS source.
# The POS stores only a distinct, random DPAPI-encrypted access code.

$account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $localKey /inheritance:r /grant:r ($account + ':(F)') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Private key ACL ayarlanamadı.' }
Add-Type -AssemblyName 'System.Security'
$serverVault = Join-Path $service 'access-code.dpapi'
$posVault = Join-Path $base 'qr-publisher-credentials.dpapi'
if (Test-Path -LiteralPath $serverVault) {
  $protected = [Convert]::FromBase64String((Get-Content -LiteralPath $serverVault -Raw -Encoding UTF8).Trim())
  $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $token = [Text.Encoding]::UTF8.GetString($plain)
} else {
  $bytes = New-Object byte[] 48
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
  $plain = [Text.Encoding]::UTF8.GetBytes($token)
  $protected = [Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  [IO.File]::WriteAllText($serverVault,[Convert]::ToBase64String($protected),[Text.Encoding]::UTF8)
}
$posJson = '{"token":"' + $token + '"}'
$posBytes = [Text.Encoding]::UTF8.GetBytes($posJson)
$posProtected = [Security.Cryptography.ProtectedData]::Protect($posBytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
[IO.File]::WriteAllText($posVault,[Convert]::ToBase64String($posProtected),[Text.Encoding]::UTF8)
$env:GITHUB_APP_ID = '5845851'
$env:GITHUB_APP_PRIVATE_KEY_FILE = $localKey
$env:QR_PUBLISH_ADMIN_TOKEN = $token
$env:QR_PUBLISH_PORT = [string]$Port
# Already running (e.g. Startup shortcut won the race): vaults are refreshed
# above. After an upgrade an older publisher may still hold the port: stop
# exactly that process (node.exe running a QRPublisher\server.mjs) and start
# the bundled version.
$bundled = [regex]::Match((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'server.mjs') -Raw -Encoding UTF8), "const VERSION='([^']+)'").Groups[1].Value
$health = $null
try { $health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/health') -TimeoutSec 2 } catch { }
if ($health -and $health.service -eq 'Nohut QR Publisher') {
  if ([string]$health.version -eq $bundled) {
    Stop-With 'running' ('Zaten çalışıyor (' + $bundled + ').') 0
  }
  $owners = @(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique)
  foreach ($owner in $owners) {
    $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $owner) -ErrorAction SilentlyContinue
    if ($proc -and $proc.Name -eq 'node.exe' -and $proc.CommandLine -like '*QRPublisher*server.mjs*') {
      Write-Host ('Stopping older QR Publisher (' + [string]$health.version + ')')
      Stop-Process -Id $owner -Force
    }
  }
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 250
  }
}
# Start at Windows sign-in, hidden and without prompts. Rewritten every run so
# upgrades replace older shortcuts that could open a file picker at sign-in.
# The lifecycle test uses a disposable APPDATA profile. Do not create a
# shortcut in the runner's real shell folders. In production prefer the
# Windows shell's (possibly redirected) Startup folder, with an APPDATA
# fallback when the shell API returns an empty path.
$startup = $null
if (-not ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_TEMP)) {
  $startup = [Environment]::GetFolderPath('Startup')
}
if ([string]::IsNullOrWhiteSpace($startup)) {
  $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
}
New-Item -ItemType Directory -Path $startup -Force | Out-Null
$shortcutFile = Join-Path $startup 'Nohut QR Publisher.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcutFile)
$link.TargetPath = Join-Path $PSHOME 'powershell.exe'
$link.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -NoPrompt'
$link.WorkingDirectory = $PSScriptRoot
$link.Description = 'Nohut QR Publisher · Windows girişinde otomatik başlat'
$link.Save()
$log = Join-Path $service 'publisher.log'
$errorLog = Join-Path $service 'publisher-error.log'
foreach ($file in @($log, $errorLog)) {
  if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 512KB) {
    Move-Item -LiteralPath $file -Destination ($file + '.1') -Force
  }
}
Write-Status 'running' ('127.0.0.1:' + $Port + ' · Node ' + $selectedNode.Version.ToString())
Write-Host 'Starting Nohut QR Publisher on localhost' $Port
$process = Start-Process -FilePath $nodePath -ArgumentList ('"' + (Join-Path $PSScriptRoot 'server.mjs') + '"') `
  -WorkingDirectory $PSScriptRoot -NoNewWindow -Wait -PassThru `
  -RedirectStandardOutput $log -RedirectStandardError $errorLog
switch ($process.ExitCode) {
  0 { Write-Status 'stopped' 'Hizmet durduruldu.' }
  98 { Write-Status 'port_busy' ('127.0.0.1:' + $Port + ' başka bir program tarafından kullanılıyor.') }
  default { Write-Status 'exited' ('Hizmet kapandı (kod ' + $process.ExitCode + '). Teknik ayrıntılara bakın.') }
}
exit $process.ExitCode
