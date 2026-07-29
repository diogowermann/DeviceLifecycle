#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Completely removes the Device Lifecycle automation from the server.

.DESCRIPTION
    Removes the scheduled task, install directory, certificate and AD objects
    registered by this automation. PowerShell modules and the NuGet provider
    are intentionally preserved — they may be shared by other projects.

    Reads DeviceLifecycle.Config.psd1 to derive all names and paths,
    exactly as the install and initialize scripts do.

.PARAMETER ConfigPath
    Path to DeviceLifecycle.Config.psd1. Defaults to the script directory.

.PARAMETER SkipAdCleanup
    Skip removal of the Quarantine OU, Exclusion group and clearing of
    extensionAttribute15 state markers on AD computer objects.

.PARAMETER SkipCertificate
    Skip removal of the self-signed certificate from the local machine store.

.PARAMETER Force
    Skip all confirmation prompts. Use with extreme caution.

.EXAMPLE
    # Preview what would be removed:
    .\Uninstall-DeviceLifecycle.ps1 -WhatIf

.EXAMPLE
    # Full interactive removal:
    .\Uninstall-DeviceLifecycle.ps1

.EXAMPLE
    # Remove only the task and files, keep AD and certificate:
    .\Uninstall-DeviceLifecycle.ps1 -SkipAdCleanup -SkipCertificate

.EXAMPLE
    # Non-interactive full uninstall:
    .\Uninstall-DeviceLifecycle.ps1 -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'DeviceLifecycle.Config.psd1'),

    [Parameter()]
    [switch]$SkipAdCleanup,

    [Parameter()]
    [switch]$SkipCertificate,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '================================================================'
Write-Host '  Device Lifecycle Automation — Complete Uninstall'
Write-Host '================================================================'
Write-Host ''

if ($WhatIfPreference) {
    Write-Host '[WHATIF] Preview mode — no changes will be made.' -ForegroundColor Cyan
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath. Uninstall cannot continue."
    exit 1
}

$helpersPath = Join-Path $PSScriptRoot 'DeviceLifecycle.Helpers.psm1'
if (-not (Test-Path -LiteralPath $helpersPath)) {
    Write-Error "Helper module not found: $helpersPath. Uninstall cannot continue."
    exit 1
}

Import-Module $helpersPath -Force

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$config = Resolve-DeviceLifecycleConfig -Config $config

$orgName = [string]$config.OrganizationName

Write-Host "Configuration loaded for organization: $orgName" -ForegroundColor Green
Write-Host "  Install root   : $($config.InstallRoot)"
Write-Host "  Task name      : $($config.TaskName)"
Write-Host "  Cert subject   : $($config.CertificateSubjectName)"
Write-Host "  Quarantine OU  : $($config.QuarantineOU)"
Write-Host "  Exclusion group: $($config.ExclusionGroup)"
Write-Host "  State attribute: $($config.StateAttribute)"
Write-Host ''

if (-not $Force -and -not $WhatIfPreference) {
    Write-Warning 'This script will PERMANENTLY remove the Device Lifecycle automation.'
    Write-Warning 'Logs, reports, state files and the scheduled task will be deleted.'
    Write-Warning ''
    $proceed = Read-Host 'Type "UNINSTALL" (uppercase) to continue, or anything else to abort'
    if ($proceed -ne 'UNINSTALL') {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        exit 0
    }
    Write-Host ''
}

# Track overall success
$phases = [System.Collections.ArrayList]::new()
function Write-PhaseResult {
    param(
        [string]$Phase,
        [string]$Status,
        [string]$Detail = ''
    )
    $icon = if ($Status -eq 'OK') { '[+]' }
            elseif ($Status -eq 'SKIP') { '[~]' }
            elseif ($Status -eq 'WARN') { '[!]' }
            else { '[x]' }

    $color = switch ($Status) {
        'OK'   { 'Green' }
        'SKIP' { 'DarkGray' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'White' }
    }

    Write-Host ('  {0} {1} {2}' -f $icon, $Phase, $Detail) -ForegroundColor $color
    [void]$phases.Add([pscustomobject]@{ Phase = $Phase; Status = $Status; Detail = $Detail })
}
# ===========================================================================
# Phase 1 — Scheduled Task
# ===========================================================================

