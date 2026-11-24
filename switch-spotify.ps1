# Replaces the Microsoft Store Spotify with the spotify.com desktop build and sets up Spicetify, so the widget's
# heart and Spotify-linked volume work. Run it in your own PowerShell window (Win+X -> Terminal):
#   powershell -ExecutionPolicy Bypass -File E:\code\spotify-widget\switch-spotify.ps1
# Your playlists and library stay (they live in your Spotify account); you may need to log in to Spotify again.
$ErrorActionPreference = 'Stop'
function Step($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }

Step '1/4  Microsoft Store Spotify -> remove'
Get-Process Spotify -ErrorAction SilentlyContinue | Stop-Process -Force
$store = Get-AppxPackage -Name 'SpotifyAB.SpotifyMusic' -ErrorAction SilentlyContinue
if ($store) { $store | Remove-AppxPackage; Write-Host "Removed $($store.PackageFullName)" } else { Write-Host 'Not installed, skipping.' }

Step '2/4  Spotify desktop build from spotify.com -> install'
$setup = Join-Path $env:TEMP 'SpotifyFullSetup.exe'
Invoke-WebRequest 'https://download.scdn.co/SpotifyFullSetup.exe' -OutFile $setup -UseBasicParsing
$sig = Get-AuthenticodeSignature $setup
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Spotify AB') { throw "The downloaded installer is not signed by Spotify AB ($($sig.Status)); stopping." }
Write-Host 'Installer signed by Spotify AB, running it ...'
Start-Process $setup -Wait
$exe = Join-Path $env:APPDATA 'Spotify\Spotify.exe'
for ($i = 0; $i -lt 60 -and -not (Test-Path $exe); $i++) { Start-Sleep -Seconds 2 }
if (-not (Test-Path $exe)) { throw "Spotify did not appear in $(Split-Path $exe)." }
Write-Host "Installed: Spotify $((Get-Item $exe).VersionInfo.ProductVersion)"
Read-Host 'Log in to Spotify in its window if it asks, then press Enter here'

Step '3/4  Spicetify -> install if missing'
$spicetify = Get-Command spicetify -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $spicetify -and (Test-Path "$env:LOCALAPPDATA\spicetify\spicetify.exe")) { $spicetify = "$env:LOCALAPPDATA\spicetify\spicetify.exe" }
if (-not $spicetify) {
    Write-Host 'Installing Spicetify with its official installer (it may ask about Marketplace: either answer is fine) ...'
    Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/spicetify/cli/main/install.ps1' | Invoke-Expression
} else { Write-Host "Already installed: $spicetify" }

Step '4/4  Widget extension + apply'
& (Join-Path $PSScriptRoot 'fix-spotify.ps1')
