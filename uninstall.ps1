# Removes the Spotify wallpaper widget installed by install.ps1: closes it, takes it out of Windows startup
# and deletes its folder (the one this script is in).
#   powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\SpotifyWidget\uninstall.ps1"
# -KeepFiles   only close it and remove the autostart; leave the files
param([switch]$KeepFiles)

$dir = $PSScriptRoot
$widget = Join-Path $dir 'spotify-widget.ps1'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($widget, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Closed the widget ($($_.ProcessId))" }

# The Startup shortcut, only if it starts this copy.
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Spotify Widget.lnk'
if (Test-Path $lnk) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    if ($s.Arguments.IndexOf($widget, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-Item $lnk -Force; Write-Host 'Removed from Windows startup' }
}

if ($KeepFiles) { return }
if (Test-Path (Join-Path $dir '.git')) {
    Write-Host "Not deleting $dir`: it is a git checkout (source code), not an installed copy."
    return
}
Set-Location $env:TEMP
Remove-Item $dir -Recurse -Force
Write-Host "Deleted $dir"
