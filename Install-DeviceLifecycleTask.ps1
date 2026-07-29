#requires -Version 5.1
#requires -RunAsAdministrator
#requires -Modules ScheduledTasks

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourceDirectory = $PSScriptRoot,

    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'DeviceLifecycle.Config.psd1'),

    [Parameter()]
    [switch]$ForceConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

Import-Module (Join-Path $PSScriptRoot 'DeviceLifecycle.Helpers.psm1') -Force

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$config = Resolve-DeviceLifecycleConfig -Config $config
$installRoot = [string]$config.InstallRoot

if (-not (Test-Path -LiteralPath $installRoot)) {
    New-Item -Path $installRoot -ItemType Directory -Force | Out-Null
}

$filesToCopy = @(
    'Invoke-DeviceLifecycle.ps1',
    'Initialize-DeviceLifecycle.ps1',
    'Install-DeviceLifecycleTask.ps1',
    'Test-DeviceLifecycle.ps1',
    'Restore-QuarantinedDevice.ps1',
    'DeviceLifecycle.Helpers.psm1',
    'README.md'
)

foreach ($fileName in $filesToCopy) {
    $sourcePath = Join-Path $SourceDirectory $fileName
    if (Test-Path -LiteralPath $sourcePath) {
        Copy-Item -LiteralPath $sourcePath -Destination $installRoot -Force
    }
}

$destinationConfig = Join-Path $installRoot 'DeviceLifecycle.Config.psd1'
if ($ForceConfig -or -not (Test-Path -LiteralPath $destinationConfig)) {
    Copy-Item -LiteralPath $ConfigPath -Destination $destinationConfig -Force
}
else {
    Write-Warning "Existing configuration preserved: $destinationConfig"
}

$scriptPath = Join-Path $installRoot 'Invoke-DeviceLifecycle.ps1'
$argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f `
    $scriptPath,
    $destinationConfig

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $argument `
    -WorkingDirectory $installRoot

$timeParts = ([string]$config.TaskTime).Split(':')
if ($timeParts.Count -ne 2) {
    throw "TaskTime must use HH:mm format. Current value: $($config.TaskTime)"
}

$triggerTime = Get-Date -Hour ([int]$timeParts[0]) -Minute ([int]$timeParts[1]) -Second 0
$trigger = New-ScheduledTaskTrigger -Daily -At $triggerTime

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $config.TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Daily lifecycle analysis and cleanup for hybrid AD, Entra ID and Intune devices.' `
    -Force | Out-Null

Write-Host "Scheduled task installed: $($config.TaskName)"
Write-Host "Execution identity: NT AUTHORITY\SYSTEM (domain identity: $env:COMPUTERNAME`$)"
Write-Host "Configuration: $destinationConfig"
Write-Host "Current mode: $($config.Mode)"
