# Peek's preview window on Windows: run by the hooks module (powershell -STA -File) when the pointer
# comes onto a path. It reads PEEK_FILE (the path), PEEK_SIZE (the picture's longest side, px),
# PEEK_LIFE (the most seconds it stays) and the words it shows (PEEK_HINT, PEEK_AGO, PEEK_PAGE,
# PEEK_PAGES, PEEK_ITEM, PEEK_ITEMS: from the environment so this file stays ASCII). It writes
# 'shown' once the window is up, or a line starting 'error', then a '.' every tenth of a second, and
# closes once nobody reads them. PEEK_RENDER=<png> draws the window to that file instead (layout check).
# The picture: a PDF's first page (Windows' PDF reader), else the Explorer's thumbnail (an image, a
# video's frame, a folder), else the file's icon.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$file = $env:PEEK_FILE
$largest = if ($env:PEEK_SIZE) { [int]$env:PEEK_SIZE } else { 320 }
$life = if ($env:PEEK_LIFE) { [int]$env:PEEK_LIFE } else { 60 }
if (-not (Test-Path -LiteralPath $file)) { [Console]::Out.WriteLine('error: not there'); exit 1 }
# The popup (shown without taking the focus, topmost, the pointer passing through) and the Explorer's
# thumbnail of any file, compiled once into the temp folder: compiling takes a second.
$assembly = Join-Path $env:TEMP 'maxx-peek-3.dll'
if (-not (Test-Path -LiteralPath $assembly)) {
  try {
  Add-Type -OutputAssembly $assembly -OutputType Library -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class MaxxPeekPopup : System.Windows.Forms.Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override System.Windows.Forms.CreateParams CreateParams {
    get { System.Windows.Forms.CreateParams p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80 | 0x8 | 0x20; return p; }
  }
}
public static class MaxxPeekThumb {
  [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr bitmap); }
  [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx; public int cy; }
  [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  static extern void SHCreateItemFromParsingName(string path, IntPtr bc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);
  [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, out BITMAP b);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
  // Thumbnail only (8) shows the content even where Explorer is set to icons only; 0 falls back to the icon.
  public static Bitmap Get(string path, int size, bool thumbnailOnly) {
    IShellItemImageFactory factory;
    try { SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out factory); } catch { return null; }
    IntPtr h;
    SIZE s; s.cx = size; s.cy = size;
    int hr = factory.GetImage(s, thumbnailOnly ? 8 : 0, out h);
    Marshal.ReleaseComObject(factory);
    if (hr != 0 || h == IntPtr.Zero) return null;
    try {
      Bitmap opaque = Image.FromHbitmap(h);
      BITMAP b;
      GetObject(h, Marshal.SizeOf(typeof(BITMAP)), out b);
      if (b.bmBitsPixel != 32 || b.bmBits == IntPtr.Zero) return opaque;
      int w = b.bmWidth, ht = Math.Abs(b.bmHeight), stride = b.bmWidthBytes;
      byte[] bits = new byte[stride * ht];
      Marshal.Copy(b.bmBits, bits, 0, bits.Length);
      bool anyAlpha = false;
      for (int i = 3; i < bits.Length; i += 4) { if (bits[i] != 0) { anyAlpha = true; break; } }
      if (!anyAlpha) return opaque;
      // The rows run top-down (thumbnails) or bottom-up (icons) depending on the source: the opaque
      // copy, which GDI turned the right way up, says which, sampled over the whole picture (an icon's
      // first and last rows are often both transparent). A tie is an icon.
      int same = 0, flipped = 0;
      for (int y = 0; y < ht; y += Math.Max(1, ht / 32)) {
        for (int x = 0; x < w; x += Math.Max(1, w / 32)) {
          Color seen = opaque.GetPixel(x, y);
          int a = y * stride + x * 4, z = (ht - 1 - y) * stride + x * 4;
          if (bits[a] == seen.B && bits[a + 1] == seen.G && bits[a + 2] == seen.R) same++;
          if (bits[z] == seen.B && bits[z + 1] == seen.G && bits[z + 2] == seen.R) flipped++;
        }
      }
      bool bottomUp = flipped >= same;
      opaque.Dispose();
      Bitmap result = new Bitmap(w, ht, PixelFormat.Format32bppPArgb);
      BitmapData data = result.LockBits(new Rectangle(0, 0, w, ht), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
      for (int y = 0; y < ht; y++) {
        int source = (bottomUp ? ht - 1 - y : y) * stride;
        Marshal.Copy(bits, source, new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride), w * 4);
      }
      result.UnlockBits(data);
      return result;
    } finally { DeleteObject(h); }
  }
}
'@
  } catch {
    # Another preview compiling it at the same time: its file is used.
  }
}
Add-Type -Path $assembly

