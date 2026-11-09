# Spotify widget on the wallpaper: cover, track, artist, progress bar and previous / play-pause / next,
# in the same pixel-art wooden frame as the Pixel Agents office (with a "SPOTIFY" name plate).
# It reads what Spotify plays from Windows' own media controls (the same source as the volume pop-up),
# so it needs no Spotify login or API key. It sits on the desktop layer, under every window, like the
# Pixel Agents office, and never takes focus.
#   Drag the card to move it; the spot is remembered in settings.json next to this script.
#   Click the cover to open Spotify.
# Parameters:
#   -Monitor primary|secondary   where it goes the first time (until you drag it somewhere)
#   -BottomMargin                gap to the bottom edge of that monitor, in pixels
#   -Source                      regex matched against the player's app id; 'chrome' tests it with YouTube
#   -Reset                       forget the dragged position
#   -Snapshot <file.png>         render the card to a PNG after 3 s and exit, with every optional button shown
#                                (for checking the layout; runs beside the real widget, off screen)
param(
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
if ($Reset -and (Test-Path $settingsPath)) { Remove-Item $settingsPath -Force }

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

    static IntPtr Hook(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
        if (msg == 0x0046) {                       // WM_WINDOWPOSCHANGING: whatever moves us, we stay at the bottom
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
# Window = 440x136 content + 32 px of wood on every side + half a plate below: 504 x 213.
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Spotify Widget" Width="504" Height="213"
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
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="3">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#38F3D27A"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#60F3D27A"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
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
    <!-- the wooden frame (New-WoodFrame); the panel below fills its see-through opening -->
    <Image x:Name="Wood" Stretch="None" HorizontalAlignment="Left" VerticalAlignment="Top"
           RenderOptions.BitmapScalingMode="NearestNeighbor"/>
    <Grid x:Name="Panel" Margin="32,32,32,45" ClipToBounds="True">
    <Border Background="#F2181009"/>
    <Image x:Name="BgArt" Stretch="UniformToFill" Opacity="0.45" Margin="-60">
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
          <Border x:Name="ArtBox" CornerRadius="2" Background="#1FFFFFFF">
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
                   TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
        <TextBlock x:Name="ArtistText" Grid.Row="1" FontSize="13" Foreground="#B8FFFFFF"
                   TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>

        <!-- shuffle, previous, play/pause, next, repeat; shuffle and repeat are dimmed when the player does not allow them -->
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Button x:Name="ShuffleBtn" Style="{StaticResource SmallBtn}" Content="&#xE8B1;" Margin="0,0,8,0"/>
          <Button x:Name="PrevBtn" Style="{StaticResource IconBtn}" Content="&#xE892;"/>
          <Button x:Name="PlayBtn" Style="{StaticResource PlayBtn}" Margin="6,0">
            <TextBlock x:Name="PlayGlyph" Text="&#xE768;" Margin="1,0,0,0"/>
          </Button>
          <Button x:Name="NextBtn" Style="{StaticResource IconBtn}" Content="&#xE893;"/>
          <Button x:Name="RepeatBtn" Style="{StaticResource SmallBtn}" Content="&#xE8EE;" Margin="8,0,0,0"/>
        </StackPanel>

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

    <!-- green while playing, grey otherwise; the name is on the plate -->
    <Rectangle x:Name="Dot" Width="6" Height="6" Fill="#1DB954" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,12,12,0"/>
    </Grid>
  </Grid>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'Root', 'Wood', 'Panel', 'BgArt', 'ArtBtn', 'ArtBox', 'ArtGlyph', 'TitleText', 'ArtistText', 'PrevBtn', 'PlayBtn', 'PlayGlyph',
               'NextBtn', 'ShuffleBtn', 'RepeatBtn', 'SeekArea',
               'PosText', 'Track', 'Fill', 'EndText', 'Dot') {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

$Wood.Source = New-WoodFrame 440 136 'SPOTIFY'

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
            shuffle = $false; repeat = 'None'; canSeek = $false; displayAt = $null }

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

function Show-Idle {
    if ($state.idle -eq $true) { return }
    $state.idle = $true; $state.key = $null; $state.artKey = $null; $state.playing = $false; $state.end = 0
    Set-Art $null
    $TitleText.Text = 'Spotify не грає'
    $ArtistText.Text = 'Натисни ▶, щоб відкрити'
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
    if (-not $s) { Show-Idle; return }

    $props = Await ($s.TryGetMediaPropertiesAsync()) $PropsT 1500
    if (-not $props -or [string]::IsNullOrWhiteSpace($props.Title)) { Show-Idle; return }
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

function Update-Progress {
    if ($state.idle -or $state.end -le 0) { $PosText.Text = ''; $EndText.Text = ''; $Fill.Width = 0; return }
    $pos = $state.pos
    if ($state.playing) { $pos += ([DateTimeOffset]::Now - $state.at).TotalSeconds }
    $pos = [math]::Max(0, [math]::Min($pos, $state.end))
    $PosText.Text = Format-Time $pos
    $EndText.Text = Format-Time $state.end
    $w = $Track.ActualWidth
    if ($w -gt 0) { $Fill.Width = [math]::Max(4, $w * $pos / $state.end) }
}

# --- Controls -----------------------------------------------------------------------------------
function Open-Spotify { try { Start-Process 'spotify:' } catch { Log "open spotify: $_" } }

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
        $null = $script:session.TryTogglePlayPauseAsync()
    } else { Open-Spotify }
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
$SeekArea.Add_MouseLeftButtonDown({
    param($sender, $e)
    if (-not ($script:session -and $state.canSeek -and $state.end -gt 0)) { return }   # not handled: the card drags instead
    $e.Handled = $true
    $f = [math]::Max(0, [math]::Min(1, $e.GetPosition($Track).X / [math]::Max(1, $Track.ActualWidth)))
    $null = $script:session.TryChangePlaybackPositionAsync([long](($state.start + $f * $state.end) * 1e7))
    $state.pos = $f * $state.end; $state.at = [DateTimeOffset]::Now
    Update-Progress
})

# Drag the card to move it; the new spot is saved.
$Root.Add_MouseLeftButtonDown({
    try {
        $win.DragMove()
        $r = [SpwDesk]::Rect($script:hwnd)
        @{ x = $r[0]; y = $r[1] } | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8
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
    if (Test-Path $settingsPath) {
        try {
            $saved = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $pt = New-Object System.Drawing.Point ([int]$saved.x + 20), ([int]$saved.y + 20)
            if (([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Contains($pt) })) { $x = [int]$saved.x; $y = [int]$saved.y }
        } catch { Log "settings: $_" }
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
        if ($state.force -or $state.tick % 2 -eq 0) { $state.force = $false; Refresh }
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

Show-Idle
$win.Show()
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()
if ($mutex) { $mutex.ReleaseMutex() }
