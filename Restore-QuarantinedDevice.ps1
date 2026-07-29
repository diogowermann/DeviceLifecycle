#requires -Version 5.1
#requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName,

    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'DeviceLifecycle.Config.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Load-State {
    param([string]$Path)

    $result = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $result
    }

    foreach ($item in @($raw | ConvertFrom-Json)) {
        [void]$result.Add($item)
    }

    return $result
}

function Save-State {
    param(
        [System.Collections.ArrayList]$State,
        [string]$Path
    )

    $temporaryPath = $Path + '.tmp'
    @($State) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

Import-Module (Join-Path $PSScriptRoot 'DeviceLifecycle.Helpers.psm1') -Force

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$config = Resolve-DeviceLifecycleConfig -Config $config
Import-Module ActiveDirectory -ErrorAction Stop

$computer = Get-ADComputer `
    -Identity $ComputerName `
    -Properties @(
        'Enabled',
        'ObjectGUID',
        'DistinguishedName',
        $config.StateAttribute
    ) `
    -ErrorAction Stop

if (
    -not ([string]$computer.DistinguishedName).EndsWith(
        ',' + [string]$config.QuarantineOU,
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "Computer is not inside the configured quarantine OU: $($computer.DistinguishedName)"
}

$state = Load-State -Path $config.StateFile
$stateRecord = @(
    $state | Where-Object {
        ([string]$_.AdObjectGuid).Equals(
            [string]$computer.ObjectGUID,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
) | Select-Object -First 1

$targetOu = if (
    $null -ne $stateRecord -and
    -not [string]::IsNullOrWhiteSpace([string]$stateRecord.OriginalParentDn)
) {
    [string]$stateRecord.OriginalParentDn
}
else {
    [string]$config.ActiveComputersOU
}

Get-ADOrganizationalUnit -Identity $targetOu -ErrorAction Stop | Out-Null

if ($PSCmdlet.ShouldProcess($ComputerName, "Move to $targetOu, enable AD account and clear lifecycle state")) {
    Move-ADObject `
        -Identity $computer.ObjectGUID `
        -TargetPath $targetOu

    Enable-ADAccount -Identity $computer.ObjectGUID

    Set-ADComputer `
        -Identity $computer.ObjectGUID `
        -Clear $config.StateAttribute

    if ($null -ne $stateRecord) {
        [void]$state.Remove($stateRecord)
        Save-State -State $state -Path $config.StateFile
    }

    if ([bool]$config.StartDeltaSyncAfterChanges) {
        try {
            Import-Module ADSync -ErrorAction Stop
            Start-ADSyncSyncCycle -PolicyType Delta | Out-Null
        }
        catch {
            Write-Warning "Computer restored, but Delta Sync could not be started: $($_.Exception.Message)"
        }
    }

    Write-Host "Computer restored in AD: $ComputerName"
    Write-Warning 'Validate hybrid join and Intune enrollment. Retire may require the device to be enrolled again.'
}
