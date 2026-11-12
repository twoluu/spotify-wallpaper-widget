# Spotify widget on the wallpaper: cover, track, artist, progress bar and shuffle / previous / play-pause /
# next / repeat. Two looks: a dark glass card (default) or a pixel-art wooden frame with a "SPOTIFY" name plate.
# It reads what Spotify plays from Windows' own media controls (the same source as the volume pop-up),
# so it needs no Spotify login or API key. It sits on the desktop layer, under every window, and never
# takes focus.
#   Drag the card to move it; the spot is remembered in settings.json next to this script.
#   Click the cover to open Spotify; ▶ starts Spotify and its music when Spotify is closed.
# Parameters:
#   -Style glass|wood            the look; remembered in settings.json, so it is needed only once
#   -Monitor primary|secondary   where it goes the first time (until you drag it somewhere)
#   -BottomMargin                gap to the bottom edge of that monitor, in pixels
#   -Source                      regex matched against the player's app id; 'chrome' tests it with YouTube
#   -Reset                       forget the dragged position
#   -Snapshot <file.png>         render the card to a PNG after 3 s and exit
#                                (for checking the layout; runs beside the real widget, off screen)
param(
    [ValidateSet('', 'glass', 'wood')][string]$Style = '',
    [ValidateSet('primary', 'secondary')][string]$Monitor = 'secondary',
    [int]$BottomMargin = 50,
    [string]$Source = 'Spotify',
    [switch]$Reset,
    [string]$Snapshot
)

if (-not $Snapshot) {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\SpotifyWallpaperWidget')
    if (-not $mutex.WaitOne(0)) { exit }
}

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $dir 'settings.json'
$logPath = Join-Path $dir 'widget.log'
function Log($m) { try { Add-Content -Path $logPath -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m) -Encoding UTF8 } catch {} }

# settings.json (this computer only): the dragged position (x, y) and the look (style).
function Read-Settings {
    $h = @{}
    if (Test-Path $settingsPath) {
        try { (Get-Content $settingsPath -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
        catch { Log "settings: $_" }
    }
    $h
}
function Save-Settings($h) { try { $h | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8 } catch { Log "settings: $_" } }

$settings = Read-Settings
if ($Reset) { $settings.Remove('x'); $settings.Remove('y'); Save-Settings $settings }
# The look: -Style wins and is remembered (except in a -Snapshot); otherwise the remembered one; otherwise glass.
if ($Style) { if (-not $Snapshot -and $settings['style'] -ne $Style) { $settings['style'] = $Style; Save-Settings $settings } }
elseif ($settings['style'] -in 'glass', 'wood') { $Style = $settings['style'] }
else { $Style = 'glass' }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.Runtime.WindowsRuntime

# Keeps the window at the bottom of the z-order (on the wallpaper), out of Alt+Tab, and never activated by a click.
Add-Type -AssemblyName System.Xaml
Add-Type -ReferencedAssemblies ([System.Windows.Interop.HwndSource].Assembly.Location), ([System.Windows.Threading.Dispatcher].Assembly.Location), ([System.Xaml.XamlType].Assembly.Location) @'
using System; using System.Runtime.InteropServices; using System.Windows; using System.Windows.Interop;
using System.Windows.Media; using System.Windows.Media.Imaging;
public static class SpwDesk {
    // Spotify hands Windows a 300x300 picture: the cover on a see-through square with the Spotify logo under it.
    // Keep only the first opaque block from the top (the cover). Pictures without see-through parts stay as they are.
    public static BitmapSource Trim(BitmapSource src) {
        var b = new FormatConvertedBitmap(src, PixelFormats.Bgra32, null, 0);
        int w = b.PixelWidth, h = b.PixelHeight, stride = w * 4;
        var px = new byte[stride * h]; b.CopyPixels(px, stride, 0);
        int top = -1, bottom = -1;
        for (int y = 0; y < h; y++) {
            bool any = false;
            for (int x = 0; x < w; x++) if (px[y * stride + x * 4 + 3] > 20) { any = true; break; }
            if (any) { if (top < 0) top = y; bottom = y; } else if (top >= 0) break;
        }
        if (top < 0) return src;
        int left = w, right = -1;
        for (int y = top; y <= bottom; y++)
            for (int x = 0; x < w; x++)
                if (px[y * stride + x * 4 + 3] > 20) { if (x < left) left = x; if (x > right) right = x; }
        int cw = right - left + 1, ch = bottom - top + 1;
        if ((cw >= w && ch >= h) || cw < w / 4 || ch < h / 4) return src;
        var c = new CroppedBitmap(b, new Int32Rect(left, top, cw, ch)); c.Freeze();
        return c;
    }

    [StructLayout(LayoutKind.Sequential)] struct WINDOWPOS { public IntPtr hwnd, after; public int x, y, cx, cy; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    static readonly IntPtr HWND_BOTTOM = new IntPtr(1);

    public static void Pin(IntPtr h) {
        SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x80 | 0x08000000);   // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
        HwndSource.FromHwnd(h).AddHook(Hook);
        SetWindowPos(h, HWND_BOTTOM, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);  // NOSIZE | NOMOVE | NOACTIVATE
    }
    public static void Move(IntPtr h, int x, int y) { SetWindowPos(h, HWND_BOTTOM, x, y, 0, 0, 0x0001 | 0x0010); }

    // Set when a monitor is plugged in, unplugged or switched off/on (WM_DISPLAYCHANGE); the widget then re-places itself.
    public static volatile bool DisplayChanged;

    public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R - r.L, r.B - r.T }; }

    // The Pixel Agents office (if it runs): a click-through Chrome window titled "Pixel Agents". Windows treats
    // its whole 960 px tall window as opaque and draws nothing under it, even where it is cut away, so a widget
    // below it in the z-order loses the part that sits inside that window. KeepAbove puts us right above it.
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    public static IntPtr FindOffice() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            if (t.ToString() != "Pixel Agents") return true;
            var c = new System.Text.StringBuilder(256); GetClassName(h, c, 256);
            if (!c.ToString().StartsWith("Chrome_WidgetWin") || (GetWindowLong(h, -20) & 0x20) == 0) return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }
    static bool allowZ;
    public static void KeepAbove(IntPtr me, IntPtr other) {
        if (other == IntPtr.Zero || !IsWindowVisible(other)) return;
        IntPtr p = GetWindow(other, 3);   // GW_HWNDPREV
        while (p != IntPtr.Zero && p != me && !IsWindowVisible(p)) p = GetWindow(p, 3);
        if (p == me) return;              // already the first visible window over it
        IntPtr after = GetWindow(other, 3);
        if (after == IntPtr.Zero) after = new IntPtr(0);   // office is on top of everything: go to the very top
        allowZ = true;
        SetWindowPos(me, after, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0200);   // NOSIZE | NOMOVE | NOACTIVATE | NOOWNERZORDER
        allowZ = false;
    }

    static IntPtr Hook(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
        if (msg == 0x0046 && !allowZ) {            // WM_WINDOWPOSCHANGING: whatever moves us, we stay at the bottom
            var p = (WINDOWPOS)Marshal.PtrToStructure(l, typeof(WINDOWPOS));
            p.after = HWND_BOTTOM; p.flags &= ~0x0004u;   // drop SWP_NOZORDER
            Marshal.StructureToPtr(p, l, false);
        } else if (msg == 0x0021) {                // WM_MOUSEACTIVATE: clicks work, the window is not activated
            handled = true; return new IntPtr(3);  // MA_NOACTIVATE
        } else if (msg == 0x007E) {                // WM_DISPLAYCHANGE
            DisplayChanged = true;
        }
        return IntPtr.Zero;
    }
}

