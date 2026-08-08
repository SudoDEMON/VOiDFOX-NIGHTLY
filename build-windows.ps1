#!/usr/bin/env pwsh
<#
VOiDFOX Windows build script.

This is intentionally separate from build.sh. The Linux script remains the
owner-specific KDE/Wayland build; this script is the Windows counterpart.
#>

param(
  [switch]$Doctor,
  [switch]$Help,
  [switch]$BootstrapOnly,
  [switch]$NoClobber,
  [string]$ProfileDir = $env:VOIDFOX_PROFILE_DIR,
  [string]$BuildDir = "${env:USERPROFILE}\voidfox-build-windows",
  [string]$WrapDir = "${env:USERPROFILE}\voidfox-windows",
  [string]$AiTempDir = "${env:USERPROFILE}\Documents\Projects\AI-TEMP",
  [string]$IconSource = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppName = "VOiDFOX"
$DesktopId = "voidfox-windows"
$DefaultIconSource = Join-Path $ScriptDir "icon.svg"
if ([string]::IsNullOrWhiteSpace($IconSource)) {
  $IconSource = $DefaultIconSource
}
if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
  $ProfileDir = Join-Path $env:APPDATA "Mozilla\Firefox\Profiles\VOID-WINDOWS"
}

$FirefoxSourceDir = Join-Path $BuildDir "firefox"
$BootstrapPath = Join-Path $BuildDir "bootstrap.py"
$ShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "$AppName Windows.lnk"

function Write-Phase {
  param([string]$Message)
  Write-Host ""
  Write-Host "============================================================"
  Write-Host $Message
  Write-Host "============================================================"
}

function Show-Usage {
  @"
Usage:
  .\build-windows.ps1              Build and stage VOiDFOX for Windows. Removes:
                                   $BuildDir
                                   $WrapDir
  .\build-windows.ps1 -Doctor       Run non-destructive prerequisite checks.
  .\build-windows.ps1 -BootstrapOnly
                                   Bootstrap Firefox source and write mozconfig,
                                   then stop before clobber/build.
  .\build-windows.ps1 -NoClobber    Reuse existing build dir and skip mach clobber.
  .\build-windows.ps1 -Help         Show this help.

Environment overrides:
  VOIDFOX_PROFILE_DIR=...           Firefox profile directory to launch.

Notes:
  - Install MozillaBuild to C:\mozilla-build first.
  - Install Visual Studio Build Tools with C++ desktop components.
  - Use a real python.org Python, not the Microsoft Store app execution alias.
  - This script does not change Windows default browser registry settings.
"@ | Write-Host
}

function Test-CommandExists {
  param([string]$Command)
  return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Resolve-Python {
  foreach ($candidate in @("python3", "python", "py")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
      continue
    }

    $source = [string]$cmd.Source
    if ($source -like "*\WindowsApps\python*.exe") {
      continue
    }

    return $candidate
  }

  return $null
}

function Get-VisualStudioPath {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (!(Test-Path -LiteralPath $vswhere)) {
    return $null
  }

  $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ([string]::IsNullOrWhiteSpace($path)) {
    return $null
  }

  return $path.Trim()
}

