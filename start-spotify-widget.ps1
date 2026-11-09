# Starts the Spotify wallpaper widget in the background (no console window). Safe to run twice: only one copy runs.
$script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'spotify-widget.ps1'
Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script`""
