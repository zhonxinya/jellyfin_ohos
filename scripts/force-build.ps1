# Compiles and runs host-side native/core unit tests.
# Prefer g++ when available; fall back to cl.exe on Windows.

param(
    [switch]$SkipRun
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Core = Join-Path $RepoRoot "native\core"
$OutDir = Join-Path $Core "tests\out"
$ThirdParty = Join-Path $RepoRoot "native\third_party"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Invoke-CompileAndRun {
    param(
        [string]$Name,
        [string[]]$Sources
    )
    $Exe = Join-Path $OutDir "$Name.exe"
    $clang = Get-Command clang++.exe -ErrorAction SilentlyContinue
    $gpp = Get-Command g++ -ErrorAction SilentlyContinue
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue

    if ($clang) {
        Write-Host "Compiling $Name with clang++..."
        & clang++.exe -std=c++17 -I $Core -I $ThirdParty -I (Join-Path $ThirdParty "nlohmann") @Sources -o $Exe
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } elseif ($gpp) {
        Write-Host "Compiling $Name with g++..."
        & g++ -std=c++17 -I $Core -I $ThirdParty -I (Join-Path $ThirdParty "nlohmann") @Sources -o $Exe
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } elseif ($cl) {
        Write-Host "Compiling $Name with cl.exe..."
        Push-Location $OutDir
        try {
            & cl.exe /nologo /EHsc /std:c++17 /I $Core /I $ThirdParty /I (Join-Path $ThirdParty "nlohmann") @Sources /Fe:$Exe
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally {
            Pop-Location
        }
    } else {
        Write-Error "Neither g++ nor cl.exe found."
        exit 1
    }

    if (-not $SkipRun) {
        Write-Host "Running $Exe"
        & $Exe
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

Invoke-CompileAndRun -Name "test_url_util" -Sources @(
    (Join-Path $Core "tests\test_url_util.cpp"),
    (Join-Path $Core "url_util.cpp")
)

Invoke-CompileAndRun -Name "test_playback_resolve" -Sources @(
    (Join-Path $Core "tests\test_playback_resolve.cpp"),
    (Join-Path $Core "url_util.cpp"),
    (Join-Path $Core "api\playback_resolve.cpp")
)

Invoke-CompileAndRun -Name "test_http_response" -Sources @(
    (Join-Path $Core "tests\test_http_response.cpp"),
    (Join-Path $Core "http_response.cpp")
)

Invoke-CompileAndRun -Name "test_image_url" -Sources @(
    (Join-Path $Core "tests\test_image_url.cpp"),
    (Join-Path $Core "image_url.cpp"),
    (Join-Path $Core "url_util.cpp")
)

Invoke-CompileAndRun -Name "test_player_engine" -Sources @(
    (Join-Path $Core "tests\test_player_engine.cpp"),
    (Join-Path $RepoRoot "native\player\engine.cpp"),
    (Join-Path $RepoRoot "native\player\ffmpeg_decoder.cpp"),
    (Join-Path $RepoRoot "native\player\hw_decoder.cpp"),
    (Join-Path $RepoRoot "native\player\subtitle.cpp"),
    (Join-Path $RepoRoot "native\player\playback_policy.cpp"),
    (Join-Path $Core "url_util.cpp")
)

Write-Host "All native core tests finished." -ForegroundColor Green