// Spotify's own volume, only Spotify gets louder or quieter (Core Audio sessions of the Spotify processes).
// Its session does not hand out ISimpleAudioVolume here (E_NOINTERFACE), but it does hand out IChannelAudioVolume,
// so the widget sets every channel (left, right) of Spotify's sessions to the same level.
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int EnumAudioEndpoints(); [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev); }
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 { int GetAudioSessionControl(); int GetSimpleAudioVolume(); [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e); }
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator { [PreserveSig] int GetCount(out int n); [PreserveSig] int GetSession(int i, out IAudioSessionControl2 s); }
[ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
    int GetState(); int GetDisplayName(); int SetDisplayName(); int GetIconPath(); int SetIconPath();
    int GetGroupingParam(); int SetGroupingParam(); int RegisterAudioSessionNotification(); int UnregisterAudioSessionNotification();
    int GetSessionIdentifier(); int GetSessionInstanceIdentifier();
    [PreserveSig] int GetProcessId(out uint pid);
}
[ComImport, Guid("1C158861-B533-4B30-B1CF-E853E51C59B8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IChannelAudioVolume {
    [PreserveSig] int GetChannelCount(out uint n);
    [PreserveSig] int SetChannelVolume(uint i, float v, ref Guid ctx);
    [PreserveSig] int GetChannelVolume(uint i, out float v);
}
public static class SpwVol {
    static System.Collections.Generic.List<IChannelAudioVolume> Find(string process) {
        var list = new System.Collections.Generic.List<IChannelAudioVolume>();
        try {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
            IMMDevice dev; if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0) return list;   // render, multimedia
            Guid iid = typeof(IAudioSessionManager2).GUID; object o;
            if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return list;
            IAudioSessionEnumerator se; if (((IAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) return list;
            int n; se.GetCount(out n);
            for (int i = 0; i < n; i++) {
                try {
                    IAudioSessionControl2 c; if (se.GetSession(i, out c) != 0) continue;
                    uint pid; if (c.GetProcessId(out pid) != 0 || pid == 0) continue;
                    string name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
                    if (string.Equals(name, process, StringComparison.OrdinalIgnoreCase)) list.Add((IChannelAudioVolume)c);
                } catch { }
            }
        } catch { }
        return list;
    }
    // 0..1, or -1 when the app has no sound session (closed, or has not played anything yet).
    public static float Get(string process) {
        foreach (var v in Find(process)) { float f; if (v.GetChannelVolume(0, out f) == 0) return f; }
        return -1;
    }
    public static void Set(string process, float value) {
        var g = Guid.Empty; value = Math.Max(0f, Math.Min(1f, value));
        foreach (var v in Find(process)) { uint n; if (v.GetChannelCount(out n) != 0) continue; for (uint i = 0; i < n; i++) v.SetChannelVolume(i, value, ref g); }
    }
}
// Bridge to Spotify's own volume slider: the widget-volume.js Spicetify extension inside Spotify asks
// http://localhost:47123/spotify-volume?cur=<its volume> a few times a second and gets back the volume the
// widget wants ({"set":0.42}) or nothing ({"set":null}). A background thread answers; the widget reads and
// writes the static fields.
public static class SpwBridge {
    public static volatile float AppVolume = -1;       // Spotify's slider, 0..1, as last reported
    public static volatile int Liked = -1;             // the playing song is in Liked Songs: 1 yes, 0 no, -1 unknown
    static volatile bool toggleHeart;
    public static void ToggleHeart() { toggleHeart = true; }
    static long lastSeen;                              // DateTime ticks of the last report
    static readonly object gate = new object();
    static float pending = float.NaN;
    public static bool Connected { get { return DateTime.UtcNow.Ticks - System.Threading.Interlocked.Read(ref lastSeen) < TimeSpan.FromSeconds(2).Ticks; } }
    public static void Request(float v) { lock (gate) pending = Math.Max(0f, Math.Min(1f, v)); }
    public static string Error;
    public static void Start(int port) {
        var t = new System.Threading.Thread(() => {
            try {
                var l = new System.Net.HttpListener();
                l.Prefixes.Add("http://localhost:" + port + "/");
                l.Start();
                while (true) {
                    var ctx = l.GetContext();
                    try {
                        var res = ctx.Response;
                        res.AddHeader("Access-Control-Allow-Origin", "*");
                        res.AddHeader("Access-Control-Allow-Private-Network", "true");
                        res.AddHeader("Access-Control-Allow-Headers", "*");
                        res.AddHeader("Cache-Control", "no-store");
                        string body = "";
                        if (ctx.Request.HttpMethod != "OPTIONS") {
                            float cur;
                            if (float.TryParse(ctx.Request.QueryString["cur"], System.Globalization.NumberStyles.Float,
                                               System.Globalization.CultureInfo.InvariantCulture, out cur)) {
                                AppVolume = cur; System.Threading.Interlocked.Exchange(ref lastSeen, DateTime.UtcNow.Ticks);
                            }
                            string liked = ctx.Request.QueryString["liked"];
                            Liked = liked == "1" ? 1 : liked == "0" ? 0 : -1;
                            float p; lock (gate) { p = pending; pending = float.NaN; }
                            bool heart = toggleHeart; toggleHeart = false;
                            body = "{\"set\":" + (float.IsNaN(p) ? "null" : p.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture))
                                 + ",\"toggleHeart\":" + (heart ? "true" : "false") + "}";
                            res.ContentType = "application/json";
                        }
                        var bytes = System.Text.Encoding.UTF8.GetBytes(body);
                        res.ContentLength64 = bytes.Length; res.OutputStream.Write(bytes, 0, bytes.Length); res.Close();
                    } catch { }
                }
            } catch (Exception e) { Error = e.Message; }
        });
        t.IsBackground = true; t.Start();
    }
}
'@

# --- Windows media controls (WinRT) ---------------------------------------------------------------
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$MgrT   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$PropsT = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$StrmT  = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]
$null = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$AsStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [type[]]@([Windows.Storage.Streams.IInputStream]))
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [type]$type, [int]$ms = 1500) {
    $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    if ($t.Wait($ms)) { $t.Result } else { $null }
}