$item = Get-Item -LiteralPath $file -Force
$isDir = $item.PSIsContainer
$ext = if ($isDir) { '' } else { $item.Extension.ToLowerInvariant() }

# The first page of a PDF, drawn by Windows' own PDF reader: Windows has no PDF thumbnail of its own.
function Get-PdfPage([string]$Path, [int]$Width) {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
  $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
  $operation = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation*' -and $_.IsGenericMethod } | Select-Object -First 1
  $action = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
  $await = { param($op, [Type]$type) $task = $operation.MakeGenericMethod($type).Invoke($null, @($op)); [void]$task.Wait(15000); $task.Result }
  $storage = & $await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
  $doc = & $await ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($storage)) ([Windows.Data.Pdf.PdfDocument])
  $page = $doc.GetPage(0)
  $options = New-Object Windows.Data.Pdf.PdfPageRenderOptions
  $options.DestinationWidth = [uint32]$Width
  $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
  [void]$action.Invoke($null, @($page.RenderToStreamAsync($stream, $options))).Wait(15000)
  $page.Dispose()
  $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
  $memory = New-Object System.IO.MemoryStream
  $net.CopyTo($memory)
  $memory.Position = 0
  @{ Picture = [System.Drawing.Image]::FromStream($memory); Pages = [int]$doc.PageCount }
}

$picture = $null
$pages = 0
if ($ext -eq '.pdf') { try { $pdf = Get-PdfPage $file $largest; $picture = $pdf.Picture; $pages = $pdf.Pages } catch { } }
if (-not $picture) { $picture = [MaxxPeekThumb]::Get($file, $largest, $true) }
if (-not $picture) { $picture = [MaxxPeekThumb]::Get($file, 128, $false) }

# What the system says of it: its kind, and the length, the size in pixels or the pages it has.
$kind = ''
$extras = New-Object System.Collections.Generic.List[string]
try {
  $shell = New-Object -ComObject Shell.Application
  $parent = Split-Path -Parent $item.FullName
  $shellItem = if ($parent) { $shell.Namespace($parent).ParseName($item.Name) } else { $shell.Namespace(17).ParseName($item.FullName) }
  $kind = [string]$shellItem.ExtendedProperty('System.ItemTypeText')
  # A kind with no friendly name ("WMP11.AssocFile.MP4") reads as its extension.
  if ($kind -match '^\w+\.AssocFile\.') { $kind = $ext.TrimStart('.').ToUpperInvariant() }
  $duration = $shellItem.ExtendedProperty('System.Media.Duration')
  if ($duration) { $span = [TimeSpan]::FromTicks([long]$duration); $extras.Add($(if ($span.TotalHours -ge 1) { $span.ToString('h\:mm\:ss') } else { $span.ToString('m\:ss') })) }
  $width = $shellItem.ExtendedProperty('System.Image.HorizontalSize'); $height = $shellItem.ExtendedProperty('System.Image.VerticalSize')
  if (-not $width) { $width = $shellItem.ExtendedProperty('System.Video.FrameWidth'); $height = $shellItem.ExtendedProperty('System.Video.FrameHeight') }
  if ($width -and $height) { $extras.Add("$width x $height") }
} catch { }
if ($pages -gt 0) { $extras.Add("$pages $(if ($pages -eq 1) { $env:PEEK_PAGE } else { $env:PEEK_PAGES })") }
if ($isDir) {
  $count = @(Get-ChildItem -LiteralPath $file -Force -ErrorAction SilentlyContinue | Select-Object -First 1000).Count
  $extras.Add("$(if ($count -ge 1000) { '1000+' } else { $count }) $(if ($count -eq 1) { $env:PEEK_ITEM } else { $env:PEEK_ITEMS })")
} else {
  $bytes = [double]$item.Length
  $extras.Add($(if ($bytes -lt 1KB) { "$bytes B" } elseif ($bytes -lt 1MB) { '{0:0} KB' -f ($bytes / 1KB) } elseif ($bytes -lt 1GB) { '{0:0.0} MB' -f ($bytes / 1MB) } else { '{0:0.0} GB' -f ($bytes / 1GB) }))
}
$age = (Get-Date) - $item.LastWriteTime
# No-break spaces keep "hace 148 d" on one line when the line wraps.
$ageText = if ($age.TotalMinutes -lt 1) { '{0:0} s' -f $age.TotalSeconds } elseif ($age.TotalHours -lt 1) { '{0:0} min' -f $age.TotalMinutes } elseif ($age.TotalDays -lt 1) { '{0:0} h' -f $age.TotalHours } else { '{0:0} d' -f $age.TotalDays }
$extras.Add(($env:PEEK_AGO + ' ' + $ageText).Replace(' ', [string][char]0x00A0))
$info = ((@($kind) + $extras) | Where-Object { $_ }) -join ('  ' + [char]0x00B7 + '  ')