function Test-SafeChildPath {
  param(
    [string]$Path,
    [string]$Parent
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  return $fullPath.StartsWith($fullParent, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-Doctor {
  $issues = 0

  Write-Host "VOiDFOX Windows doctor"
  Write-Host "Repo: $ScriptDir"
  Write-Host "Build dir: $BuildDir"
  Write-Host "Wrapper dir: $WrapDir"
  Write-Host "Profile: $ProfileDir"
  Write-Host ""

  $mozillaBuild = "C:\mozilla-build\start-shell.bat"
  if (Test-Path -LiteralPath $mozillaBuild) {
    Write-Host "OK: MozillaBuild found: $mozillaBuild"
  } else {
    Write-Warning "Missing MozillaBuild: $mozillaBuild"
    $issues++
  }

  $vsPath = Get-VisualStudioPath
  if ($null -ne $vsPath) {
    Write-Host "OK: Visual Studio C++ tools found: $vsPath"
  } else {
    Write-Warning "Visual Studio C++ build tools were not detected."
    $issues++
  }

  $python = Resolve-Python
  if ($null -ne $python) {
    Write-Host "OK: Python command: $python"
  } else {
    Write-Warning "Real Python was not detected. The Microsoft Store app execution alias does not count."
    $issues++
  }

  foreach ($cmd in @("git", "curl")) {
    if (Test-CommandExists $cmd) {
      Write-Host "OK: $cmd"
    } else {
      Write-Warning "Missing command: $cmd"
      $issues++
    }
  }

  if (Test-Path -LiteralPath $IconSource) {
    Write-Host "OK: Icon source found: $IconSource"
  } else {
    Write-Warning "Icon source not found: $IconSource"
    $issues++
  }

  $driveName = ([System.IO.Path]::GetPathRoot($BuildDir)).TrimEnd('\').TrimEnd(':')
  $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
  if ($null -ne $drive) {
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    Write-Host "Free disk on ${driveName}: $freeGb GB"
    if ($drive.Free -lt 80GB) {
      Write-Warning "Firefox source builds are large. Keep at least 80GB free for this workflow."
      $issues++
    }
  }

  if (Test-Path -LiteralPath $FirefoxSourceDir) {
    Write-Host "Firefox source exists: $FirefoxSourceDir"
  } else {
    Write-Host "Firefox source not present yet: $FirefoxSourceDir"
  }

  Write-Host ""
  if ($issues -eq 0) {
    Write-Host "Doctor passed."
  } else {
    Write-Host "Doctor found $issues warning(s)."
  }

  return $issues
}

function Invoke-CheckedProcess {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [string]$WorkingDirectory
  )

  Write-Host "> $FilePath $($ArgumentList -join ' ')"
  $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Command failed with exit code $($process.ExitCode): $FilePath"
  }
}

function Write-Mozconfig {
  $mozconfig = Join-Path $FirefoxSourceDir "mozconfig"
  $jobCount = [Environment]::ProcessorCount

  @"
ac_add_options --enable-application=browser
ac_add_options --with-branding=browser/branding/unofficial

# Windows build: keep optimization conservative. Linux-specific znver5,
# GTK/Wayland, XDG, and KDE integration flags intentionally stay in build.sh.
ac_add_options --enable-optimize
ac_add_options --enable-lto=thin

mk_add_options MOZ_MAKE_FLAGS="-j$jobCount"
mk_add_options "export RUSTFLAGS=-C target-cpu=native"

ac_add_options --disable-debug
ac_add_options --disable-tests
ac_add_options --disable-crashreporter
ac_add_options --disable-updater
ac_add_options --disable-artifact-builds

mk_add_options MOZ_DEBUG_SYMBOLS=0
"@ | Set-Content -LiteralPath $mozconfig -Encoding UTF8

  Write-Host "Wrote mozconfig: $mozconfig"
  Get-Content -LiteralPath $mozconfig | Write-Host
}

function Ensure-FirefoxSource {
  $python = Resolve-Python
  if ($null -eq $python) {
    throw "Python is required. Install python.org Python and rerun -Doctor."
  }

  New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

  if (!(Test-Path -LiteralPath $FirefoxSourceDir)) {
    Write-Phase "Downloading bootstrap + source"
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/mozilla/firefox/main/python/mozboot/bin/bootstrap.py" -OutFile $BootstrapPath
    Invoke-CheckedProcess -FilePath $python -ArgumentList @($BootstrapPath, "--application-choice=browser", "--no-interactive") -WorkingDirectory $BuildDir
  }

  if (!(Test-Path -LiteralPath $FirefoxSourceDir)) {
    throw "$FirefoxSourceDir not found. Bootstrap did not clone the source."
  }

  Write-Phase "Syncing latest Firefox main"
  Invoke-CheckedProcess -FilePath "git" -ArgumentList @("fetch", "origin") -WorkingDirectory $FirefoxSourceDir
  Invoke-CheckedProcess -FilePath "git" -ArgumentList @("reset", "--hard", "origin/main") -WorkingDirectory $FirefoxSourceDir
}

function Invoke-Mach {
  param([string[]]$MachArgs)

  $machPs1 = Join-Path $FirefoxSourceDir "mach.ps1"
  $mach = Join-Path $FirefoxSourceDir "mach"

  if (Test-Path -LiteralPath $machPs1) {
    Invoke-CheckedProcess -FilePath "powershell.exe" -ArgumentList @("-ExecutionPolicy", "Bypass", "-File", $machPs1) + $MachArgs -WorkingDirectory $FirefoxSourceDir
    return
  }

  if (Test-Path -LiteralPath $mach) {
    Invoke-CheckedProcess -FilePath $mach -ArgumentList $MachArgs -WorkingDirectory $FirefoxSourceDir
    return
  }

  throw "Could not find mach entry point under $FirefoxSourceDir."
}

function Get-DistBin {
  $json = & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $FirefoxSourceDir "mach.ps1") environment --format json
  $envInfo = $json | ConvertFrom-Json
  $distBin = Join-Path $envInfo.topobjdir "dist\bin"
  if (!(Test-Path -LiteralPath (Join-Path $distBin "firefox.exe"))) {
    throw "firefox.exe not found under dist\bin: $distBin"
  }

  return $distBin
}

function Install-WindowsWrapper {
  param([string]$DistBin)

  Write-Phase "Creating Windows wrapper"
  New-Item -ItemType Directory -Force -Path $WrapDir | Out-Null
  New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
  New-Item -ItemType Directory -Force -Path $AiTempDir | Out-Null

  $runPs1 = Join-Path $WrapDir "run.ps1"
  $runCmd = Join-Path $WrapDir "run.cmd"
  $gfxLog = Join-Path $WrapDir "run-gfx-log.cmd"
  $safeMode = Join-Path $WrapDir "run-safe-mode.cmd"
  $distForScript = $DistBin.Replace("'", "''")
  $profileForScript = $ProfileDir.Replace("'", "''")
  $tempForScript = $AiTempDir.Replace("'", "''")

  @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

`$ffbin = '$distForScript\firefox.exe'
`$profileDir = `$env:VOIDFOX_PROFILE_DIR
if ([string]::IsNullOrWhiteSpace(`$profileDir)) {
  `$profileDir = '$profileForScript'
}

if (`$env:VOIDFOX_LOG_GFX -eq "1") {
  `$aiTempDir = '$tempForScript'
  New-Item -ItemType Directory -Force -Path `$aiTempDir | Out-Null
  `$env:MOZ_LOG = if (`$env:MOZ_LOG) { `$env:MOZ_LOG } else { "PlatformDecoderModule:5,GfxInfo:5,Widget:3" }
  `$env:MOZ_LOG_FILE = if (`$env:MOZ_LOG_FILE) { `$env:MOZ_LOG_FILE } else { Join-Path `$aiTempDir "voidfox-windows-gfx.log" }
}

`$argsToFirefox = @()
if (`$env:VOIDFOX_SAFE_MODE -eq "1") {
  `$argsToFirefox += "--safe-mode"
}
`$argsToFirefox += @("--profile", `$profileDir)
`$argsToFirefox += `$args

& `$ffbin @argsToFirefox
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $runPs1 -Encoding UTF8

  @"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
"@ | Set-Content -LiteralPath $runCmd -Encoding ASCII

  @"
@echo off
set VOIDFOX_LOG_GFX=1
call "%~dp0run.cmd" %*
"@ | Set-Content -LiteralPath $gfxLog -Encoding ASCII

  @"
@echo off
set VOIDFOX_SAFE_MODE=1
call "%~dp0run.cmd" %*
"@ | Set-Content -LiteralPath $safeMode -Encoding ASCII

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  $shortcut.TargetPath = $runCmd
  $shortcut.WorkingDirectory = $WrapDir
  $shortcut.Description = "VOiDFOX Windows"
  $shortcut.IconLocation = Join-Path $DistBin "firefox.exe"
  $shortcut.Save()

  Write-Host "Run wrapper: $runCmd"
  Write-Host "Safe mode: $safeMode"
  Write-Host "Graphics log: $gfxLog"
  Write-Host "Shortcut: $ShortcutPath"
}

if ($Help) {
  Show-Usage
  exit 0
}

if ($Doctor) {
  exit (Invoke-Doctor)
}

Write-Phase "VOiDFOX Windows build"
if ((Invoke-Doctor) -ne 0) {
  throw "Doctor checks failed. Install the missing prerequisites before building."
}

if (!$NoClobber) {
  Write-Phase "Removing previous Windows build targets"
  foreach ($path in @($BuildDir, $WrapDir)) {
    if (!(Test-SafeChildPath -Path $path -Parent $env:USERPROFILE)) {
      throw "Refusing to remove unsafe path outside USERPROFILE: $path"
    }
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Recurse -Force
    }
  }
}

Ensure-FirefoxSource
Write-Phase "Writing Windows mozconfig"
Write-Mozconfig

if ($BootstrapOnly) {
  Write-Host "BootstrapOnly requested; stopping before clobber/build."
  exit 0
}

Write-Phase "Clobber and build"
if (!$NoClobber) {
  Invoke-Mach -MachArgs @("clobber")
}
Invoke-Mach -MachArgs @("build")

Write-Phase "Locating build output"
$distBin = Get-DistBin
Write-Host "Dist bin: $distBin"

Install-WindowsWrapper -DistBin $distBin

Write-Phase "Mission complete"
Write-Host "Run from shortcut: $ShortcutPath"
Write-Host "Or from terminal: $WrapDir\run.cmd"
