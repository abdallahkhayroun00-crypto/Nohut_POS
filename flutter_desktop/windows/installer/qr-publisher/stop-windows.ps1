# Nohut QR Publisher - stop the local publisher and its sign-in shortcut.
# Used by the uninstaller. Touches only node.exe processes running
# QRPublisher\server.mjs; keys and DPAPI vaults in %APPDATA% are kept.
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*QRPublisher*server.mjs*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
$shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Nohut QR Publisher.lnk'
Remove-Item -LiteralPath $shortcut -Force
exit 0
