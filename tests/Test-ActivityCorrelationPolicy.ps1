$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DeviceLifecycle.Helpers.psm1') -Force

$now = [datetime]'2026-08-28T12:00:00Z'
$reportCutoff = $now.AddDays(-75)
$quarantineCutoff = $now.AddDays(-90)

function Assert-Decision {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedStatus,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $result = Get-DeviceLifecycleActivityDecision @Arguments
    if ([string]$result.Status -ne $ExpectedStatus) {
        throw "$Name failed. Expected=$ExpectedStatus Actual=$($result.Status)"
    }

    Write-Host "PASS: $Name -> $($result.Status)"
}

$base = @{
    ReportCutoff = $reportCutoff
    QuarantineCutoff = $quarantineCutoff
}

Assert-Decision -Name 'AD-only stale device is quarantined' -ExpectedStatus 'QuarantineCandidate' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-200)
    EntraRecordPresent = $false
    EntraLastActivityUtc = $null
    IntuneRecordPresent = $false
    IntuneLastSyncUtc = $null
})

Assert-Decision -Name 'AD-only recent device stays active' -ExpectedStatus 'Active' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-10)
    EntraRecordPresent = $false
    EntraLastActivityUtc = $null
    IntuneRecordPresent = $false
    IntuneLastSyncUtc = $null
})

Assert-Decision -Name 'Recent Entra activity prevents quarantine' -ExpectedStatus 'Active' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-200)
    EntraRecordPresent = $true
    EntraLastActivityUtc = $now.AddDays(-5)
    IntuneRecordPresent = $false
    IntuneLastSyncUtc = $null
})

Assert-Decision -Name 'Missing Intune record does not block stale AD and Entra' -ExpectedStatus 'QuarantineCandidate' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-200)
    EntraRecordPresent = $true
    EntraLastActivityUtc = $now.AddDays(-150)
    IntuneRecordPresent = $false
    IntuneLastSyncUtc = $null
})

Assert-Decision -Name 'Recent Intune activity prevents quarantine' -ExpectedStatus 'Active' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-200)
    EntraRecordPresent = $true
    EntraLastActivityUtc = $now.AddDays(-150)
    IntuneRecordPresent = $true
    IntuneLastSyncUtc = $now.AddDays(-1)
})

Assert-Decision -Name 'Existing Entra record without timestamp requires review' -ExpectedStatus 'ManualReview' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-200)
    EntraRecordPresent = $true
    EntraLastActivityUtc = $null
    IntuneRecordPresent = $false
    IntuneLastSyncUtc = $null
})

Assert-Decision -Name 'Existing Intune record without timestamp requires review' -ExpectedStatus 'ManualReview' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-200)
    EntraRecordPresent = $false
    EntraLastActivityUtc = $null
    IntuneRecordPresent = $true
    IntuneLastSyncUtc = $null
})

Assert-Decision -Name 'Intermediate inactivity remains warning' -ExpectedStatus 'Warning' -Arguments ($base + @{
    AdLastLogonUtc = $now.AddDays(-80)
    EntraRecordPresent = $false
    EntraLastActivityUtc = $null
    IntuneRecordPresent = $false
    IntuneLastSyncUtc = $null
})
