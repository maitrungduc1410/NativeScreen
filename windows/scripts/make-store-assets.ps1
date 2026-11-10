# Draws the MSIX tile and logo images from the app icon (macos/.../AppIcon.appiconset/icon_1024.png) into
# windows/src/NativeScreen.App/Assets/Store. Run again after the icon changes, then commit the PNGs.
# Run from anywhere: powershell windows/scripts/make-store-assets.ps1
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$windows = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $windows -Parent
$source = Join-Path $repo "macos\NativeScreen\Assets.xcassets\AppIcon.appiconset\icon_1024.png"
$outDir = Join-Path $windows "src\NativeScreen.App\Assets\Store"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Get-ChildItem $outDir -Filter *.png | Remove-Item

$icon = [System.Drawing.Bitmap]::FromFile($source)

# The macOS icon has a transparent margin and a soft shadow. Crop to the opaque rounded square, plus 2%, so the Windows
# images are not drawn small inside an empty frame.
$rect = New-Object System.Drawing.Rectangle 0, 0, $icon.Width, $icon.Height
$data = $icon.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$bytes = New-Object byte[] ($data.Stride * $icon.Height)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$icon.UnlockBits($data)
$minX = $icon.Width; $minY = $icon.Height; $maxX = -1; $maxY = -1
for ($y = 0; $y -lt $icon.Height; $y++) {
    $row = $y * $data.Stride
    for ($x = 0; $x -lt $icon.Width; $x++) {
        if ($bytes[$row + $x * 4 + 3] -ge 128) {
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }
        }
    }
}
$side = [math]::Max($maxX - $minX + 1, $maxY - $minY + 1)
$side = [int][math]::Round($side * 1.04)
$cx = ($minX + $maxX + 1) / 2.0
$cy = ($minY + $maxY + 1) / 2.0
$crop = New-Object System.Drawing.RectangleF ([float]($cx - $side / 2.0)), ([float]($cy - $side / 2.0)), ([float]$side), ([float]$side)

function Save-Image([string] $name, [int] $width, [int] $height, [double] $fraction) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $size = [int][math]::Round([math]::Min($width, $height) * $fraction)
    $x = [int][math]::Floor(($width - $size) / 2)
    $y = [int][math]::Floor(($height - $size) / 2)
    $attributes = New-Object System.Drawing.Imaging.ImageAttributes
    $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $target = New-Object System.Drawing.Rectangle $x, $y, $size, $size
    $graphics.DrawImage($icon, $target, $crop.X, $crop.Y, $crop.Width, $crop.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    $graphics.Dispose()
    $bitmap.Save((Join-Path $outDir $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

$scales = 100, 125, 150, 200, 400
# Name, width and height at scale 100, and the share of the shorter side the icon covers. Tiles keep a margin, as the
# Start menu draws them on a colored plate; the app list and taskbar icon fills its frame.
$images = @(
    @("StoreLogo", 50, 50, 1.0),
    @("Square44x44Logo", 44, 44, 1.0),
    @("Square71x71Logo", 71, 71, 0.66),
    @("Square150x150Logo", 150, 150, 0.66),
    @("Wide310x150Logo", 310, 150, 0.66),
    @("Square310x310Logo", 310, 310, 0.66),
    @("SplashScreen", 620, 300, 0.5)
)
foreach ($image in $images) {
    foreach ($scale in $scales) {
        $w = [int][math]::Round($image[1] * $scale / 100.0)
        $h = [int][math]::Round($image[2] * $scale / 100.0)
        Save-Image "$($image[0]).scale-$scale.png" $w $h $image[3]
    }
}

# Taskbar, Start list, Explorer and Alt+Tab ask for exact pixel sizes. Unplated variants keep Windows from drawing a
# colored plate behind the icon; the icon is the same on light and dark taskbars.
foreach ($size in 16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256) {
    foreach ($suffix in "", "_altform-unplated", "_altform-lightunplated") {
        Save-Image "Square44x44Logo.targetsize-$size$suffix.png" $size $size 1.0
    }
}

$icon.Dispose()
$count = (Get-ChildItem $outDir -Filter *.png).Count
"Wrote $count images to $outDir"