$script:mgr = $null
$script:session = $null
function Get-Player {
    if (-not $script:mgr) { $script:mgr = Await ($MgrT::RequestAsync()) $MgrT 3000 }
    if (-not $script:mgr) { return $null }
    foreach ($s in $script:mgr.GetSessions()) { if ($s.SourceAppUserModelId -match $Source) { return $s } }
    $null
}

function Get-Art($props) {
    if (-not $props -or -not $props.Thumbnail) { return $null }
    $ras = Await ($props.Thumbnail.OpenReadAsync()) $StrmT 2000
    if (-not $ras) { return $null }
    $ms = New-Object System.IO.MemoryStream
    try {
        # Called through reflection: PowerShell cannot hand a WinRT stream to this .NET method directly.
        $net = $AsStreamForRead.Invoke($null, @($ras.psobject.BaseObject))
        $net.CopyTo($ms); $net.Dispose()
        if ($ms.Length -eq 0) { return $null }
        $ms.Position = 0
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $ms; $bmp.EndInit(); $bmp.Freeze()
        [SpwDesk]::Trim($bmp)
    } finally { $ms.Dispose(); try { ([IDisposable]$ras).Dispose() } catch {} }
}

# --- Wooden frame: the same pixel-art frame as the Pixel Agents office (~\.pixel-agents\frame-widget.ps1) ---
# The card's content (440x136) sits in the frame's see-through opening; the window is the frame's size.
$Band = 32        # wood thickness
$PlateH = 26      # name plate height
function New-WoodFrame([int]$Width, [int]$Height, [string]$Name) {
    $B = $Band
    $W = $Width + 2 * $B
    $H = $Height + 2 * $B + [int]($PlateH / 2)
    $fh = $Height + 2 * $B   # frame outer height (the shadow hangs a little lower)
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $bmp.SetResolution(96, 96)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'None'; $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'
    $g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    function Fill($hex, $x, $y, $w, $h) {
        $br = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
        $g.FillRectangle($br, $x, $y, $w, $h); $br.Dispose()
    }
    # soft drop shadow
    Fill '#140c08' 4 6 $W ($fh - 2)
    # outer outline + wood
    Fill '#24140a' 0 0 ($W - 4) ($fh - 4)
    Fill '#6e4022' 2 2 ($W - 8) ($fh - 8)
    # wood grain: pixel stripes along each side, one row per 5 px of band
    $grain = @('#7d4a28', '#5f361c', '#86522d')
    $rows = [int][Math]::Floor(($B - 7) / 5)
    for ($i = 0; $i -lt $rows; $i++) {
        $o = 5 + $i * 5; $gc = $grain[$i % 3]
        for ($x = 6 + $i * 13; $x -lt $W - 12; $x += 37) { Fill $gc $x $o 14 2; Fill $gc ($x + 9) ($fh - 9 - $o) 14 2 }
        for ($y = 8 + $i * 11; $y -lt $fh - 12; $y += 31) { Fill $gc $o $y 2 12; Fill $gc ($W - 9 - $o) ($y + 7) 2 12 }
    }
    # bevel: light top/left, dark bottom/right
    Fill '#a8703f' 2 2 ($W - 8) 3; Fill '#a8703f' 2 2 3 ($fh - 8)
    Fill '#43250f' 2 ($fh - 9) ($W - 8) 3; Fill '#43250f' ($W - 9) 2 3 ($fh - 8)
    # gold inner trim around the opening
    $ix = $B - 6; $iy = $B - 6; $iw = $Width + 12; $ih = $Height + 12
    Fill '#3a2410' ($ix - 1) ($iy - 1) ($iw + 2) ($ih + 2)
    Fill '#c9963c' $ix $iy $iw $ih
    Fill '#f3d27a' $ix $iy $iw 2; Fill '#f3d27a' $ix $iy 2 $ih
    Fill '#8a6022' $ix ($iy + $ih - 2) $iw 2; Fill '#8a6022' ($ix + $iw - 2) $iy 2 $ih
    # thin dark edge, then the see-through opening where the card's content goes
    Fill '#1b120a' ($B - 2) ($B - 2) ($Width + 4) ($Height + 4)
    $g.CompositingMode = 'SourceCopy'
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 0, 0, 0))), $B, $B, $Width, $Height)
    $g.CompositingMode = 'SourceOver'
    # corner studs, in the middle of the wood
    $s = [int](($B - 4) / 2) - 2
    foreach ($c in @(@($s, $s), @(($W - $s - 8), $s), @($s, ($fh - $s - 8)), @(($W - $s - 8), ($fh - $s - 8)))) {
        Fill '#3a2410' $c[0] $c[1] 6 6; Fill '#e8c060' ($c[0] + 1) ($c[1] + 1) 4 4; Fill '#fff0b0' ($c[0] + 1) ($c[1] + 1) 2 2
    }
    # name plate, centered on the bottom band
    $font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $g.TextRenderingHint = 'SingleBitPerPixelGridFit'
    $tw = [int]($g.MeasureString($Name, $font).Width) + 22
    $px = [int](($W - 4 - $tw) / 2); $py = $fh - $B - 2 + [Math]::Max(0, [int](($B - 22) / 2))
    Fill '#24140a' ($px - 1) ($py - 1) ($tw + 2) ($PlateH + 2)
    Fill '#d6a646' $px $py $tw $PlateH
    Fill '#f6dc8c' $px $py $tw 2; Fill '#8f6424' $px ($py + $PlateH - 2) $tw 2
    Fill '#5a3a14' ($px + 4) ($py + 11) 2 2; Fill '#5a3a14' ($px + $tw - 6) ($py + 11) 2 2
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $tb = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#3b2208'))
    $g.DrawString($Name, $font, $tb, (New-Object System.Drawing.RectangleF ($px + 1), ($py + 1), $tw, $PlateH), $sf)
    $tb.Dispose(); $font.Dispose(); $g.Dispose()

    # Hand it to WPF as a frozen picture (through PNG, which keeps the see-through parts).
    $ms = New-Object System.IO.MemoryStream
    try {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $ms.Position = 0
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.CacheOption = 'OnLoad'; $img.StreamSource = $ms; $img.EndInit(); $img.Freeze()
        $img
    } finally { $ms.Dispose() }
}

