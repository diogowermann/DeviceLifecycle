function Resolve-DeviceLifecycleConfig {
    <#
    .SYNOPSIS
        Resolves organization-specific configuration defaults from OrganizationName.

    .DESCRIPTION
        Derives InstallRoot, StateFile, LogDirectory, ReportDirectory, TaskName,
        CertificateSubjectName and CertificateFileName from the OrganizationName
        key when the corresponding keys are empty or not present in the config.

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

    if ([string]::IsNullOrWhiteSpace([string]$Config.CertificateSubjectName)) {
        $Config.CertificateSubjectName = "CN=$org Device Lifecycle Automation"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.CertificateFileName)) {
        $Config.CertificateFileName = "$org-DeviceLifecycle.cer"
    }

    return $Config
}