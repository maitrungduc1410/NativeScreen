# Builds an unsigned MSIX into windows/artifacts/msix. Sign it with your own certificate before installing it.
# Run from anywhere: powershell windows/scripts/package-msix.ps1
$ErrorActionPreference = "Stop"
$windows = Split-Path $PSScriptRoot -Parent
$project = Join-Path $windows "src\NativeScreen.App\NativeScreen.App.csproj"
$output = Join-Path $windows "artifacts\msix\"
dotnet build $project -c Release -p:Platform=x64 -p:NsPackage=true "-p:AppxPackageDir=$output" --nologo
if ($LASTEXITCODE -ne 0) { throw "MSIX build failed" }
Get-ChildItem $output -Recurse -Filter *.msix | ForEach-Object { "$($_.FullName)  $([math]::Round($_.Length / 1MB)) MB" }
