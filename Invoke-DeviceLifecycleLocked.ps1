#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateSet('ReportOnly', 'Quarantine', 'Enforce')]
    [string]$ModeOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($PSCommandPath) {
    Split-Path $PSCommandPath -Parent
}
else {
    $PWD.Path
}

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $scriptRoot 'DeviceLifecycle.Config.psd1'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$helpersPath = Join-Path $scriptRoot 'DeviceLifecycle.Helpers.psm1'
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Configuration helper module not found: $helpersPath"
}

Import-Module $helpersPath -Force
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$config = Resolve-DeviceLifecycleConfig -Config $config

if (-not (Test-Path -LiteralPath $config.InstallRoot)) {
    New-Item -Path $config.InstallRoot -ItemType Directory -Force | Out-Null
}

$lockPath = Join-Path $config.InstallRoot 'DeviceLifecycle.lock'
$lockStream = $null

try {
    try {
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        Write-Host "DeviceLifecycle run skipped because another execution holds the lock: $lockPath"
        exit 0
    }

    $invokePath = Join-Path $scriptRoot 'Invoke-DeviceLifecycle.ps1'
    if (-not (Test-Path -LiteralPath $invokePath)) {
        throw "Lifecycle script not found: $invokePath"
    }

    if ([string]::IsNullOrWhiteSpace($ModeOverride)) {
        & $invokePath -ConfigPath $ConfigPath
    }
    else {
        & $invokePath -ConfigPath $ConfigPath -ModeOverride $ModeOverride
    }
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}
