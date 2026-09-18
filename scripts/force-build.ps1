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
        & clang++.exe -std=c++17 -pthread -I $Core -I $ThirdParty -I (Join-Path $ThirdParty "nlohmann") @Sources -o $Exe
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } elseif ($gpp) {
        Write-Host "Compiling $Name with g++..."
        # -pthread：RangeCache 含后台预取线程（std::thread），链接需要 pthread
        & g++ -std=c++17 -pthread -I $Core -I $ThirdParty -I (Join-Path $ThirdParty "nlohmann") @Sources -o $Exe
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

# ItemsQuery：媒体库筛选/排序/分页的 query string 构造（纯函数，不依赖网络客户端）
Invoke-CompileAndRun -Name "test_items_query" -Sources @(
    (Join-Path $Core "tests\test_items_query.cpp"),
    (Join-Path $Core "api\items_query.cpp"),
    (Join-Path $Core "url_util.cpp")
)

Invoke-CompileAndRun -Name "test_player_engine" -Sources @(
    (Join-Path $Core "tests\test_player_engine.cpp"),
    (Join-Path $RepoRoot "native\feature\player\engine.cpp"),
    (Join-Path $RepoRoot "native\feature\player\ffmpeg_decoder.cpp"),
    (Join-Path $RepoRoot "native\feature\player\hw_decoder.cpp"),
    (Join-Path $RepoRoot "native\feature\player\subtitle.cpp"),
    (Join-Path $RepoRoot "native\feature\player\playback_policy.cpp"),
    (Join-Path $Core "url_util.cpp")
)

# RangeCache：软解取流的 Range 分页/缓存逻辑（不依赖 FFmpeg，故可主机单测）
Invoke-CompileAndRun -Name "test_range_cache" -Sources @(
    (Join-Path $Core "tests\test_range_cache.cpp"),
    (Join-Path $RepoRoot "native\feature\player\range_cache.cpp"),
    (Join-Path $RepoRoot "native\feature\player\range_fetcher.cpp")
)

# 媒体库管理：请求构造（query 编码 / 请求体形状）+ 响应归一化（纯函数，不依赖网络客户端）
Invoke-CompileAndRun -Name "test_library_admin_api" -Sources @(
    (Join-Path $Core "tests\test_library_admin_api.cpp"),
    (Join-Path $Core "api\library_admin_api.cpp"),
    (Join-Path $Core "url_util.cpp")
)

Write-Host "All native core tests finished." -ForegroundColor Green
