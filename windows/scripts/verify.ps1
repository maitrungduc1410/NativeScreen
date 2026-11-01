# Builds the Windows solution, runs tests, and writes windows/artifacts/verify-report.md.
# Run from anywhere: pwsh windows/scripts/verify.ps1
$ErrorActionPreference = "Stop"
$windows = Split-Path $PSScriptRoot -Parent
$solution = Join-Path $windows "NativeScreen.Windows.slnx"
$reportDir = Join-Path $windows "artifacts"
$reportPath = Join-Path $reportDir "verify-report.md"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$results = New-Object System.Collections.Generic.List[string]
$failed = $false

function Invoke-Check {
    param(
        [string] $Name,
        [scriptblock] $Action
    )
    Write-Host "== $Name"
    try {
        & $Action
        if ($LASTEXITCODE -ne 0) {
            throw "exit $LASTEXITCODE"
        }
        $script:results.Add("- **${Name}:** PASS")
    }
    catch {
        $script:failed = $true
        $script:results.Add("- **${Name}:** FAIL ($($_.Exception.Message))")
        throw
    }
}

try {
    Invoke-Check "Debug x64" { dotnet build $solution -c Debug -p:Platform=x64 --nologo }
    Invoke-Check "Release x64" { dotnet build $solution -c Release -p:Platform=x64 --nologo }
    Invoke-Check "Tests" { dotnet test $solution -c Debug -p:Platform=x64 --nologo --no-build }
    $shaders = @(Get-ChildItem -Path (Join-Path $windows "src") -Recurse -Filter *.hlsl -ErrorAction SilentlyContinue)
    if ($shaders.Count -eq 0) {
        $results.Add("- **Shaders:** skipped (no .hlsl files yet)")
    }
    else {
        $dxc = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter dxc.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if (-not $dxc) {
            $results.Add("- **Shaders:** FAIL (dxc.exe not found; $($shaders.Count) file(s))")
            $failed = $true
        }
        else {
            $shaderFailed = $false
            $outDir = Join-Path $reportDir "shaders"
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            foreach ($shader in $shaders) {
                $profile = "ps_5_0"
                $head = Get-Content -Path $shader.FullName -TotalCount 1
                if ($head -match "dxc:\s*(\S+)") { $profile = $Matches[1] }
                $outFile = Join-Path $outDir ($shader.BaseName + ".dxo")
                & $dxc.FullName -T $profile -E main -O3 -Fo $outFile $shader.FullName
                if ($LASTEXITCODE -ne 0) { $shaderFailed = $true }
            }
            if ($shaderFailed) {
                $results.Add("- **Shaders:** FAIL ($($shaders.Count) file(s), dxc $($dxc.FullName))")
                $failed = $true
            }
            else {
                $results.Add("- **Shaders:** PASS ($($shaders.Count) file(s), dxc)")
            }
        }
    }
}
catch {
    if (-not $failed) {
        $failed = $true
        $results.Add("- **Script:** FAIL ($($_.Exception.Message))")
    }
}
finally {
    $status = if ($failed) { "FAIL" } else { "PASS" }
    $body = @(
        "# Verify report",
        "",
        "- **When:** $((Get-Date).ToString('yyyy-MM-dd HH:mm'))",
        "- **Result:** $status",
        "",
        ($results -join "`n"),
        ""
    ) -join "`n"
    Set-Content -Path $reportPath -Value $body -Encoding utf8
    Write-Host "Wrote $reportPath ($status)"
}

if ($failed) { exit 1 }
