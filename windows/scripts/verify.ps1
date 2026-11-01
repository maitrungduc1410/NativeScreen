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
    $shaders = Get-ChildItem -Path (Join-Path $windows "src") -Recurse -Filter *.hlsl -ErrorAction SilentlyContinue
    if ($shaders) {
        $results.Add("- **Shaders:** FAIL (compiler hook is not wired yet; $($shaders.Count) file(s) found)")
        $failed = $true
    }
    else {
        $results.Add("- **Shaders:** skipped (no .hlsl files yet)")
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
