# Native HarmonyOS HAP build script (no Flutter)
param(
    [ValidateSet('debug', 'release')]
    [string]$BuildMode = 'debug',

    [string]$DeviceId = '',

    [switch]$Run,

    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$NativeApp = Join-Path $ProjectRoot 'native\app'
$BundleName = 'com.zhonxinya.jellyfin_hmos_flutter'
$AbilityName = 'EntryAbility'

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Resolve-HvigorwPath {
    param([string]$AppRoot)
    $devEcoRoots = @(
        'C:\Program Files\Huawei\DevEco Studio',
        'C:\Program Files\Huawei\DevEco-Studio'
    )
    foreach ($root in $devEcoRoots) {
        $bat = Join-Path $root 'tools\hvigor\bin\hvigorw.bat'
        if (Test-Path $bat) {
            return $bat
        }
    }
    $repoBat = Join-Path $PSScriptRoot 'hvigorw.bat'
    if (Test-Path $repoBat) {
        return $repoBat
    }
    $localBat = Join-Path $AppRoot 'hvigorw.bat'
    if (Test-Path $localBat) {
        return $localBat
    }
    return $null
}

function Resolve-HdcPath {
    $candidates = @(
        'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
        'C:\Program Files\Huawei\DevEco-Studio\sdk\default\openharmony\toolchains\hdc.exe'
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }
    if (Get-Command hdc -ErrorAction SilentlyContinue) {
        return 'hdc'
    }
    return $null
}

function Get-DeviceId {
    param(
        [string]$HdcPath,
        [string]$Preferred = ''
    )
    if ($Preferred -and $Preferred.Length -gt 0) {
        return $Preferred
    }
    $output = & $HdcPath list targets 2>&1
    foreach ($line in $output) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0 -and $trimmed -match '^[A-Za-z0-9_-]+$') {
            return $trimmed
        }
    }
    return $null
}

$Hvigorw = Resolve-HvigorwPath -AppRoot $NativeApp
$Hdc = Resolve-HdcPath
$Ohpm = $null

if (-not (Test-Path $NativeApp)) {
    Write-Host 'ERROR: native/app not found' -ForegroundColor Red
    exit 1
}

$devEcoCandidates = @(
    'C:\Program Files\Huawei\DevEco Studio',
    'C:\Program Files\Huawei\DevEco-Studio'
)
$DevEcoRoot = $devEcoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (Get-Command ohpm -ErrorAction SilentlyContinue) {
    $Ohpm = 'ohpm'
} elseif ($DevEcoRoot) {
    $ohpmCmd = Join-Path $DevEcoRoot 'tools\ohpm\bin\ohpm.bat'
    if (Test-Path $ohpmCmd) { $Ohpm = $ohpmCmd }
}

if (-not $Hvigorw) {
    Write-Host 'ERROR: hvigorw.bat not found. Install DevEco Studio.' -ForegroundColor Red
    exit 1
}

Write-Step "Native project: $NativeApp"
Write-Step "Build mode: $BuildMode"

Push-Location $NativeApp
try {
    if ($Clean) {
        Write-Step 'Cleaning build outputs...'
        if (Test-Path '.\entry\build') { Remove-Item -Recurse -Force '.\entry\build' }
        if (Test-Path '.\build') { Remove-Item -Recurse -Force '.\build' }
        if (Test-Path '.\.hvigor') { Remove-Item -Recurse -Force '.\.hvigor' }
    }

    if ($Ohpm) {
        Write-Step 'ohpm install...'
        & $Ohpm install --all
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'ERROR: ohpm install failed' -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } else {
        Write-Host 'WARN: ohpm not found, skipping dependency install' -ForegroundColor Yellow
    }

    Write-Step 'hvigor assembleHap...'
    $modeArg = if ($BuildMode -eq 'release') { 'release' } else { 'debug' }
    & $Hvigorw assembleHap '-p' 'module=entry@default' '-p' 'product=default' '-p' "buildMode=$modeArg" '--no-daemon'
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'ERROR: hvigor build failed' -ForegroundColor Red
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}

$hapCandidates = @(
    (Join-Path $NativeApp 'entry\build\default\outputs\default\entry-default-signed.hap'),
    (Join-Path $NativeApp 'entry\build\default\outputs\default\entry-default-unsigned.hap')
)
$Hap = $hapCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Hap) {
    Write-Host 'WARN: HAP not found. Check signing config in native/app/build-profile.json5' -ForegroundColor Yellow
} else {
    Write-Host ('HAP: ' + $Hap) -ForegroundColor Green
}

if ($Run) {
    if (-not $Hap) {
        Write-Host 'ERROR: no HAP to install' -ForegroundColor Red
        exit 1
    }
    if (-not $Hdc) {
        Write-Host 'ERROR: hdc not found' -ForegroundColor Red
        exit 1
    }
    $targetDevice = Get-DeviceId -HdcPath $Hdc -Preferred $DeviceId
    if (-not $targetDevice) {
        Write-Host 'ERROR: no device connected. Connect device via USB and retry.' -ForegroundColor Red
        exit 1
    }
    Write-Step "Installing on device: $targetDevice"
    & $Hdc -t $targetDevice install $Hap
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'ERROR: hdc install failed' -ForegroundColor Red
        exit $LASTEXITCODE
    }
    $startCmd = "aa start -a $AbilityName -b $BundleName"
    & $Hdc -t $targetDevice shell $startCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'ERROR: hdc start failed. Unlock the device screen and retry.' -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Step 'App launched successfully'
}

Write-Step 'Done'