Write-Host '--- Phase 1: Scheduled Task ---' -ForegroundColor Cyan
$taskExists = Get-ScheduledTask -TaskName $config.TaskName -ErrorAction SilentlyContinue
if (-not $taskExists) {
    Write-PhaseResult -Phase 'Scheduled Task' -Status 'SKIP' -Detail 'Task not found'
}
else {
    if ($PSCmdlet.ShouldProcess($config.TaskName, 'Unregister scheduled task')) {
        try {
            Unregister-ScheduledTask -TaskName $config.TaskName -Confirm:$false
            Write-PhaseResult -Phase 'Scheduled Task' -Status 'OK' -Detail "Removed: $($config.TaskName)"
        }
        catch {
            Write-PhaseResult -Phase 'Scheduled Task' -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
}

# ===========================================================================
# Phase 2 — Install directory and all files
# ===========================================================================

Write-Host '--- Phase 2: Install Directory ---' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $config.InstallRoot)) {
    Write-PhaseResult -Phase 'Install Directory' -Status 'SKIP' -Detail 'Directory not found'
}
else {
    if ($PSCmdlet.ShouldProcess($config.InstallRoot, 'Delete install directory and all contents')) {
        try {
            Remove-Item -LiteralPath $config.InstallRoot -Recurse -Force
            Write-PhaseResult -Phase 'Install Directory' -Status 'OK' -Detail "Deleted: $($config.InstallRoot)"
        }
        catch {
            Write-PhaseResult -Phase 'Install Directory' -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
}

# ===========================================================================
# Phase 3 — Certificate
# ===========================================================================

Write-Host '--- Phase 3: Certificate ---' -ForegroundColor Cyan
if ($SkipCertificate) {
    Write-PhaseResult -Phase 'Certificate' -Status 'SKIP' -Detail 'Skipped by parameter'
}
else {
    $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $config.CertificateSubjectName } |
        Select-Object -First 1

    if (-not $cert) {
        Write-PhaseResult -Phase 'Certificate' -Status 'SKIP' -Detail 'Certificate not found in LocalMachine\My'
    }
    else {
        if ($PSCmdlet.ShouldProcess($cert.Thumbprint, 'Remove certificate from local machine store')) {
            try {
                $certPath = 'Cert:\LocalMachine\My\{0}' -f $cert.Thumbprint
                Remove-Item -LiteralPath $certPath -Force
                Write-PhaseResult -Phase 'Certificate' -Status 'OK' -Detail "Removed thumbprint: $($cert.Thumbprint)"
            }
            catch {
                Write-PhaseResult -Phase 'Certificate' -Status 'FAIL' -Detail $_.Exception.Message
            }
        }
    }
}
# ===========================================================================
# Phase 4 — Active Directory objects
# ===========================================================================

Write-Host '--- Phase 4: Active Directory Objects ---' -ForegroundColor Cyan
if ($SkipAdCleanup) {
    Write-PhaseResult -Phase 'AD Cleanup' -Status 'SKIP' -Detail 'Skipped by parameter'
}
else {
    $adAvailable = Get-Module -Name ActiveDirectory -ListAvailable -ErrorAction SilentlyContinue
    if (-not $adAvailable) {
        Write-PhaseResult -Phase 'AD Cleanup' -Status 'WARN' -Detail 'ActiveDirectory module not available — skipping AD cleanup'
    }
    else {
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue

        # 4a — Unprotect and remove Quarantine OU
        $quarantineOu = Get-ADOrganizationalUnit -Identity $config.QuarantineOU -ErrorAction SilentlyContinue
        if (-not $quarantineOu) {
            Write-PhaseResult -Phase 'AD: Quarantine OU' -Status 'SKIP' -Detail 'OU not found'
        }
        else {
            if ($PSCmdlet.ShouldProcess($config.QuarantineOU, 'Remove Quarantine OU')) {
                try {
                    Set-ADOrganizationalUnit `
                        -Identity $config.QuarantineOU `
                        -ProtectedFromAccidentalDeletion:$false `
                        -ErrorAction Stop

                    Remove-ADOrganizationalUnit `
                        -Identity $config.QuarantineOU `
                        -Confirm:$false `
                        -ErrorAction Stop

                    Write-PhaseResult -Phase 'AD: Quarantine OU' -Status 'OK' -Detail "Removed: $($config.QuarantineOU)"
                }
                catch {
                    if ($_.Exception.Message -match 'is not empty|has child') {
                        Write-PhaseResult -Phase 'AD: Quarantine OU' -Status 'WARN' -Detail 'OU contains child objects — manually remove contents first'
                    }
                    else {
                        Write-PhaseResult -Phase 'AD: Quarantine OU' -Status 'FAIL' -Detail $_.Exception.Message
                    }
                }
            }
        }

        # 4b — Remove Exclusion group
        $exclusionGroup = Get-ADGroup -Identity $config.ExclusionGroup -ErrorAction SilentlyContinue
        if (-not $exclusionGroup) {
            Write-PhaseResult -Phase 'AD: Exclusion Group' -Status 'SKIP' -Detail 'Group not found'
        }
        else {
            if ($PSCmdlet.ShouldProcess($config.ExclusionGroup, 'Remove exclusion group')) {
                try {
                    Remove-ADGroup `
                        -Identity $config.ExclusionGroup `
                        -Confirm:$false `
                        -ErrorAction Stop

                    Write-PhaseResult -Phase 'AD: Exclusion Group' -Status 'OK' -Detail "Removed: $($config.ExclusionGroup)"
                }
                catch {
                    Write-PhaseResult -Phase 'AD: Exclusion Group' -Status 'FAIL' -Detail $_.Exception.Message
                }
            }
        }
# 4c — Clear lifecycle state from extensionAttribute on all AD computers
        $stateAttr = [string]$config.StateAttribute
        Write-Host "  Scanning AD computers for '$stateAttr' lifecycle state markers ..."
        $affectedComputers = @(Get-ADComputer `
            -Filter "$stateAttr -like '*'" `
            -Properties @('Name', $stateAttr) `
            -ErrorAction SilentlyContinue)

        if ($affectedComputers.Count -eq 0) {
            Write-PhaseResult -Phase 'AD: State Attribute' -Status 'SKIP' -Detail 'No computers with lifecycle state markers found'
        }
        else {
            $count = $affectedComputers.Count
            $computerList = ($affectedComputers | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', '
            if ($count -gt 5) { $computerList += " ... (+$($count - 5) more)" }

            if (-not $Force -and -not $WhatIfPreference) {
                Write-Host "  Found $count computer(s) with lifecycle state markers."
                Write-Host "  Examples: $computerList"
                Write-Warning 'Clearing the lifecycle state does NOT undo quarantines or deletions.'
                Write-Warning 'Computers already quarantined may need manual recovery (see Restore-QuarantinedDevice.ps1).'
                $clearConfirm = Read-Host "  Type 'CLEAR' to clear $stateAttr on all $count computers, or anything else to skip"
                if ($clearConfirm -ne 'CLEAR') {
                    Write-PhaseResult -Phase 'AD: State Attribute' -Status 'SKIP' -Detail "Skipped by user ($count computers retain markers)"
                    $affectedComputers = @()
                }
            }

            $cleared = 0
            $failed = 0
            foreach ($computer in $affectedComputers) {
                if ($PSCmdlet.ShouldProcess($computer.Name, "Clear $stateAttr")) {
                    try {
                        Set-ADComputer `
                            -Identity $computer.ObjectGUID `
                            -Clear $stateAttr `
                            -ErrorAction Stop
                        $cleared++
                    }
                    catch {
                        $failed++
                        Write-Warning "  Failed to clear $stateAttr on $($computer.Name): $($_.Exception.Message)"
                    }
                }
            }

            if ($cleared -gt 0 -or $failed -gt 0) {
                $detail = "Cleared: $cleared"
                if ($failed -gt 0) { $detail += " | Failed: $failed" }
                $status = if ($failed -gt 0) { 'WARN' } else { 'OK' }
                Write-PhaseResult -Phase 'AD: State Attribute' -Status $status -Detail $detail
            }
        }
    }
}
# ===========================================================================
# Summary
# ===========================================================================

Write-Host ''
Write-Host '================================================================'
Write-Host '  Uninstall Summary'
Write-Host '================================================================'

$phases | Format-Table -Property Phase, Status, Detail -AutoSize -Wrap

$failures = @($phases | Where-Object { $_.Status -eq 'FAIL' })
$warnings = @($phases | Where-Object { $_.Status -eq 'WARN' })
$successes = @($phases | Where-Object { $_.Status -eq 'OK' })

Write-Host "Phases completed:  OK=$($successes.Count)  SKIP=$(@($phases | Where-Object { $_.Status -eq 'SKIP' }).Count)  WARN=$($warnings.Count)  FAIL=$($failures.Count)"

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host '[WHATIF] No changes were actually made.' -ForegroundColor Cyan
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Some phases failed. Review the errors above and retry if needed.' -ForegroundColor Red
}

if ($warnings.Count -gt 0 -and $failures.Count -eq 0) {
    Write-Host ''
    Write-Host 'Uninstall completed with warnings. Review the warnings above.' -ForegroundColor Yellow
}

if ($failures.Count -eq 0 -and $warnings.Count -eq 0 -and -not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'Device Lifecycle automation has been fully removed.' -ForegroundColor Green
}

exit $(if ($failures.Count -gt 0) { 1 } else { 0 })