# Layout: the picture on top, then the name, what it is, its folder and what a click does.
$pad = 10
$gap = 18
$textWidth = 360
$fit = 1.0
if ($picture) { $fit = [Math]::Min(1.0, $largest / [double][Math]::Max($picture.Width, $picture.Height)) }
$pictureWidth = if ($picture) { [int]($picture.Width * $fit) } else { 0 }
$pictureHeight = if ($picture) { [int]($picture.Height * $fit) } else { 0 }
$width = [Math]::Max($pictureWidth, $textWidth) + $pad * 2
$nameFont = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$infoFont = New-Object System.Drawing.Font('Segoe UI', 9)
$smallFont = New-Object System.Drawing.Font('Segoe UI', 8)
$lineTop = $pad + $pictureHeight + $(if ($picture) { 8 } else { 0 })
# What it is takes a second line where one does not hold it (a long kind, the age last).
$infoHeight = if ([System.Windows.Forms.TextRenderer]::MeasureText($info, $infoFont).Width -gt ($width - $pad * 2 - 24)) { 34 } else { 18 }
$height = $lineTop + 20 + $infoHeight + 16 + 18 + $pad

function Add-Line($Form, [string]$Text, $Font, $Color, [int]$Top, [int]$Height, [bool]$IsPath) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Font = $Font
  $label.ForeColor = $Color
  $label.BackColor = [System.Drawing.Color]::Transparent
  $label.AutoSize = $false
  $label.UseMnemonic = $false
  $label.AutoEllipsis = $true
  $label.Bounds = New-Object System.Drawing.Rectangle($pad, $Top, ($width - $pad * 2), $Height)
  $Form.Controls.Add($label)
}

$form = New-Object MaxxPeekPopup
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
$form.ClientSize = New-Object System.Drawing.Size($width, $height)
if ($picture) {
  $box = New-Object System.Windows.Forms.PictureBox
  $box.SizeMode = 'Zoom'
  $box.Image = $picture
  $box.Bounds = New-Object System.Drawing.Rectangle([int](($width - $pictureWidth) / 2), $pad, $pictureWidth, $pictureHeight)
  $form.Controls.Add($box)
}
$name = if ($item.Name) { $item.Name } else { $item.FullName }
$folder = if ($parent) { $parent } else { '' }
Add-Line $form $name $nameFont ([System.Drawing.Color]::White) $lineTop 20 $false
Add-Line $form $info $infoFont ([System.Drawing.Color]::FromArgb(200, 200, 200)) ($lineTop + 20) $infoHeight $false
Add-Line $form $folder $smallFont ([System.Drawing.Color]::FromArgb(150, 150, 150)) ($lineTop + 20 + $infoHeight) 16 $true
Add-Line $form $env:PEEK_HINT $smallFont ([System.Drawing.Color]::FromArgb(217, 119, 87)) ($lineTop + 36 + $infoHeight) 18 $false

# Drawn to a file instead of shown (a check of the layout).
if ($env:PEEK_RENDER) {
  $form.Location = New-Object System.Drawing.Point(-30000, -30000)
  $form.Show()
  [System.Windows.Forms.Application]::DoEvents()
  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $width, $height)))
  $bitmap.Save($env:PEEK_RENDER)
  [Console]::Out.WriteLine('rendered')
  exit 0
}

# Above the pointer and to its right; under it, or to its left, where there is no room: never over
# the pointer, which stays on the terminal.
$cursor = [System.Windows.Forms.Cursor]::Position
$area = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
$x = $cursor.X + $gap
$y = $cursor.Y - $gap - $height
if ($y -lt $area.Top) { $y = $cursor.Y + $gap }
if ($x + $width -gt $area.Right) { $x = $cursor.X - $gap - $width }
$form.Location = New-Object System.Drawing.Point([Math]::Max($area.Left, [Math]::Min($x, $area.Right - $width)), [Math]::Max($area.Top, [Math]::Min($y, $area.Bottom - $height)))
$form.add_Shown({ [Console]::Out.WriteLine('shown'); [Console]::Out.Flush() })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $life * 1000
$timer.add_Tick({ $form.Close() })
$timer.Start()
# The mod reads a '.' ten times a second; once it stops reading (the pointer left), writing fails and the window closes.
$beat = New-Object System.Windows.Forms.Timer
$beat.Interval = 100
$beat.add_Tick({ try { [Console]::Out.WriteLine('.'); [Console]::Out.Flush() } catch { $form.Close() } })
$beat.Start()
[System.Windows.Forms.Application]::Run($form)
