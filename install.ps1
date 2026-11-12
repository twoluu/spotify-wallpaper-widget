# Installs the Spotify wallpaper widget for the current Windows user. No admin rights needed.
#
#   One line, straight from GitHub (paste into PowerShell):
#     irm https://raw.githubusercontent.com/twoluu/spotify-wallpaper-widget/main/install.ps1 | iex
#   From a downloaded or cloned copy:
#     powershell -ExecutionPolicy Bypass -File install.ps1
#
# Options (from a copy; or one line: & ([scriptblock]::Create((irm <install.ps1 url>))) -NoAutostart):
#   -InstallDir <path>   where the widget goes (default: %LOCALAPPDATA%\SpotifyWidget)
#   -NoAutostart         do not start it together with Windows
#   -NoStart             do not start it now
#   -Style glass|wood    the look: dark glass card (default) or pixel-art wooden frame
#   -NoSpicetify         do not add the extension to Spicetify (see below)
# If Spicetify (spicetify.app) is installed, the widget-volume.js extension is added to it: the widget's volume
# then moves Spotify's own slider and the heart adds songs to Liked Songs. Spotify restarts once for that.
# Without Spicetify the widget still works (volume through Windows, no heart).
# Running it again updates the widget and keeps its saved position and look.
param(
    [ValidateSet('', 'glass', 'wood')][string]$Style = '',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'SpotifyWidget'),
    [switch]$NoAutostart,
    [switch]$NoStart,
    [switch]$NoSpicetify
)
$ErrorActionPreference = 'Stop'
$Repo = 'twoluu/spotify-wallpaper-widget'
$Branch = 'main'
$Files = 'spotify-widget.ps1', 'start-spotify-widget.ps1', 'stop-spotify-widget.ps1', 'install.ps1', 'uninstall.ps1', 'README.md', 'LICENSE'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'   # the widget needs Windows PowerShell 5.1

if ([Environment]::OSVersion.Version.Major -lt 10 -or [Environment]::OSVersion.Version.Build -lt 17763) {
    throw 'The widget needs Windows 10 version 1809 or newer (it reads Windows media controls).'
}

# Where the files come from: this folder when run from a copy, otherwise the latest version on GitHub.
$tmp = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'spotify-widget.ps1'))) {
    $src = $PSScriptRoot
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('spotify-widget-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'widget.zip'
    Write-Host "Downloading github.com/$Repo ..."
    Invoke-WebRequest "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp
    $src = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
}

$target = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$widget = Join-Path $target 'spotify-widget.ps1'

# Close a copy already running from the install folder, so its files can be replaced.
function Get-WidgetProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match '[\\/"]spotify-widget\.ps1' -and $_.CommandLine -notmatch '-Snapshot' }
}
Get-WidgetProcess | Where-Object { $_.CommandLine.IndexOf($widget, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force -Path $target | Out-Null
if ([IO.Path]::GetFullPath($src).TrimEnd('\') -ne $target) {
    foreach ($f in $Files) {
        $from = Join-Path $src $f
        if (Test-Path $from) { Copy-Item -Path $from -Destination $target -Force }
    }
}
if (-not (Test-Path $widget)) { throw "spotify-widget.ps1 was not found in $src" }
$extSrc = Join-Path $src 'spicetify\widget-volume.js'
$extCopy = Join-Path $target 'spicetify\widget-volume.js'
if ((Test-Path $extSrc) -and $extSrc -ne $extCopy) {
    New-Item -ItemType Directory -Force -Path (Split-Path $extCopy) | Out-Null
    Copy-Item $extSrc $extCopy -Force
}
Get-ChildItem $target -File | Unblock-File   # files from the internet would otherwise be blocked
if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "Installed to $target"

# The look goes into settings.json, next to the saved position.
if ($Style) {
    $settingsPath = Join-Path $target 'settings.json'
    $h = @{}
    if (Test-Path $settingsPath) {
        try { (Get-Content $settingsPath -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } } catch {}
    }
    $h['style'] = $Style
    $h | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Host "Look: $Style"
}

# Spicetify: put the extension in and turn it on (only when it changed: applying restarts Spotify).
$spicetify = Get-Command spicetify -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $spicetify -and (Test-Path "$env:LOCALAPPDATA\spicetify\spicetify.exe")) { $spicetify = "$env:LOCALAPPDATA\spicetify\spicetify.exe" }
if ($NoSpicetify -or -not (Test-Path $extCopy)) {
} elseif (-not $spicetify) {
    Write-Host 'Spicetify not found: volume goes through Windows and the heart stays off (see README to add it later).'
} else {
    $extDir = Join-Path $env:APPDATA 'spicetify\Extensions'
    $extLive = Join-Path $extDir 'widget-volume.js'
    $changed = -not (Test-Path $extLive) -or (Get-FileHash $extLive).Hash -ne (Get-FileHash $extCopy).Hash
    New-Item -ItemType Directory -Force -Path $extDir | Out-Null
    Copy-Item $extCopy $extLive -Force
    $listed = (& $spicetify config extensions 2>$null | Out-String) -match 'widget-volume\.js'
    if (-not $listed) { & $spicetify config extensions widget-volume.js | Out-Null; $changed = $true }
    if ($changed) {
        Write-Host 'Adding the extension to Spicetify (Spotify restarts) ...'
        & $spicetify apply | Out-Null
        if ($LASTEXITCODE -ne 0) { & $spicetify backup apply | Out-Null }   # after a Spotify update
    }
    Write-Host 'Spicetify extension: on (volume = Spotify''s slider, heart = Liked Songs).'
}

# Start together with Windows: a shortcut in the user's Startup folder.
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Spotify Widget.lnk'
if (-not $NoAutostart) {
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = $PsExe
    $s.Arguments = "-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$widget`""
    $s.WorkingDirectory = $target
    $s.WindowStyle = 7
    $s.Description = 'Spotify wallpaper widget'
    $s.Save()
    Write-Host "Starts with Windows (shortcut: $lnk)"
}

if (-not $NoStart) {
    $other = Get-WidgetProcess | Where-Object { $_.CommandLine.IndexOf($widget, [StringComparison]::OrdinalIgnoreCase) -lt 0 }
    if ($other) {
        Write-Host "Another copy of the widget is already running (process $($other[0].ProcessId)); close it first, only one copy runs at a time."
    } else {
        Start-Process -FilePath $PsExe -WindowStyle Hidden -ArgumentList '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$widget`""
        Write-Host 'Started. It sits on the desktop, under all windows: minimize them to see it.'
    }
}
Write-Host "To remove it: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $target 'uninstall.ps1')`""
