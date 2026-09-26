<#
.SYNOPSIS
    Builds BioKey release artifacts: Windows installer (setup.exe) and Android release APK.

.DESCRIPTION
    Produces dist\BioKey-Setup-<version>.exe (Windows) and dist\BioKey-<version>.apk (Android).
    The two halves are independent: a failure in one (e.g. Windows Developer Mode disabled)
    does not prevent the other from running.

.PARAMETER SkipWindows
    Skip the Windows build + Inno Setup packaging step entirely.

.PARAMETER SkipAndroid
    Skip the Android release APK build step entirely.
#>
param(
    [switch]$SkipWindows,
    [switch]$SkipAndroid
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$env:BIOKEY_VERSION = $version
New-Item -ItemType Directory -Force dist | Out-Null

Write-Host "BioKey release build - version $version" -ForegroundColor Cyan

# --- Windows: setup.exe -----------------------------------------------------
if ($SkipWindows) {
    Write-Host "Windows : ignore (-SkipWindows)." -ForegroundColor Yellow
} else {
    try {
        Write-Host "Windows : flutter build windows --release" -ForegroundColor Cyan
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows --release a échoué (code $LASTEXITCODE)." }

        $iscc = @(
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
            "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if (-not $iscc) {
            throw "ISCC.exe introuvable. Installez Inno Setup : winget install --id JRSoftware.InnoSetup -e --scope user"
        }

        & $iscc installer\biokey.iss
        if ($LASTEXITCODE -ne 0) { throw "ISCC.exe a échoué (code $LASTEXITCODE)." }

        Write-Host "Windows : OK -> dist\BioKey-Setup-$version.exe" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "=============================================================" -ForegroundColor Red
        Write-Host " Échec de la compilation Windows." -ForegroundColor Red
        Write-Host " $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host " Si l'erreur mentionne des liens symboliques ou le Mode" -ForegroundColor Yellow
        Write-Host " développeur, activez-le : Paramètres -> Système -> Espace" -ForegroundColor Yellow
        Write-Host " développeurs -> Mode développeur, puis relancez ce script." -ForegroundColor Yellow
        Write-Host "=============================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "On continue avec l'APK Android..." -ForegroundColor Yellow
    }
}

# --- Android: release APK ---------------------------------------------------
if ($SkipAndroid) {
    Write-Host "Android : ignoré (-SkipAndroid)." -ForegroundColor Yellow
} else {
    try {
        Write-Host "Android : flutter build apk --release" -ForegroundColor Cyan
        flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk --release a échoué (code $LASTEXITCODE)." }

        Copy-Item build\app\outputs\flutter-apk\app-release.apk "dist\BioKey-$version.apk" -Force
        Write-Host "Android : OK -> dist\BioKey-$version.apk" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "=============================================================" -ForegroundColor Red
        Write-Host " Échec de la compilation Android." -ForegroundColor Red
        Write-Host " $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "=============================================================" -ForegroundColor Red
        Write-Host ""
    }
}

Write-Host ""
Write-Host "Contenu de dist\ :" -ForegroundColor Cyan
Get-ChildItem dist