# --- The card ---------------------------------------------------------------------------------------
# Two looks share everything inside the card (cover, text, buttons, progress); only the outside differs:
#   glass: a 440x136 dark glass card with rounded corners and a "● SPOTIFY" badge
#   wood:  the same content in the pixel-art wooden frame (New-WoodFrame) with a "SPOTIFY" name plate;
#          the window is 440x136 + 32 px of wood on every side + half a plate below = 504 x 213
$Wood = $Style -eq 'wood'
$WinW = if ($Wood) { 504 } else { 440 }
$WinH = if ($Wood) { 213 } else { 136 }

if ($Wood) {
    $IconBtnLook = @{ Radius = 3; Hover = '#38F3D27A'; Press = '#60F3D27A' }
    $PlayBtnStyle = @'
    <Style x:Key="PlayBtn" TargetType="Button" BasedOn="{StaticResource IconBtn}">
      <Setter Property="Foreground" Value="#FF3B2208"/>
      <Setter Property="Width" Value="38"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <!-- a gold button like the name plate: dark outline, light top edge, dark bottom edge -->
            <Border x:Name="B" Background="#FFD6A646" BorderBrush="#FF24140A" BorderThickness="1" CornerRadius="2">
              <Grid>
                <Border Height="2" VerticalAlignment="Top" Background="#FFF6DC8C"/>
                <Border Height="2" VerticalAlignment="Bottom" Background="#FF8F6424"/>
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#FFE6BA5C"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#FFB88A34"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@
    # the wooden frame; the panel fills its see-through opening
    $CardOpen = @'
    <Image x:Name="WoodFrame" Stretch="None" HorizontalAlignment="Left" VerticalAlignment="Top"
           RenderOptions.BitmapScalingMode="NearestNeighbor"/>
    <Grid x:Name="Panel" Margin="32,32,32,45" ClipToBounds="True">
    <Border Background="#FF181009"/>
'@
    $BgArtOpacity = '0.45'; $ArtRadius = 2; $TitleRight = 16
    # green while playing, grey otherwise; the name is on the plate
    $CardClose = @'
    <Rectangle x:Name="Dot" Width="6" Height="6" Fill="#1DB954" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,12,12,0"/>
    </Grid>
'@
} else {
    $IconBtnLook = @{ Radius = 17; Hover = '#26FFFFFF'; Press = '#45FFFFFF' }
    $PlayBtnStyle = @'
    <Style x:Key="PlayBtn" TargetType="Button" BasedOn="{StaticResource IconBtn}">
      <Setter Property="Foreground" Value="#FF101214"/>
      <Setter Property="Width" Value="38"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="#F2FFFFFF" CornerRadius="19">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#FFFFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#FFD0D0D0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@
    $CardOpen = @'
    <Grid.Clip><RectangleGeometry Rect="0,0,440,136" RadiusX="18" RadiusY="18"/></Grid.Clip>
    <Grid x:Name="Panel">
    <Border Background="#FF121517"/>
'@
    $BgArtOpacity = '0.6'; $ArtRadius = 10; $TitleRight = 62
    $CardClose = @'
    <Border CornerRadius="18" BorderBrush="#2EFFFFFF" BorderThickness="1"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,14,16,0">
      <Ellipse x:Name="Dot" Width="7" Height="7" Fill="#1DB954" VerticalAlignment="Center"/>
      <TextBlock Text="SPOTIFY" FontSize="9.5" FontWeight="Bold" Foreground="#8CFFFFFF" Margin="5,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
    </Grid>
'@
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Spotify Widget" Width="$WinW" Height="$WinH"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" ShowActivated="False" Topmost="False"
        FontFamily="Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="IconBtn" TargetType="ButtonBase">
      <Setter Property="Foreground" Value="#E6FFFFFF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ButtonBase">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="$($IconBtnLook.Radius)">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="$($IconBtnLook.Hover)"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="$($IconBtnLook.Press)"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
$PlayBtnStyle
    <Style x:Key="SmallBtn" TargetType="ButtonBase" BasedOn="{StaticResource IconBtn}">
      <Setter Property="Width" Value="28"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#B8FFFFFF"/>
    </Style>
    <Style x:Key="ArtBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button"><ContentPresenter/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root" Background="Transparent">
$CardOpen
    <Image x:Name="BgArt" Stretch="UniformToFill" Opacity="$BgArtOpacity" Margin="-60">
      <Image.CacheMode><BitmapCache/></Image.CacheMode>
      <Image.Effect><BlurEffect Radius="70" KernelType="Gaussian"/></Image.Effect>
    </Image>
    <Border>
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#33000000" Offset="0"/>
          <GradientStop Color="#99000000" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
    </Border>

    <Grid Margin="14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="108"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Button x:Name="ArtBtn" Style="{StaticResource ArtBtn}">
        <Grid Width="108" Height="108">
          <Border x:Name="ArtBox" CornerRadius="$ArtRadius" Background="#1FFFFFFF">
            <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.45"/></Border.Effect>
          </Border>
          <TextBlock x:Name="ArtGlyph" Text="&#xE8D6;" FontFamily="Segoe MDL2 Assets" FontSize="36"
                     Foreground="#80FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
      </Button>

      <Grid Grid.Column="1" Margin="16,0,0,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="TitleText" FontSize="17" FontWeight="SemiBold" Foreground="White"
                   TextTrimming="CharacterEllipsis" Margin="0,0,$TitleRight,0"/>
        <TextBlock x:Name="ArtistText" Grid.Row="1" FontSize="13" Foreground="#B8FFFFFF"
                   TextTrimming="CharacterEllipsis" Margin="0,1,28,0"/>
        <!-- add the playing song to Liked Songs / take it out (needs the Spicetify extension) -->
        <Button x:Name="HeartBtn" Grid.Row="1" Style="{StaticResource SmallBtn}" Content="&#xE006;" FontSize="13"
                Width="26" Height="24" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,-4,0"/>

        <!-- shuffle, previous, play/pause, next, repeat; shuffle and repeat are dimmed when the player does not allow them -->
        <Grid Grid.Row="3" Margin="-7,0,0,0">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Button x:Name="ShuffleBtn" Style="{StaticResource SmallBtn}" Content="&#xE8B1;" Margin="0,0,3,0"/>
            <Button x:Name="PrevBtn" Style="{StaticResource IconBtn}" Content="&#xE892;"/>
            <Button x:Name="PlayBtn" Style="{StaticResource PlayBtn}" Margin="5,0">
              <TextBlock x:Name="PlayGlyph" Text="&#xE768;" Margin="1,0,0,0"/>
            </Button>
            <Button x:Name="NextBtn" Style="{StaticResource IconBtn}" Content="&#xE893;"/>
            <Button x:Name="RepeatBtn" Style="{StaticResource SmallBtn}" Content="&#xE8EE;" Margin="3,0,0,0"/>
          </StackPanel>
          <!-- Spotify's volume in 10 % steps: - and + (hold to repeat), a click left/right of the bar's end, the mouse wheel -->
          <StackPanel x:Name="VolBox" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <RepeatButton x:Name="VolDownBtn" Style="{StaticResource SmallBtn}" Content="&#xE738;" FontSize="10" Width="22" Delay="450" Interval="300"/>
            <Grid x:Name="VolArea" Width="60" Background="Transparent" Cursor="Hand" VerticalAlignment="Center">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/></Grid.RowDefinitions>
              <!-- the level as a number; hidden: the 10 blocks show it (kept for screen readers and tests) -->
              <TextBlock x:Name="VolText" FontSize="11.5" FontWeight="SemiBold" Foreground="#F2FFFFFF" HorizontalAlignment="Center" Margin="0,0,0,1" Visibility="Collapsed"/>
              <!-- 10 blocks, one per 10 %: lit up to the volume -->
              <UniformGrid x:Name="VolTrack" Grid.Row="1" Rows="1" Columns="10" Height="6" VerticalAlignment="Center"/>
            </Grid>
            <RepeatButton x:Name="VolUpBtn" Style="{StaticResource SmallBtn}" Content="&#xE710;" FontSize="10" Width="22" Delay="450" Interval="300"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="4" Margin="0,5,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="PosText" FontSize="10.5" Foreground="#A0FFFFFF" MinWidth="28" VerticalAlignment="Center"/>
          <!-- click anywhere on the bar to jump there (when the player allows it) -->
          <Grid x:Name="SeekArea" Grid.Column="1" Height="14" Margin="6,0" Background="Transparent" VerticalAlignment="Center">
            <Grid x:Name="Track" Height="4" VerticalAlignment="Center">
              <Border Background="#33FFFFFF" CornerRadius="2"/>
              <Border x:Name="Fill" Background="#1DB954" CornerRadius="2" HorizontalAlignment="Left" Width="0"/>
            </Grid>
          </Grid>
          <TextBlock x:Name="EndText" Grid.Column="2" FontSize="10.5" Foreground="#A0FFFFFF" MinWidth="28" TextAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
      </Grid>
    </Grid>

$CardClose
  </Grid>
</Window>
"@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'Root', 'WoodFrame', 'Panel', 'BgArt', 'ArtBtn', 'ArtBox', 'ArtGlyph', 'TitleText', 'ArtistText', 'PrevBtn', 'PlayBtn', 'PlayGlyph',
               'NextBtn', 'ShuffleBtn', 'RepeatBtn', 'SeekArea', 'HeartBtn', 'VolBox', 'VolDownBtn', 'VolUpBtn', 'VolArea', 'VolText', 'VolTrack',
               'PosText', 'Track', 'Fill', 'EndText', 'Dot') {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

if ($Wood) { $WoodFrame.Source = New-WoodFrame 440 136 'SPOTIFY' }

$GlyphPlay  = [string][char]0xE768
$GlyphPause = [string][char]0xE769
$GlyphRepeatAll = [string][char]0xE8EE
$GlyphRepeatOne = [string][char]0xE8ED
$bc = [System.Windows.Media.BrushConverter]::new()
$Green = $bc.ConvertFromString('#1DB954')
$Grey  = $bc.ConvertFromString('#80FFFFFF')
$Dim   = $bc.ConvertFromString('#B8FFFFFF')
$ArtEmpty = $ArtBox.Background
# The repeat-mode type (None / Track / List), taken from the method that wants it.
$RepeatT = [Windows.Media.Control.GlobalSystemMediaTransportControlsSession].GetMethod('TryChangeAutoRepeatModeAsync').GetParameters()[0].ParameterType

$state = @{ key = $null; artKey = $null; artRetry = 0; playing = $false; pos = 0.0; end = 0.0; start = 0.0
            at = [DateTimeOffset]::Now; tick = 0; force = $true; idle = $null
            shuffle = $false; repeat = 'None'; canSeek = $false; displayAt = $null; playAfterOpen = $null; vol = -1; volTarget = $null; channelReset = $false; liked = $false; heartHold = $null }

# Shuffle / repeat buttons: always shown, dimmed while the player does not allow them, green when on.
function Set-ModeButtons([bool]$canShuffle, [bool]$canRepeat) {
    $ShuffleBtn.IsEnabled = $canShuffle
    $RepeatBtn.IsEnabled  = $canRepeat
    $ShuffleBtn.Foreground = if ($state.shuffle) { $Green } else { $Dim }
    $RepeatBtn.Content     = if ($state.repeat -eq 'Track') { $GlyphRepeatOne } else { $GlyphRepeatAll }
    $RepeatBtn.Foreground  = if ($state.repeat -eq 'Track' -or $state.repeat -eq 'List') { $Green } else { $Dim }
}

function Format-Time([double]$s) { if ($s -lt 0) { $s = 0 }; $t = [TimeSpan]::FromSeconds([math]::Floor($s)); if ($t.TotalHours -ge 1) { $t.ToString('h\:mm\:ss') } else { '{0}:{1:00}' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds } }

function Set-Art($bmp) {
    if ($bmp) {
        $b = New-Object System.Windows.Media.ImageBrush $bmp
        $b.Stretch = 'UniformToFill'
        $ArtBox.Background = $b; $ArtGlyph.Visibility = 'Collapsed'; $BgArt.Source = $bmp
    } else {
        $ArtBox.Background = $ArtEmpty; $ArtGlyph.Visibility = 'Visible'; $BgArt.Source = $null
    }
}

# $why: 'closed' = Spotify is not running; 'empty' = it runs but has no song loaded yet (just started), and then
# only Spotify itself can start the music: Windows' play command does nothing until a song is picked there.
function Show-Idle([string]$why = 'closed') {
    if ($state.idle -eq $true -and $state.idleWhy -eq $why) { return }
    $state.idleWhy = $why
    $state.idle = $true; $state.key = $null; $state.artKey = $null; $state.playing = $false; $state.end = 0
    Set-Art $null
    $TitleText.Text = 'Spotify не грає'
    $ArtistText.Text = if ($why -eq 'empty') { 'Обери пісню в Spotify' }
                       elseif ($state.playAfterOpen) { 'Запускаю Spotify…' } else { 'Натисни ▶, щоб увімкнути' }
    $PlayGlyph.Text = $GlyphPlay
    $PrevBtn.IsEnabled = $false; $NextBtn.IsEnabled = $false
    $PosText.Text = ''; $EndText.Text = ''; $Fill.Width = 0
    $Dot.Fill = $Grey
    $state.canSeek = $false; $SeekArea.Cursor = $null
    Set-ModeButtons $false $false
    $Panel.Opacity = 0.8   # only the content dims; the wood stays as it is
}

function Refresh {
    $s = Get-Player
    $script:session = $s
    # ▶ was pressed while Spotify was closed: once it shows up in the media controls, start the music.
    if ($state.playAfterOpen) {
        if ([DateTime]::Now -gt $state.playAfterOpen) { $state.playAfterOpen = $null; $state.idle = $null }
        elseif ($s -and "$($s.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing') { $state.playAfterOpen = $null }
        elseif ($s -and $s.GetPlaybackInfo().Controls.IsPlayEnabled) {
            if (Await ($s.TryPlayAsync()) ([bool]) 1500) { $state.playAfterOpen = $null; Log 'started Spotify and its music' }
        }
    }
    if (-not $s) { Show-Idle 'closed'; return }

    $props = Await ($s.TryGetMediaPropertiesAsync()) $PropsT 1500
    if (-not $props -or [string]::IsNullOrWhiteSpace($props.Title)) { Show-Idle 'empty'; return }
    if ($state.idle -ne $false) {
        $state.idle = $false
        $PrevBtn.IsEnabled = $true; $NextBtn.IsEnabled = $true; $Panel.Opacity = 1
    }

    $key = '{0}|{1}|{2}' -f $props.Title, $props.Artist, $props.AlbumTitle
    if ($key -ne $state.key) {
        $state.key = $key
        $TitleText.Text = $props.Title
        $ArtistText.Text = if ($props.Artist) { $props.Artist } else { $props.AlbumTitle }
        $state.artKey = $null; $state.artRetry = 0
    }
    # The cover often arrives a moment after the title: load it now and once more a few seconds later.
    if ($state.artKey -ne $key -or $state.artRetry -eq 4) {
        $bmp = Get-Art $props
        if ($bmp) { Set-Art $bmp; $state.artKey = $key } elseif ($state.artRetry -gt 10) { Set-Art $null; $state.artKey = $key }
    }
    $state.artRetry++

    $pb = $s.GetPlaybackInfo()
    $playing = "$($pb.PlaybackStatus)" -eq 'Playing'
    $state.playing = $playing
    $c = $pb.Controls
    $state.shuffle = [bool]$pb.IsShuffleActive
    $state.repeat = if ($null -ne $pb.AutoRepeatMode) { "$($pb.AutoRepeatMode)" } else { 'None' }
    Set-ModeButtons ([bool]$c.IsShuffleEnabled) ([bool]$c.IsRepeatEnabled)
    $state.canSeek = [bool]$c.IsPlaybackPositionEnabled
    $SeekArea.Cursor = if ($state.canSeek) { [System.Windows.Input.Cursors]::Hand } else { $null }
    $PlayGlyph.Text = if ($playing) { $GlyphPause } else { $GlyphPlay }
    $PlayGlyph.Margin = if ($playing) { [System.Windows.Thickness]::new(0) } else { [System.Windows.Thickness]::new(1, 0, 0, 0) }
    $Dot.Fill = if ($playing) { $Green } else { $Grey }

    $tl = $s.GetTimelineProperties()
    $state.start = $tl.StartTime.TotalSeconds
    $state.end = ($tl.EndTime - $tl.StartTime).TotalSeconds
    $state.pos = ($tl.Position - $tl.StartTime).TotalSeconds
    $state.at = $tl.LastUpdatedTime
    if ($state.at.Year -lt 2000) { $state.at = [DateTimeOffset]::Now }
}

# Spotify's volume, in 10 % steps. With the widget-volume.js Spicetify extension in Spotify (SpwBridge) it is
# Spotify's own slider, both ways; without it, the volume of Spotify's sound in Windows (SpwVol).
# A step glides there (a 30 ms timer walks it), it never jumps.
function Get-SpotifyVolume {
    if ([SpwBridge]::Connected) {
        # The slider does all the work now: undo any lowering done through Windows before the extension was there.
        if (-not $state.channelReset) { if ([SpwVol]::Get('Spotify') -lt 0.999) { [SpwVol]::Set('Spotify', 1) }; $state.channelReset = $true }
        return [SpwBridge]::AppVolume
    }
    $state.channelReset = $false
    [SpwVol]::Get('Spotify')
}
function Set-SpotifyVolume([double]$v) {
    if ([SpwBridge]::Connected) { [SpwBridge]::Request([single]$v) } else { [SpwVol]::Set('Spotify', [single]$v) }
}
$VolOn  = $bc.ConvertFromString('#F2FFFFFF')
$VolOff = $bc.ConvertFromString('#2EFFFFFF')
$VolSegs = foreach ($i in 0..9) {
    $b = New-Object System.Windows.Controls.Border
    $b.Margin = [System.Windows.Thickness]::new(0.5, 0, 0.5, 0); $b.CornerRadius = [System.Windows.CornerRadius]::new(1); $b.Background = $VolOff
    $null = $VolTrack.Children.Add($b); $b
}
function Show-Volume([double]$v) {
    $v = [math]::Max(0.0, [math]::Min(1.0, $v))
    $VolText.Text = '{0}' -f [int][math]::Round($v * 100)
    $lit = [int][math]::Round($v * 10)
    for ($i = 0; $i -lt 10; $i++) { $VolSegs[$i].Background = if ($i -lt $lit) { $VolOn } else { $VolOff } }
}
function Update-Volume {
    if ($null -ne $state.volTarget) { return }   # mid-step: the glide timer draws it
    # Just after a step Spotify still reports the old level for a moment: trust our own value for 1 s.
    if ($state.volHold -and [DateTime]::Now -lt $state.volHold) { return }
    $v = Get-SpotifyVolume
    $state.vol = $v
    if ($v -lt 0) { $VolBox.Opacity = 0.35; foreach ($b in $VolSegs) { $b.Background = $VolOff }; $VolText.Text = ''; return }
    $VolBox.Opacity = 1
    Show-Volume $v
}
# Heart: shows whether the playing song is in Liked Songs (green, filled) and adds / removes it. Only with the
# Spicetify extension; without it the heart stays dimmed.
$GlyphHeart     = [string][char]0xE006
$GlyphHeartFull = [string][char]0xE00B
function Update-Heart {
    if ($state.heartHold -and [DateTime]::Now -lt $state.heartHold) { return }   # just clicked: Spotify catches up
    $liked = if ([SpwBridge]::Connected -and -not $state.idle) { [SpwBridge]::Liked } else { -1 }
    $HeartBtn.IsEnabled = $liked -ge 0
    Show-Heart ($liked -eq 1)
}
function Show-Heart([bool]$on) {
    $HeartBtn.Content = if ($on) { $GlyphHeartFull } else { $GlyphHeart }
    $HeartBtn.Foreground = if ($on) { $Green } else { $Dim }
    $HeartBtn.ToolTip = if ($on) { 'В улюблених: натисни, щоб прибрати' } else { 'Додати в улюблені' }
    $state.liked = $on
}

# One 10 % step up (+1) or down (-1), from where the volume is heading, onto the 10 % grid (47 % -> 50 % / 40 %).
function Step-Volume([int]$dir) {
    if ($state.vol -lt 0) { return }
    $from = if ($null -ne $state.volTarget) { $state.volTarget } else { $state.vol }
    $to = if ($dir -gt 0) { [math]::Floor($from * 10 + 0.001) + 1 } else { [math]::Ceiling($from * 10 - 0.001) - 1 }
    $state.volTarget = [math]::Max(0.0, [math]::Min(1.0, $to / 10))
    if (-not $volTimer.IsEnabled) { $volTimer.Start() }
}
$volTimer = New-Object System.Windows.Threading.DispatcherTimer
$volTimer.Interval = [TimeSpan]::FromMilliseconds(30)
$volTimer.Add_Tick({
    try {
        if ($null -eq $state.volTarget) { $volTimer.Stop(); return }
        $d = $state.volTarget - $state.vol
        $step = 0.015   # 1.5 % per tick: one 10 % step takes about 0.2 s
        $state.vol = if ([math]::Abs($d) -le $step) { $state.volTarget } else { $state.vol + $step * [math]::Sign($d) }
        Set-SpotifyVolume $state.vol
        Show-Volume $state.vol
        if ($state.vol -eq $state.volTarget) { $state.volTarget = $null; $state.volHold = [DateTime]::Now.AddSeconds(1); $volTimer.Stop() }
    } catch { Log "volume: $_"; $state.volTarget = $null; $volTimer.Stop() }
})
function Update-Progress {
    if ($state.idle -or $state.end -le 0) { $PosText.Text = ''; $EndText.Text = ''; $Fill.Width = 0; return }
    $pos = $state.pos
    if ($state.playing) { $pos += ([DateTimeOffset]::Now - $state.at).TotalSeconds }
    $pos = [math]::Max(0.0, [math]::Min($pos, $state.end))
    $PosText.Text = Format-Time $pos
    $EndText.Text = Format-Time $state.end
    $w = $Track.ActualWidth
    if ($w -gt 0) { $Fill.Width = [math]::Max(4.0, $w * $pos / $state.end) }
}

# --- Controls -----------------------------------------------------------------------------------
# Starts the Spotify app: the one already running, the usual desktop install (%APPDATA%\Spotify), the Microsoft Store
# version, or whatever handles spotify: links. (spotify: alone fails on computers where nothing registered it.)
function Find-SpotifyExe {
    $p = Get-Process -Name Spotify -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { return $p.Path }
    foreach ($c in (Join-Path $env:APPDATA 'Spotify\Spotify.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Spotify.exe')) {
        if (Test-Path $c) { return $c }
    }
    $null
}
# -Play: start the music too, as soon as Spotify is up (Refresh does it; it gives up after 30 s).
function Open-Spotify([switch]$Play) {
    try {
        $exe = Find-SpotifyExe
        if ($exe) { Start-Process -FilePath $exe }
        else {
            $pkg = Get-AppxPackage -Name 'SpotifyAB.SpotifyMusic' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pkg) { Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!Spotify" } else { Start-Process 'spotify:' }
        }
        if ($Play) { $state.playAfterOpen = [DateTime]::Now.AddSeconds(30); $state.idle = $null }   # idle -> redrawn with "starting"
    } catch {
        Log "open spotify: $_"
        $state.playAfterOpen = $null
        $ArtistText.Text = 'Spotify не знайдено на цьому комп''ютері'   # stays: Show-Idle redraws only after a change
    }
    $state.force = $true
}

$PrevBtn.Add_Click({ if ($script:session) { $null = $script:session.TrySkipPreviousAsync() }; $state.force = $true })
$NextBtn.Add_Click({ if ($script:session) { $null = $script:session.TrySkipNextAsync() }; $state.force = $true })
$PlayBtn.Add_Click({
    if ($script:session -and -not $state.idle) {
        $null = $script:session.TryTogglePlayPauseAsync()
        $state.playing = -not $state.playing   # flip right away, the next refresh confirms it
        $PlayGlyph.Text = if ($state.playing) { $GlyphPause } else { $GlyphPlay }
        if (-not $state.playing) { $state.pos += ([DateTimeOffset]::Now - $state.at).TotalSeconds }
        $state.at = [DateTimeOffset]::Now
    } elseif ($script:session) {
        # Spotify runs with no song loaded: try to play, and bring its window up to pick a song there.
        $null = $script:session.TryPlayAsync()
        Open-Spotify
    } else { Open-Spotify -Play }
    $state.force = $true
})
$ArtBtn.Add_Click({ Open-Spotify })

$ShuffleBtn.Add_Click({
    if (-not $script:session) { return }
    $state.shuffle = -not $state.shuffle
    $null = $script:session.TryChangeShuffleActiveAsync($state.shuffle)
    Set-ModeButtons $true $RepeatBtn.IsEnabled
    $state.force = $true
})
# Repeat cycles: off -> whole list -> this track -> off.
$RepeatBtn.Add_Click({
    if (-not $script:session) { return }
    $state.repeat = switch ($state.repeat) { 'List' { 'Track' } 'Track' { 'None' } default { 'List' } }
    $null = $script:session.TryChangeAutoRepeatModeAsync([Enum]::Parse($RepeatT, $state.repeat))
    Set-ModeButtons $ShuffleBtn.IsEnabled $true
    $state.force = $true
})

# Click on the progress bar to jump to that spot.
$HeartBtn.Add_Click({
    [SpwBridge]::ToggleHeart()
    Show-Heart (-not $state.liked)                       # show it right away
    $state.heartHold = [DateTime]::Now.AddSeconds(1.5)
})
$VolDownBtn.Add_Click({ Step-Volume -1 })
$VolUpBtn.Add_Click({ Step-Volume 1 })
# A click on the bar: one step towards the click (on the lit blocks: quieter, on the dark ones: louder).
$VolArea.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true   # the card does not start moving
    if ($state.vol -lt 0) { return }
    Step-Volume $(if ($e.GetPosition($VolTrack).X -lt $VolTrack.ActualWidth * $state.vol) { -1 } else { 1 })
})
# Mouse wheel anywhere over the card: one 10 % step per notch.
$Root.Add_MouseWheel({
    param($sender, $e)
    if ($state.vol -lt 0) { return }
    Step-Volume ([math]::Sign($e.Delta))
    $e.Handled = $true
})
$SeekArea.Add_MouseLeftButtonDown({
    param($sender, $e)
    if (-not ($script:session -and $state.canSeek -and $state.end -gt 0)) { return }   # not handled: the card drags instead
    $e.Handled = $true
    $f = [math]::Max(0.0, [math]::Min(1.0, $e.GetPosition($Track).X / [math]::Max(1.0, $Track.ActualWidth)))
    $null = $script:session.TryChangePlaybackPositionAsync([long](($state.start + $f * $state.end) * 1e7))
    $state.pos = $f * $state.end; $state.at = [DateTimeOffset]::Now
    Update-Progress
})

