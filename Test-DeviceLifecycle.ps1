#requires -Version 5.1
#requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'DeviceLifecycle.Config.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

Import-Module (Join-Path $PSScriptRoot 'DeviceLifecycle.Helpers.psm1') -Force

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$config = Resolve-DeviceLifecycleConfig -Config $config
$results = New-Object System.Collections.ArrayList
$graphConnected = $false

function Add-TestResult {
    param(
        [string]$Test,
        [bool]$Success,
        [string]$Detail
    )

    [void]$results.Add([pscustomobject]@{
        Test = $Test
        Success = $Success
        Detail = $Detail
    })
}

try {
    foreach ($moduleName in @(
        'ActiveDirectory',
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'Microsoft.Graph.DeviceManagement',
        'Microsoft.Graph.DeviceManagement.Enrollment'
    )) {
        try {
            Import-Module $moduleName -ErrorAction Stop
            Add-TestResult -Test "Module:$moduleName" -Success $true -Detail 'Loaded'
        }
        catch {
            Add-TestResult -Test "Module:$moduleName" -Success $false -Detail $_.Exception.Message
        }
    }

    try {
        Get-ADOrganizationalUnit -Identity $config.ActiveComputersOU -ErrorAction Stop | Out-Null
        Add-TestResult -Test 'AD:ActiveComputersOU' -Success $true -Detail $config.ActiveComputersOU
    }
    catch {
        Add-TestResult -Test 'AD:ActiveComputersOU' -Success $false -Detail $_.Exception.Message
    }

    try {
        Get-ADOrganizationalUnit -Identity $config.QuarantineOU -ErrorAction Stop | Out-Null
        Add-TestResult -Test 'AD:QuarantineOU' -Success $true -Detail $config.QuarantineOU
    }
    catch {
        Add-TestResult -Test 'AD:QuarantineOU' -Success $false -Detail $_.Exception.Message
    }

    try {
        Get-ADGroup -Identity $config.ExclusionGroup -ErrorAction Stop | Out-Null
        Add-TestResult -Test 'AD:ExclusionGroup' -Success $true -Detail $config.ExclusionGroup
    }
    catch {
        Add-TestResult -Test 'AD:ExclusionGroup' -Success $false -Detail $_.Exception.Message
    }

    try {
        $certificate = Get-Item -LiteralPath (
            'Cert:\LocalMachine\My\{0}' -f $config.CertificateThumbprint
        ) -ErrorAction Stop

        if (-not $certificate.HasPrivateKey) {
            throw 'Certificate exists but has no private key.'
        }

        Add-TestResult `
            -Test 'Certificate' `
            -Success $true `
            -Detail ("Expires {0:u}" -f $certificate.NotAfter)
    }
    catch {
        Add-TestResult -Test 'Certificate' -Success $false -Detail $_.Exception.Message
    }

    try {
        Connect-MgGraph `
            -TenantId $config.TenantId `
            -ClientId $config.ClientId `
            -CertificateThumbprint $config.CertificateThumbprint `
            -NoWelcome

        $graphConnected = $true
        Add-TestResult -Test 'Graph:Authentication' -Success $true -Detail 'App-only connection established'
    }
    catch {
        Add-TestResult -Test 'Graph:Authentication' -Success $false -Detail $_.Exception.Message
    }

    if ($graphConnected) {
        try {
            Get-MgDevice -Top 1 -Property @('id', 'deviceId', 'onPremisesSecurityIdentifier') | Out-Null
            Add-TestResult -Test 'Graph:EntraDevices' -Success $true -Detail 'Read succeeded'
        }
        catch {
            Add-TestResult -Test 'Graph:EntraDevices' -Success $false -Detail $_.Exception.Message
        }

        try {
            Get-MgDeviceManagementManagedDevice `
                -Top 1 `
                -Property @('id', 'azureADDeviceId', 'lastSyncDateTime') | Out-Null

            Add-TestResult -Test 'Graph:IntuneDevices' -Success $true -Detail 'Read succeeded'
        }
        catch {
            Add-TestResult -Test 'Graph:IntuneDevices' -Success $false -Detail $_.Exception.Message
        }

        try {
            Get-MgDeviceManagementWindowsAutopilotDeviceIdentity `
                -Top 1 `
                -Property @('id', 'azureActiveDirectoryDeviceId') | Out-Null

            Add-TestResult -Test 'Graph:Autopilot' -Success $true -Detail 'Read succeeded'
        }
        catch {
            Add-TestResult -Test 'Graph:Autopilot' -Success $false -Detail $_.Exception.Message
        }
    }

    try {
        Import-Module ADSync -ErrorAction Stop
        Get-ADSyncScheduler | Out-Null
        Add-TestResult -Test 'EntraConnect:ADSync' -Success $true -Detail 'Scheduler accessible'
    }
    catch {
        Add-TestResult -Test 'EntraConnect:ADSync' -Success $false -Detail $_.Exception.Message
    }
}
finally {
    if ($graphConnected) {
        Disconnect-MgGraph | Out-Null
    }
}

$results | Format-Table -AutoSize

if (@($results | Where-Object { -not $_.Success }).Count -gt 0) {
    exit 1
}

exit 0
