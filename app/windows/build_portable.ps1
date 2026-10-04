[CmdletBinding()]
param(
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$WindowsDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDirectory = Split-Path -Parent $WindowsDirectory
$RepositoryDirectory = Split-Path -Parent $ProjectDirectory
$ReleaseDirectory = Join-Path $WindowsDirectory "releases"

# Prefer a project-local toolchain when one has been provisioned. This keeps
# the portable build reproducible without modifying the user's global PATH.
$LocalToolRoot = Join-Path $RepositoryDirectory ".toolchains"
$LocalPathEntries = @()
$LocalFlutterBin = Join-Path $LocalToolRoot "flutter\bin"
if (Test-Path (Join-Path $LocalFlutterBin "flutter.bat")) {
    $LocalPathEntries += $LocalFlutterBin
    # Cargokit's Windows build helper resolves Dart through FLUTTER_ROOT.
    # Adding flutter.bat to PATH alone is insufficient inside MSBuild's
    # custom-command environment.
    $env:FLUTTER_ROOT = Join-Path $LocalToolRoot "flutter"
    $env:PUB_CACHE = Join-Path $LocalToolRoot "pub-cache"
    # Keep Flutter/Dart telemetry and analysis-server state inside the
    # project-local toolchain. The build stays reproducible on locked-down
    # Windows accounts that cannot write user-level AppData directories.
    $LocalRoamingData = Join-Path $LocalToolRoot "appdata"
    $LocalAppData = Join-Path $LocalToolRoot "localappdata"
    New-Item -ItemType Directory -Force -Path $LocalRoamingData | Out-Null
    New-Item -ItemType Directory -Force -Path $LocalAppData | Out-Null
    $env:APPDATA = $LocalRoamingData
    $env:LOCALAPPDATA = $LocalAppData
    $env:FLUTTER_SUPPRESS_ANALYTICS = "true"
}
$LocalCargoHome = Join-Path $LocalToolRoot "cargo"
$LocalRustupHome = Join-Path $LocalToolRoot "rustup"
if (Test-Path (Join-Path $LocalCargoHome "bin\cargo.exe")) {
    $LocalPathEntries += Join-Path $LocalCargoHome "bin"
    $env:CARGO_HOME = $LocalCargoHome
    $env:RUSTUP_HOME = $LocalRustupHome
}
if (Test-Path (Join-Path $LocalToolRoot "nuget.exe")) {
    $LocalPathEntries += $LocalToolRoot
}
if ($LocalPathEntries.Count -gt 0) {
    $env:Path = ($LocalPathEntries -join ";") + ";" + $env:Path
}

Push-Location $ProjectDirectory
try {
    if (-not $SkipTests) {
        # Explicitly pass the visible test files instead of letting Flutter
        # discover every *_test.dart entry. Archives created on macOS can
        # contain hidden AppleDouble files named ._*_test.dart; those are
        # binary metadata, not Dart source, and crash the Windows test loader.
        $TestFiles = Get-ChildItem -Path "test" -Filter "*_test.dart" `
            -Recurse -File |
            Select-Object -ExpandProperty FullName
        if ($TestFiles.Count -eq 0) {
            throw "No Flutter test files were found."
        }
        & flutter test --no-pub @TestFiles
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter tests failed."
        }
    }

    & flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) {
        throw "Windows release build failed."
    }

    $VersionLine = Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(.+)$' |
        Select-Object -First 1
    if ($null -eq $VersionLine) {
        throw "Unable to read the application version from pubspec.yaml."
    }
    $Version = $VersionLine.Matches[0].Groups[1].Value.Trim()
    $VersionParts = $Version -split '\+', 2
    $BuildName = $VersionParts[0]
    $BuildNumber = if ($VersionParts.Count -gt 1) { $VersionParts[1] } else { "0" }

    $BuildCandidates = @(
        (Join-Path $ProjectDirectory "build\windows\x64\runner\Release"),
        (Join-Path $ProjectDirectory "build\windows\runner\Release")
    )
    $BuildDirectory = $BuildCandidates |
        Where-Object { Test-Path (Join-Path $_ "LumaLex.exe") } |
        Select-Object -First 1
    if ($null -eq $BuildDirectory) {
        throw "Unable to locate the built LumaLex.exe."
    }

    New-Item -ItemType Directory -Force -Path $ReleaseDirectory | Out-Null
    $PackageName = "LumaLex-$BuildName-build$BuildNumber-windows-x64-portable"
    $StageDirectory = Join-Path $ReleaseDirectory $PackageName
    $ZipPath = Join-Path $ReleaseDirectory "$PackageName.zip"
    $HashPath = "${ZipPath}.sha256.txt"

    if (Test-Path $StageDirectory) {
        Remove-Item -Recurse -Force $StageDirectory
    }
    if (Test-Path $ZipPath) {
        Remove-Item -Force $ZipPath
    }
    if (Test-Path $HashPath) {
        Remove-Item -Force $HashPath
    }

    New-Item -ItemType Directory -Path $StageDirectory | Out-Null
    Copy-Item -Path (Join-Path $BuildDirectory "*") `
        -Destination $StageDirectory -Recurse -Force
    Copy-Item -Path (Join-Path $WindowsDirectory "PORTABLE_README.txt") `
        -Destination $StageDirectory -Force

    $RequiredPaths = @(
        "LumaLex.exe",
        "flutter_windows.dll",
        "data\flutter_assets"
    )
    foreach ($RequiredPath in $RequiredPaths) {
        if (-not (Test-Path (Join-Path $StageDirectory $RequiredPath))) {
            throw "Portable package is incomplete: missing $RequiredPath"
        }
    }

    Compress-Archive -Path $StageDirectory -DestinationPath $ZipPath `
        -CompressionLevel Optimal
    # Compute the digest directly so packaging does not depend on
    # Microsoft.PowerShell.Utility being available for Get-FileHash.
    $Sha256 = [System.Security.Cryptography.SHA256]::Create()
    $ZipStream = [System.IO.File]::OpenRead($ZipPath)
    try {
        $HashBytes = $Sha256.ComputeHash($ZipStream)
        $Hash = [System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $ZipStream.Dispose()
        $Sha256.Dispose()
    }
    "$Hash  $PackageName.zip" | Set-Content -Encoding ascii -Path $HashPath

    Write-Host ""
    Write-Host "Portable Windows package: $ZipPath"
    Write-Host "SHA-256: $Hash"
    Write-Host "Extract the whole folder, then double-click LumaLex.exe."
}
finally {
    Pop-Location
}
