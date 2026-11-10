# Builds the Store MSIX (unsigned) into windows/artifacts/msix, then checks what is inside it.
# Without arguments the package has the local test identity and can be sideloaded after signing it with your own
# certificate. For the Store, pass the values from Partner Center > Product identity (docs/releasing.md):
#   powershell windows/scripts/package-msix.ps1 -IdentityName <Package/Identity/Name> -Publisher "CN=<...>" `
#     -PublisherDisplayName "<...>" -Version 1.2.0
# Run from anywhere: powershell windows/scripts/package-msix.ps1
param(
    [string] $IdentityName = "",
    [string] $Publisher = "",
    [string] $PublisherDisplayName = "",
    # major.minor.build; the package version gets a zero revision, as the Store requires.
    [string] $Version = "1.0.0",
    # The fourth part of the exe's file version (the run number shown in Settings).
    [int] $Build = 0
)
$ErrorActionPreference = "Stop"
$windows = Split-Path $PSScriptRoot -Parent
$project = Join-Path $windows "src\NativeScreen.App\NativeScreen.App.csproj"
$output = Join-Path $windows "artifacts\msix"

$numeric = $Version -replace '-.*$', ''
$properties = @(
    "-p:Platform=x64",
    "-p:NsPackage=true",
    # Doubled: Windows PowerShell would read one trailing backslash as escaping the closing quote of a path with spaces.
    "-p:AppxPackageDir=$output\\",
    "-p:Version=$Version",
    "-p:FileVersion=$numeric.$Build",
    "-p:NsPackageVersion=$numeric.0"
)
if ($IdentityName) { $properties += "-p:NsStoreIdentityName=$IdentityName" }
if ($Publisher) { $properties += "-p:NsStorePublisher=$Publisher" }
if ($PublisherDisplayName) { $properties += "-p:NsStorePublisherDisplayName=$PublisherDisplayName" }

if (Test-Path $output) { Remove-Item $output -Recurse -Force }
dotnet build $project -c Release @properties --nologo
if ($LASTEXITCODE -ne 0) { throw "MSIX build failed" }

$msix = @(Get-ChildItem $output -Recurse -Filter *.msix)
if ($msix.Count -ne 1) { throw "Expected one .msix in $output, found $($msix.Count)" }
$msix = $msix[0]

# Every file the manifest names must be in the package: the Store rejects missing or placeholder tiles. A logo may be
# present only as its scale or target size variants (Square44x44Logo.scale-200.png), which the resource index resolves.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($msix.FullName)
try {
    $entries = @($zip.Entries | ForEach-Object { [System.Uri]::UnescapeDataString($_.FullName).Replace('/', '\') })
    $reader = New-Object System.IO.StreamReader(($zip.Entries | Where-Object FullName -eq "AppxManifest.xml").Open())
    [xml] $manifest = $reader.ReadToEnd()
    $reader.Dispose()
}
finally {
    $zip.Dispose()
}

$problems = New-Object System.Collections.Generic.List[string]
$named = New-Object System.Collections.Generic.List[string]
foreach ($node in $manifest.SelectNodes("//*")) {
    foreach ($attribute in $node.Attributes) {
        if ($attribute.Value -match '\.(png|jpg|jpeg|gif)$') { $named.Add($attribute.Value) }
    }
    if (-not $node.HasChildNodes -or $node.ChildNodes.Count -ne 1 -or $node.FirstChild.NodeType -ne "Text") { continue }
    if ($node.InnerText -match '\.(png|jpg|jpeg|gif)$') { $named.Add($node.InnerText) }
}
foreach ($file in ($named | Sort-Object -Unique)) {
    $stem = [System.IO.Path]::ChangeExtension($file, $null).TrimEnd('.')
    $extension = [System.IO.Path]::GetExtension($file)
    $variants = @($entries | Where-Object { $_ -ieq $file -or ($_.StartsWith("$stem.", "OrdinalIgnoreCase") -and $_.EndsWith($extension, "OrdinalIgnoreCase")) })
    if ($variants.Count -eq 0) { $problems.Add("missing image: $file") }
    else { "  $file ($($variants.Count) file(s))" }
}

$executable = $manifest.Package.Applications.Application.Executable
if ($entries -notcontains $executable) { $problems.Add("missing executable: $executable") }

# Native libraries are loaded from the package folder (MSIX ignores PATH when it resolves them), and data files are read
# next to the exe.
$required = @(
    "onnxruntime.dll", "onnxruntime_providers_shared.dll", "DirectML.dll", "resources.pri",
    "runtimes\win-x64\whisper.dll", "runtimes\win-x64\ggml-whisper.dll", "runtimes\win-x64\ggml-base-whisper.dll", "runtimes\win-x64\ggml-cpu-whisper.dll",
    "Assets\Models\face_detection_yunet_2023mar.onnx", "Assets\app.ico",
    "Localization\Localizable.xcstrings", "Mcp\MCPTools.json"
)
foreach ($file in $required) {
    if ($entries -notcontains $file) { $problems.Add("missing: $file") }
}
# The Store updates this package; nothing in it may update itself.
if ($entries | Where-Object { $_ -match '^Velopack' }) {
    $problems.Add("Velopack is in the Store package")
}

$identity = $manifest.Package.Identity
"Identity: $($identity.Name), $($identity.Publisher), $($identity.Version)"
"Package:  $($msix.FullName)  $([math]::Round($msix.Length / 1MB)) MB"
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "FAIL $_" }
    throw "The package is incomplete"
}
"Package check: PASS"
