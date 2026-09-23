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

    # -I $Core\api：api 目录下的头文件（library_admin_api.h / item_metadata_api.h …）
    # 被测试以 `#include "xxx_api.h"` 直接引用，不加这条路径测试根本编不过。
    # -I native\feature\player：同上，player 的可移植能力目录（range_cache.h / engine.h …）。
    $Player = Join-Path $RepoRoot "native\feature\player"
    if ($clang) {
        Write-Host "Compiling $Name with clang++..."
        & clang++.exe -std=c++17 -pthread -I $Core -I (Join-Path $Core "api") -I $Player -I $ThirdParty -I (Join-Path $ThirdParty "nlohmann") @Sources -o $Exe
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } elseif ($gpp) {
        Write-Host "Compiling $Name with g++..."
        # -pthread：RangeCache 含后台预取线程（std::thread），链接需要 pthread
        & g++ -std=c++17 -pthread -I $Core -I (Join-Path $Core "api") -I $Player -I $ThirdParty -I (Join-Path $ThirdParty "nlohmann") @Sources -o $Exe
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } elseif ($cl) {
        Write-Host "Compiling $Name with cl.exe..."
        Push-Location $OutDir
        try {
            & cl.exe /nologo /EHsc /std:c++17 /I $Core /I (Join-Path $Core "api") /I $Player /I $ThirdParty /I (Join-Path $ThirdParty "nlohmann") @Sources /Fe:$Exe
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

# socket_util.h 是 header-only，单独编译即可（无需额外 .cpp）。
# 守的是"fd ≥ 1024 不能 abort"这条 OpenHarmony 特有的约束，见该测试文件头说明。
Invoke-CompileAndRun -Name "test_socket_util" -Sources @(
    (Join-Path $Core "tests\test_socket_util.cpp")
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

# ItemsQuery：媒体库筛选/排序/分页的 query string 构造（纯函数，不依赖网络客户端），
# 外加 options_parse.cpp：宿主 JSON -> ItemsQuery/PlaybackInfoOptions 的容错解析
Invoke-CompileAndRun -Name "test_items_query" -Sources @(
    (Join-Path $Core "tests\test_items_query.cpp"),
    (Join-Path $Core "api\items_query.cpp"),
    (Join-Path $Core "api\options_parse.cpp"),
    (Join-Path $Core "url_util.cpp")
)

# json_arg：入参容错读取（header-only）。守住"异常不得从 NAPI 边界逸出"——
# nlohmann 的 value() 对"键存在但类型不符"（尤其 ArkTS 传下来的 null）会抛异常，
# 而异常一旦逸出 RunAsync 的 worker 线程就是 std::terminate、应用直接消失。
# 该文件是 header-only，只需编译测试自身。
Invoke-CompileAndRun -Name "test_json_arg" -Sources @(
    (Join-Path $Core "tests\test_json_arg.cpp")
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
    (Join-Path $RepoRoot "native\feature\player\range_fetcher.cpp"),
    # 诊断日志注入点（RangeCache 会用它打印慢取流/慢加锁）；未注入时为空实现
    (Join-Path $RepoRoot "native\feature\player\player_log.cpp")
)

# 媒体库管理：请求构造（query 编码 / 请求体形状）+ 响应归一化（纯函数，不依赖网络客户端）
Invoke-CompileAndRun -Name "test_library_admin_api" -Sources @(
    (Join-Path $Core "tests\test_library_admin_api.cpp"),
    (Join-Path $Core "api\library_admin_api.cpp"),
    (Join-Path $Core "url_util.cpp")
)

# 条目元数据管理：整体替换的字段完整性（少带字段 = 服务端清空；ProviderIds 缺失 = 500）
Invoke-CompileAndRun -Name "test_item_metadata_api" -Sources @(
    (Join-Path $Core "tests\test_item_metadata_api.cpp"),
    (Join-Path $Core "api\item_metadata_api.cpp"),
    (Join-Path $Core "url_util.cpp")
)

# DeviceProfile：客户端能力声明（决定服务端会不会转码；av1 必须在直接播放列表之外）
Invoke-CompileAndRun -Name "test_device_profile" -Sources @(
    (Join-Path $Core "tests\test_device_profile.cpp"),
    (Join-Path $Core "api\device_profile.cpp")
)

# ImageCache：磁盘图片缓存（淘汰触发频率 / LRU / 在途去重 / 错误必须显式）。
# 只依赖注入的下载函数（ImageDownloadFn），因此不需要 HttpClient 与 mbedTLS，可零依赖主机单测。
Invoke-CompileAndRun -Name "test_image_cache" -Sources @(
    (Join-Path $Core "tests\test_image_cache.cpp"),
    (Join-Path $Core "image_cache.cpp")
)

Write-Host "All native core tests finished." -ForegroundColor Green
