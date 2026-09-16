# HarmonyOS 设备管理脚本
param(
  [ValidateSet("list", "info", "log", "start", "stop", "uninstall", "install")]
  [string]$Action = "list",
  [string]$DeviceId = "",
  [switch]$Follow
)

$HDC_PATH = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$BUNDLE_NAME = "com.zhonxinya.jellyfin_hmos_flutter"
$ABILITY_NAME = "EntryAbility"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$HAP_PATH = Join-Path $ProjectRoot "native\app\entry\build\default\outputs\default\entry-default-signed.hap"

if (-not (Test-Path $HDC_PATH)) {
  Write-Host "Error: HDC not found at $HDC_PATH" -ForegroundColor Red
  exit 1
}

function Get-DeviceId {
  param([string]$Preferred = '')
  if ($Preferred -and $Preferred.Length -gt 0) {
    return $Preferred
  }
  $output = & $HDC_PATH list targets 2>&1
  foreach ($line in $output) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -gt 0 -and $trimmed -match '^[A-Za-z0-9_-]+$') {
      return $trimmed
    }
  }
  return $null
}

$Device = Get-DeviceId -Preferred $DeviceId
if (-not $Device) {
  Write-Host "Error: no device connected" -ForegroundColor Red
  exit 1
}

Write-Host "Device: $Device" -ForegroundColor Cyan

switch ($Action) {
  "list" {
    Write-Host "   OK: $Device" -ForegroundColor Green
  }
  "info" {
    $model = & $HDC_PATH -t $Device shell getprop ro.product.model 2>&1
    Write-Host "   Model: $model" -ForegroundColor Gray
  }
  "log" {
    if ($Follow) {
      & $HDC_PATH -t $Device shell hilog | Select-String $BUNDLE_NAME
    }
    else {
      & $HDC_PATH -t $Device shell hilog | Select-String $BUNDLE_NAME | Select-Object -Last 50
    }
  }
  "start" {
    & $HDC_PATH -t $Device shell aa start -a $ABILITY_NAME -b $BUNDLE_NAME
    if ($LASTEXITCODE -eq 0) {
      Write-Host "App started" -ForegroundColor Green
    }
    else {
      Write-Host "Failed to start app (unlock screen and retry)" -ForegroundColor Red
    }
  }
  "stop" {
    & $HDC_PATH -t $Device shell aa force-stop $BUNDLE_NAME
    if ($LASTEXITCODE -eq 0) {
      Write-Host "App stopped" -ForegroundColor Green
    }
    else {
      Write-Host "Failed to stop app" -ForegroundColor Red
    }
  }
  "install" {
    if (-not (Test-Path $HAP_PATH)) {
      Write-Host "Error: HAP not found at $HAP_PATH. Run build.ps1 first." -ForegroundColor Red
      exit 1
    }
    & $HDC_PATH -t $Device install $HAP_PATH
    if ($LASTEXITCODE -eq 0) {
      Write-Host "App installed" -ForegroundColor Green
    }
    else {
      Write-Host "Failed to install app" -ForegroundColor Red
    }
  }
  "uninstall" {
    & $HDC_PATH -t $Device shell bm uninstall -n $BUNDLE_NAME
    if ($LASTEXITCODE -eq 0) {
      Write-Host "App uninstalled" -ForegroundColor Green
    }
    else {
      Write-Host "Failed to uninstall" -ForegroundColor Red
    }
  }
}
