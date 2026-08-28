function Resolve-DeviceLifecycleConfig {
    <#
    .SYNOPSIS
        Resolves organization-specific configuration defaults from OrganizationName.

    .DESCRIPTION
        Derives InstallRoot, StateFile, LogDirectory, ReportDirectory, TaskName,
        SnapshotTaskName, CertificateSubjectName and CertificateFileName from the
        OrganizationName key when the corresponding keys are empty or not present
        in the config.

        Explicit values in the .psd1 always take precedence over derivation.
    #>

    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $org = [string]$Config.OrganizationName

    if ([string]::IsNullOrWhiteSpace([string]$Config.InstallRoot)) {
        $Config.InstallRoot = "C:\ProgramData\$org\DeviceLifecycle"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.StateFile)) {
        $Config.StateFile = Join-Path $Config.InstallRoot 'state.json'
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.LogDirectory)) {
        $Config.LogDirectory = Join-Path $Config.InstallRoot 'Logs'
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.ReportDirectory)) {
        $Config.ReportDirectory = Join-Path $Config.InstallRoot 'Reports'
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.TaskName)) {
        $Config.TaskName = "$org - Device Lifecycle"
    }

    if (-not $Config.ContainsKey('SnapshotTaskName') -or [string]::IsNullOrWhiteSpace([string]$Config.SnapshotTaskName)) {
        $Config.SnapshotTaskName = "$org - Device Lifecycle Snapshot"
    }

    if (-not $Config.ContainsKey('SnapshotIntervalMinutes') -or [int]$Config.SnapshotIntervalMinutes -le 0) {
        $Config.SnapshotIntervalMinutes = 30
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.CertificateSubjectName)) {
        $Config.CertificateSubjectName = "CN=$org Device Lifecycle Automation"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.CertificateFileName)) {
        $Config.CertificateFileName = "$org-DeviceLifecycle.cer"
    }

    return $Config
}

function Get-DeviceLifecycleActivityDecision {
    <#
    .SYNOPSIS
        Classifies lifecycle activity using only sources that actually exist.

    .DESCRIPTION
        AD activity is always required. Entra and Intune activity timestamps are
        required only when a unique, valid record was correlated in that source.
        A missing cloud record is therefore treated as unavailable evidence, not
        as a correlation error. Ambiguity and identity consistency checks remain
        the responsibility of the caller before this function is invoked.
    #>

    param(
        [Parameter()]$AdLastLogonUtc,
        [Parameter(Mandatory)][bool]$EntraRecordPresent,
        [Parameter()]$EntraLastActivityUtc,
        [Parameter(Mandatory)][bool]$IntuneRecordPresent,
        [Parameter()]$IntuneLastSyncUtc,
        [Parameter(Mandatory)][datetime]$ReportCutoff,
        [Parameter(Mandatory)][datetime]$QuarantineCutoff
    )

    $missingAvailableTimestamp = (
        $null -eq $AdLastLogonUtc -or
        ($EntraRecordPresent -and $null -eq $EntraLastActivityUtc) -or
        ($IntuneRecordPresent -and $null -eq $IntuneLastSyncUtc)
    )

    if ($missingAvailableTimestamp) {
        return [pscustomobject]@{
            Status = 'ManualReview'
            RecommendedAction = 'None'
            Reason = 'MissingActivityTimestamp'
        }
    }

    $allAvailableSignalsOld = (
        $AdLastLogonUtc -le $QuarantineCutoff -and
        (-not $EntraRecordPresent -or $EntraLastActivityUtc -le $QuarantineCutoff) -and
        (-not $IntuneRecordPresent -or $IntuneLastSyncUtc -le $QuarantineCutoff)
    )

    if ($allAvailableSignalsOld) {
        return [pscustomobject]@{
            Status = 'QuarantineCandidate'
            RecommendedAction = 'Quarantine'
            Reason = $null
        }
    }

    $availableDates = @(
        $AdLastLogonUtc,
        $(if ($EntraRecordPresent) { $EntraLastActivityUtc } else { $null }),
        $(if ($IntuneRecordPresent) { $IntuneLastSyncUtc } else { $null })
    ) | Where-Object { $null -ne $_ }

    $latestActivityUtc = $availableDates | Sort-Object -Descending | Select-Object -First 1
    if ($null -ne $latestActivityUtc -and $latestActivityUtc -le $ReportCutoff) {
        return [pscustomobject]@{
            Status = 'Warning'
            RecommendedAction = 'Monitor'
            Reason = 'ApproachingQuarantineThreshold'
        }
    }

    return [pscustomobject]@{
        Status = 'Active'
        RecommendedAction = 'None'
        Reason = $null
    }
}
