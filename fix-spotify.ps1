# After a Spotify update: puts Spicetify and the widget's extension (volume + heart) back into Spotify.
# Run it in your own PowerShell window (Win+X -> Terminal), not from inside another app:
#   powershell -ExecutionPolicy Bypass -File E:\code\spotify-widget\fix-spotify.ps1
$ErrorActionPreference = 'Stop'

$exe = Join-Path $env:APPDATA 'Spotify\Spotify.exe'
if (Test-Path $exe) { Write-Host "Spotify $((Get-Item $exe).VersionInfo.ProductVersion) in $(Split-Path $exe)" }
else { Write-Host "Spotify (desktop version from spotify.com) is not installed in $(Split-Path $exe)."; return }

$spicetify = Get-Command spicetify -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $spicetify -and (Test-Path "$env:LOCALAPPDATA\spicetify\spicetify.exe")) { $spicetify = "$env:LOCALAPPDATA\spicetify\spicetify.exe" }
if (-not $spicetify) {
    Write-Host 'Spicetify is not installed for this Windows user. Install it (official installer), then run this again:'
    Write-Host '  iwr -useb https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | iex'
    return
}
Write-Host "Spicetify $(& $spicetify -v)"

# the widget's extension
$ext = Join-Path $PSScriptRoot 'spicetify\widget-volume.js'
$extDir = Join-Path $env:APPDATA 'spicetify\Extensions'
New-Item -ItemType Directory -Force -Path $extDir | Out-Null
Copy-Item $ext $extDir -Force
if (-not ((& $spicetify config extensions | Out-String) -match 'widget-volume\.js')) { & $spicetify config extensions widget-volume.js }

# apply (Spotify restarts). Right after a Spotify update a plain apply fails and a new backup is needed;
# with a backup already in place it is the other way round, so try apply first and fall back.
& $spicetify apply
if ($LASTEXITCODE -ne 0) { & $spicetify backup apply }
Write-Host ''
Write-Host 'Done. Spotify restarted with Spicetify; the widget''s volume and heart work again in a few seconds.'