# Drag the card to move it; the new spot is saved.
$Root.Add_MouseLeftButtonDown({
    try {
        $win.DragMove()
        $r = [SpwDesk]::Rect($script:hwnd)
        $h = Read-Settings; $h['x'] = $r[0]; $h['y'] = $r[1]; Save-Settings $h
    } catch { Log "drag: $_" }
})

# --- Placement: on the wallpaper of the chosen monitor, centered, near the bottom ---------------
# Runs at start and again whenever monitors change: if the chosen monitor was off when the widget started,
# it sat on the other one, and moves back once the chosen monitor is on again.
function Place-Widget {
    if ($Snapshot) { [SpwDesk]::Move($script:hwnd, -4000, -4000); return }
    $scale = [System.Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformToDevice.M11
    $wPx = [int]($win.Width * $scale); $hPx = [int]($win.Height * $scale)

    $x = $null; $y = $null
    $saved = Read-Settings
    if ($null -ne $saved['x'] -and $null -ne $saved['y']) {
        $pt = New-Object System.Drawing.Point ([int]$saved['x'] + 20), ([int]$saved['y'] + 20)
        if (([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Contains($pt) })) { $x = [int]$saved['x']; $y = [int]$saved['y'] }
    }
    if ($null -eq $x) {
        $scr = [System.Windows.Forms.Screen]::PrimaryScreen
        if ($Monitor -eq 'secondary') {
            $o = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
            if ($o) { $scr = $o }
        }
        $wa = $scr.WorkingArea
        $x = $wa.X + [int](($wa.Width - $wPx) / 2)
        $y = $wa.Bottom - $hPx - $BottomMargin
    }
    $r = [SpwDesk]::Rect($script:hwnd)
    if ($r[0] -ne $x -or $r[1] -ne $y) {
        [SpwDesk]::Move($script:hwnd, $x, $y)
        Log "placed at $x,$y (scale $scale, source '$Source', $([System.Windows.Forms.Screen]::AllScreens.Count) monitor(s))"
    }
}
$win.Add_SourceInitialized({
    $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    [SpwDesk]::Pin($script:hwnd)
    Place-Widget
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({
    try {
        $state.tick++
        # A monitor came or went: wait 2 s for Windows to settle, then re-place the card.
        if ([SpwDesk]::DisplayChanged) { [SpwDesk]::DisplayChanged = $false; $state.displayAt = [DateTime]::Now.AddSeconds(2) }
        if ($state.displayAt -and [DateTime]::Now -ge $state.displayAt) { $state.displayAt = $null; Place-Widget }
        if ($state.force -or $state.tick % 2 -eq 0) { $state.force = $false; Refresh; Update-Volume; Update-Heart }
        # Stay right above the Pixel Agents office window, if it runs (see SpwDesk.KeepAbove).
        if (-not $Snapshot -and $state.tick % 2 -eq 1) {
            if (-not $script:office -or -not $script:officeCheck -or $state.tick -ge $script:officeCheck) {
                $script:office = [SpwDesk]::FindOffice(); $script:officeCheck = $state.tick + 20   # look again every 10 s
            }
            if ($script:office -ne [IntPtr]::Zero) { [SpwDesk]::KeepAbove($script:hwnd, $script:office) }
        }
        Update-Progress
    } catch {
        Log "tick: $_"
        $script:mgr = $null   # get a fresh media manager next time
    }
})

$win.Add_Closed({ $timer.Stop(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

# -Snapshot: draw the card into a PNG after 3 s, then quit.
if ($Snapshot) {
    $snap = New-Object System.Windows.Threading.DispatcherTimer
    $snap.Interval = [TimeSpan]::FromSeconds(3)
    $snap.Add_Tick({
        $snap.Stop()
        try {
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]$win.Width), ([int]$win.Height), 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($Root)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [System.IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
        } catch { Log "snapshot: $_" }
        $win.Close()
    })
    $snap.Start()
}

if (-not $Snapshot) { [SpwBridge]::Start(47123) }
Show-Idle
$win.Show()
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()
if ($mutex) { $mutex.ReleaseMutex() }
