#requires -Version 5.1
#requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateSet('ReportOnly', 'Quarantine', 'Enforce')]
    [string]$ModeOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the script root and configuration path with fallbacks for remoting
# or hosting contexts where $PSScriptRoot may not be available.
$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($PSCommandPath) {
    Split-Path $PSCommandPath -Parent
}
else {
    $PWD.Path
}

if (-not $ConfigPath -and $scriptRoot) {
    $ConfigPath = Join-Path $scriptRoot 'DeviceLifecycle.Config.psd1'
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

function Convert-ToUtcDate {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ([datetime]$Value).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-MaxDate {
    param([object[]]$Dates)

    $validDates = @($Dates | Where-Object { $null -ne $_ })
    if ($validDates.Count -eq 0) {
        return $null
    }

    return ($validDates | Sort-Object -Descending | Select-Object -First 1)
}

function Test-DnWithin {
    param(
        [Parameter(Mandatory)][string]$DistinguishedName,
        [Parameter(Mandatory)][string]$ContainerDn
    )

    return $DistinguishedName.EndsWith(
        ',' + $ContainerDn,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-ParentDn {
    param([Parameter(Mandatory)][string]$DistinguishedName)

    return ($DistinguishedName -replace '^[^,]+,', '')
}

function Add-ToIndex {
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter()][string]$Key,
        [Parameter(Mandatory)]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return
    }

    $normalizedKey = $Key.Trim().ToLowerInvariant()
    if (-not $Index.ContainsKey($normalizedKey)) {
        $Index[$normalizedKey] = New-Object System.Collections.ArrayList
    }

    [void]$Index[$normalizedKey].Add($Value)
}

function Get-IndexValues {
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter()][string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return @()
    }

    $normalizedKey = $Key.Trim().ToLowerInvariant()
    if (-not $Index.ContainsKey($normalizedKey)) {
        return @()
    }

    return @($Index[$normalizedKey])
}

function Load-State {
    param([Parameter(Mandatory)][string]$Path)

    $result = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) {
        return ,$result
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ,$result
    }

    $parsed = $raw | ConvertFrom-Json
    foreach ($item in @($parsed)) {
        [void]$result.Add($item)
    }

    return ,$result
}

function Save-State {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$State,
        [Parameter(Mandatory)][string]$Path
    )

    $temporaryPath = $Path + '.tmp'
    $stateItems = [object[]]$State.ToArray()

    # An empty collection produces no pipeline output. In that situation,
    # Set-Content would never run and the temporary file would not exist.
    $json = if ($stateItems.Count -eq 0) {
        '[]'
    }
    else {
        ConvertTo-Json -InputObject $stateItems -Depth 8
    }

    Set-Content `
        -LiteralPath $temporaryPath `
        -Value $json `
        -Encoding UTF8 `
        -Force

    if (-not (Test-Path -LiteralPath $temporaryPath)) {
        throw "Temporary state file was not created: $temporaryPath"
    }

    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-StateRecord {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$State,
        [Parameter(Mandatory)][string]$AdObjectGuid
    )

    return (
        @(
            $State | Where-Object {
                ([string]$_.AdObjectGuid).Equals(
                    $AdObjectGuid,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
        ) | Select-Object -First 1
    )
}

function New-StateRecord {
    param(
        [Parameter(Mandatory)]$Computer,
        [Parameter()]$EntraDevice,
        [Parameter()]$IntuneDevice,
        [Parameter(Mandatory)][datetime]$QuarantinedAtUtc,
        [Parameter()]$AdLastLogonUtc,
        [Parameter()]$EntraLastActivityUtc,
        [Parameter()]$IntuneLastSyncUtc
    )

    return [pscustomobject]@{
        ComputerName = [string]$Computer.Name
        AdObjectGuid = [string]$Computer.ObjectGUID
        AdSid = [string]$Computer.SID
        OriginalParentDn = $(Get-ParentDn -DistinguishedName ([string]$Computer.DistinguishedName))
        QuarantinedAtUtc = $QuarantinedAtUtc.ToString('o')
        RetireRequestedAtUtc = $null
        AdDeletedAtUtc = $null
        IntuneDeletedAtUtc = $null
        EntraDeletedAtUtc = $null
        EntraObjectId = $(if ($null -ne $EntraDevice) { [string]$EntraDevice.Id } else { $null })
        EntraDeviceId = $(if ($null -ne $EntraDevice) { [string]$EntraDevice.DeviceId } else { $null })
        IntuneManagedDeviceId = $(if ($null -ne $IntuneDevice) { [string]$IntuneDevice.Id } else { $null })
        SerialNumber = $(if ($null -ne $IntuneDevice) { [string]$IntuneDevice.SerialNumber } else { $null })
        LastKnownAdLogonUtc = $(if ($null -ne $AdLastLogonUtc) { ([datetime]$AdLastLogonUtc).ToString('o') } else { $null })
        LastKnownEntraActivityUtc = $(if ($null -ne $EntraLastActivityUtc) { ([datetime]$EntraLastActivityUtc).ToString('o') } else { $null })
        LastKnownIntuneSyncUtc = $(if ($null -ne $IntuneLastSyncUtc) { ([datetime]$IntuneLastSyncUtc).ToString('o') } else { $null })
        LastError = $null
        LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Get-QuarantineTimestamp {
    param(
        [Parameter()]$StateRecord,
        [Parameter()]$Computer,
        [Parameter(Mandatory)][string]$StateAttribute
    )

    if ($null -ne $StateRecord -and -not [string]::IsNullOrWhiteSpace([string]$StateRecord.QuarantinedAtUtc)) {
        return Convert-ToUtcDate -Value $StateRecord.QuarantinedAtUtc
    }

    $property = $Computer.PSObject.Properties[$StateAttribute]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return $null
    }

    $marker = [string]$property.Value
    if ($marker -match '^DeviceLifecycle\|QuarantinedUtc=(.+)$') {
        return Convert-ToUtcDate -Value $Matches[1]
    }

    return $null
}

function Test-ActionBudget {
    return ($script:ActionCount -lt [int]$script:Config.MaximumActionsPerRun)
}

function Register-ChangedDevice {
    param(
        [Parameter()]
        [bool]$RequiresSync = $true
    )

    $script:ActionCount++
    if ($RequiresSync) {
        $script:SyncRequired = $true
    }
}

function Test-NamePattern {
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter()]
        [object[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    foreach ($pattern in @($Patterns)) {
        $patternText = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($patternText)) {
            continue
        }

        if ($Name -like $patternText) {
            return $true
        }
    }

    return $false
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$helpersPath = Join-Path $scriptRoot 'DeviceLifecycle.Helpers.psm1'
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Configuration helper module not found: $helpersPath"
}

Import-Module $helpersPath -Force

$script:Config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$script:Config = Resolve-DeviceLifecycleConfig -Config $script:Config

if (-not [string]::IsNullOrWhiteSpace($ModeOverride)) {
    $script:Config.Mode = $ModeOverride
}

$validModes = @('ReportOnly', 'Quarantine', 'Enforce')
if ($script:Config.Mode -notin $validModes) {
    throw "Invalid Mode in configuration: $($script:Config.Mode)"
}

Ensure-Directory -Path $script:Config.InstallRoot
Ensure-Directory -Path $script:Config.LogDirectory
Ensure-Directory -Path $script:Config.ReportDirectory

$runTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile = Join-Path $script:Config.LogDirectory "DeviceLifecycle-$runTimestamp.log"
$reportPath = Join-Path $script:Config.ReportDirectory "DeviceLifecycle-$runTimestamp.csv"
$latestReportPath = Join-Path $script:Config.ReportDirectory 'DeviceLifecycle-Latest.csv'

$script:ActionCount = 0
$script:SyncRequired = $false
$report = New-Object System.Collections.ArrayList
$state = Load-State -Path $script:Config.StateFile
if ($null -eq $state) {
    $state = New-Object System.Collections.ArrayList
}
$graphConnected = $false

Write-Log -Level INFO -Message "Starting device lifecycle run. Mode=$($script:Config.Mode)."

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    foreach ($moduleName in @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'Microsoft.Graph.DeviceManagement'
    )) {
        Import-Module $moduleName -ErrorAction Stop
    }

    $certificate = Get-Item -LiteralPath (
        'Cert:\LocalMachine\My\{0}' -f $script:Config.CertificateThumbprint
    ) -ErrorAction Stop

    if (-not $certificate.HasPrivateKey) {
        throw 'The configured certificate does not have a private key in LocalMachine\My.'
    }

    Connect-MgGraph `
        -TenantId $script:Config.TenantId `
        -ClientId $script:Config.ClientId `
        -CertificateThumbprint $script:Config.CertificateThumbprint `
        -NoWelcome

    $graphConnected = $true
    Write-Log -Level INFO -Message 'Connected to Microsoft Graph using application authentication.'

    $quarantineOuObject = Get-ADOrganizationalUnit `
        -Identity $script:Config.QuarantineOU `
        -ErrorAction Stop

    $activeOuObject = Get-ADOrganizationalUnit `
        -Identity $script:Config.ActiveComputersOU `
        -ErrorAction Stop

    $schemaNamingContext = (Get-ADRootDSE).SchemaNamingContext
    $stateAttributeExists = Get-ADObject `
        -SearchBase $schemaNamingContext `
        -LDAPFilter ('(lDAPDisplayName={0})' -f $script:Config.StateAttribute) `
        -ErrorAction Stop

    if ($null -eq $stateAttributeExists) {
        throw "AD state attribute not found in schema: $($script:Config.StateAttribute)"
    }

    $adProperties = @(
        'LastLogonDate',
        'whenCreated',
        'Enabled',
        'OperatingSystem',
        'SID',
        'ObjectGUID',
        'ProtectedFromAccidentalDeletion',
        'PrimaryGroupID',
        $script:Config.StateAttribute
    )

    $adComputers = @(
        Get-ADComputer `
            -Filter * `
            -SearchBase $script:Config.ActiveComputersOU `
            -SearchScope Subtree `
            -Properties $adProperties
    )

    Write-Log -Level INFO -Message "AD computers loaded: $($adComputers.Count)."

    $excludedAdGuids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    try {
        $exclusionGroup = Get-ADGroup -Identity $script:Config.ExclusionGroup -ErrorAction Stop
        foreach ($member in @(Get-ADGroupMember -Identity $exclusionGroup -Recursive)) {
            if ($member.ObjectClass -eq 'computer') {
                [void]$excludedAdGuids.Add([string]$member.ObjectGUID)
            }
        }
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        Write-Log -Level WARN -Message "Exclusion group not found: $($script:Config.ExclusionGroup)."
    }

    $entraDevices = @(
        Get-MgDevice `
            -All `
            -Property @(
                'id',
                'deviceId',
                'displayName',
                'accountEnabled',
                'approximateLastSignInDateTime',
                'onPremisesSecurityIdentifier',
                'onPremisesSyncEnabled',
                'trustType',
                'operatingSystem',
                'registrationDateTime'
            )
    )

    $intuneDevices = @(
        Get-MgDeviceManagementManagedDevice `
            -All `
            -Property @(
                'id',
                'deviceName',
                'azureADDeviceId',
                'lastSyncDateTime',
                'enrolledDateTime',
                'operatingSystem',
                'serialNumber',
                'managementAgent',
                'managementState'
            )
    )

    Write-Log -Level INFO -Message (
        "Cloud records loaded. Entra={0}; Intune={1}." -f
        $entraDevices.Count,
        $intuneDevices.Count
    )

    $entraBySid = @{}
    $entraByObjectId = @{}
    foreach ($device in $entraDevices) {
        Add-ToIndex -Index $entraBySid -Key ([string]$device.OnPremisesSecurityIdentifier) -Value $device
        Add-ToIndex -Index $entraByObjectId -Key ([string]$device.Id) -Value $device
    }

    $intuneByAzureDeviceId = @{}
    $intuneByObjectId = @{}
    foreach ($device in $intuneDevices) {
        Add-ToIndex -Index $intuneByAzureDeviceId -Key ([string]$device.AzureADDeviceId) -Value $device
        Add-ToIndex -Index $intuneByObjectId -Key ([string]$device.Id) -Value $device
    }

    $nowUtc = [datetime]::UtcNow
    $reportCutoff = $nowUtc.AddDays(-[int]$script:Config.ReportAfterDays)
    $quarantineCutoff = $nowUtc.AddDays(-[int]$script:Config.QuarantineAfterDays)
    $minimumCreatedCutoff = $nowUtc.AddDays(-[int]$script:Config.MinimumObjectAgeDays)

    foreach ($computer in $adComputers) {
        $status = 'Active'
        $recommendedAction = 'None'
        $reason = $null
        $actionTaken = 'None'
        $actionError = $null
        $entraDevice = $null
        $intuneDevice = $null
        $inQuarantine = Test-DnWithin `
            -DistinguishedName ([string]$computer.DistinguishedName) `
            -ContainerDn $script:Config.QuarantineOU

        $adObjectGuid = [string]$computer.ObjectGUID
        $stateRecord = Get-StateRecord -State $state -AdObjectGuid $adObjectGuid
        $stateAttributeProperty = $computer.PSObject.Properties[$script:Config.StateAttribute]
        $stateAttributeValue = if ($null -ne $stateAttributeProperty) {
            [string]$stateAttributeProperty.Value
        }
        else {
            $null
        }
        $adCreatedUtc = Convert-ToUtcDate -Value $computer.whenCreated
        $isNewComputerObject = (
            $null -ne $adCreatedUtc -and
            $adCreatedUtc -gt $minimumCreatedCutoff
        )

        if ($computer.Name.Equals($env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase)) {
            $status = 'Excluded'
            $reason = 'ExecutionServer'
        }
        elseif ($excludedAdGuids.Contains($adObjectGuid)) {
            $status = 'Excluded'
            $reason = 'ExclusionGroup'
        }
        elseif (@($script:Config.ExcludedComputerNames) -contains [string]$computer.Name) {
            $status = 'Excluded'
            $reason = 'ExcludedComputerName'
        }
        elseif (Test-NamePattern -Name ([string]$computer.Name) -Patterns $script:Config.ExcludedNamePatterns) {
            $status = 'Excluded'
            $reason = 'ExcludedNamePattern'
        }
        elseif (([int]$computer.PrimaryGroupID -eq 516) -or ([int]$computer.PrimaryGroupID -eq 521)) {
            $status = 'Excluded'
            $reason = 'DomainController'
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$computer.OperatingSystem)) {
            # A computer object without an operating-system value can be a
            # prestaged, incomplete or stale AD object. It must never become
            # eligible for an automatic destructive action.
            $status = 'ManualReview'
            $reason = 'MissingOperatingSystem'
        }
        elseif (Test-NamePattern -Name ([string]$computer.OperatingSystem) -Patterns $script:Config.ExcludedOperatingSystemPatterns) {
            $status = 'Excluded'
            $reason = 'ServerOperatingSystem'
        }
        elseif ([bool]$computer.ProtectedFromAccidentalDeletion) {
            $status = 'ManualReview'
            $reason = 'ProtectedFromAccidentalDeletion'
        }
        elseif (
            -not [string]::IsNullOrWhiteSpace($stateAttributeValue) -and
            -not $stateAttributeValue.StartsWith(
                'DeviceLifecycle|',
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $status = 'ManualReview'
            $reason = 'StateAttributeAlreadyInUse'
        }
        elseif (-not [bool]$computer.Enabled -and -not $inQuarantine) {
            $status = 'ManualReview'
            $reason = 'AlreadyDisabledOutsideQuarantine'
        }
        elseif ([bool]$computer.Enabled -and $inQuarantine) {
            $status = 'ManualReview'
            $reason = 'EnabledInQuarantine'
        }

        $entraMatches = @()
        $intuneMatches = @()
        $intuneExpectedMissingAfterRetire = $false

        if ($status -notin @('Excluded', 'ManualReview')) {
            $entraMatches = @(
                Get-IndexValues -Index $entraBySid -Key ([string]$computer.SID)
            )

            if ($entraMatches.Count -gt 1) {
                $status = 'ManualReview'
                $reason = 'AmbiguousEntraMatch'
            }
            elseif ($entraMatches.Count -eq 1) {
                $entraDevice = $entraMatches[0]

                if (
                    -not ([string]$entraDevice.DisplayName).Equals(
                        [string]$computer.Name,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    $status = 'ManualReview'
                    $reason = 'EntraNameMismatch'
                }
                elseif ([string]$entraDevice.TrustType -ne 'ServerAd') {
                    $status = 'ManualReview'
                    $reason = 'EntraDeviceIsNotHybridJoined'
                }
                elseif ($entraDevice.OnPremisesSyncEnabled -ne $true) {
                    $status = 'ManualReview'
                    $reason = 'EntraDeviceNotCurrentlySynced'
                }
            }
        }

        if ($status -notin @('Excluded', 'ManualReview') -and $null -ne $entraDevice) {
            $intuneMatches = @(
                Get-IndexValues `
                    -Index $intuneByAzureDeviceId `
                    -Key ([string]$entraDevice.DeviceId)
            )

            if ($intuneMatches.Count -eq 0) {
                if (
                    $inQuarantine -and
                    $null -ne $stateRecord -and
                    -not [string]::IsNullOrWhiteSpace([string]$stateRecord.RetireRequestedAtUtc)
                ) {
                    # A successful Retire can remove the managedDevice record.
                    # The state captured at quarantine is used for audit.
                    $intuneExpectedMissingAfterRetire = $true
                }
            }
            elseif ($intuneMatches.Count -gt 1) {
                $status = 'ManualReview'
                $reason = 'AmbiguousIntuneMatch'
            }
            else {
                $intuneDevice = $intuneMatches[0]
            }
        }

        # MinimumObjectAgeDays is a lifecycle action guard, not an inventory
        # filter. New computer objects still receive normal Entra/Intune
        # correlation above so downstream inventory has complete evidence.
        if ($isNewComputerObject -and $status -notin @('Excluded', 'ManualReview')) {
            $status = 'Excluded'
            $recommendedAction = 'None'
            $reason = 'NewComputerObject'
        }

        $adLastLogonUtc = Convert-ToUtcDate -Value $computer.LastLogonDate
        $entraLastActivityUtc = if ($null -ne $entraDevice) {
            Convert-ToUtcDate -Value $entraDevice.ApproximateLastSignInDateTime
        }
        else {
            $null
        }
        $intuneLastSyncUtc = if ($null -ne $intuneDevice) {
            Convert-ToUtcDate -Value $intuneDevice.LastSyncDateTime
        }
        elseif ($intuneExpectedMissingAfterRetire -and $null -ne $stateRecord) {
            Convert-ToUtcDate -Value $stateRecord.LastKnownIntuneSyncUtc
        }
        else {
            $null
        }

        $latestActivityUtc = Get-MaxDate -Dates @(
            $adLastLogonUtc,
            $entraLastActivityUtc,
            $intuneLastSyncUtc
        )

        $daysSinceLatestActivity = if ($null -ne $latestActivityUtc) {
            [math]::Floor(($nowUtc - $latestActivityUtc).TotalDays)
        }
        else {
            $null
        }

        if ($status -notin @('Excluded', 'ManualReview')) {
            if ($inQuarantine) {
                $quarantinedAtUtc = Get-QuarantineTimestamp `
                    -StateRecord $stateRecord `
                    -Computer $computer `
                    -StateAttribute $script:Config.StateAttribute

                if ($null -eq $quarantinedAtUtc) {
                    $status = 'ManualReview'
                    $reason = 'MissingQuarantineState'
                }
                else {
                    $quarantineAgeDays = [math]::Floor(($nowUtc - $quarantinedAtUtc).TotalDays)

                    if (
                        $null -ne $latestActivityUtc -and
                        $latestActivityUtc -gt $quarantinedAtUtc
                    ) {
                        # This can be the expected Intune check-in that receives
                        # the Retire command. It is reported, but the AD
                        # quarantine remains the authoritative lifecycle state.
                        $reason = 'CloudActivityObservedAfterQuarantine'
                    }

                    if ($quarantineAgeDays -ge [int]$script:Config.DeleteAfterQuarantineDays) {
                        $status = 'DeleteCandidate'
                        $recommendedAction = 'Delete'
                    }
                    else {
                        $status = 'Quarantined'
                        $recommendedAction = 'Wait'
                    }
                }
            }
            else {
                $activityDecision = Get-DeviceLifecycleActivityDecision `
                    -AdLastLogonUtc $adLastLogonUtc `
                    -EntraRecordPresent:($null -ne $entraDevice) `
                    -EntraLastActivityUtc $entraLastActivityUtc `
                    -IntuneRecordPresent:($null -ne $intuneDevice) `
                    -IntuneLastSyncUtc $intuneLastSyncUtc `
                    -ReportCutoff $reportCutoff `
                    -QuarantineCutoff $quarantineCutoff

                $status = [string]$activityDecision.Status
                $recommendedAction = [string]$activityDecision.RecommendedAction
                $reason = $activityDecision.Reason
            }
        }

        if (
            $status -eq 'QuarantineCandidate' -and
            $script:Config.Mode -in @('Quarantine', 'Enforce')
        ) {
            if (-not (Test-ActionBudget)) {
                $actionTaken = 'SkippedSafetyLimit'
            }
            elseif ($PSCmdlet.ShouldProcess($computer.Name, 'Retire in Intune when present, disable and move to quarantine in AD')) {
                $anyChangeApplied = $false
                $adChangeApplied = $false
                $changeCounted = $false

                try {
                    if ($null -ne $intuneDevice) {
                        Invoke-MgRetireDeviceManagementManagedDevice `
                            -ManagedDeviceId ([string]$intuneDevice.Id) `
                            -Confirm:$false

                        $retireRequestedAtUtc = [datetime]::UtcNow
                        $anyChangeApplied = $true
                    }
                    else {
                        $retireRequestedAtUtc = $null
                    }

                    Disable-ADAccount -Identity $computer.ObjectGUID
                    $anyChangeApplied = $true
                    $adChangeApplied = $true

                    Move-ADObject `
                        -Identity $computer.ObjectGUID `
                        -TargetPath $script:Config.QuarantineOU

                    $quarantinedAtUtc = [datetime]::UtcNow
                    $marker = 'DeviceLifecycle|QuarantinedUtc={0}' -f $quarantinedAtUtc.ToString('o')
                    $replaceValues = @{}
                    $replaceValues[$script:Config.StateAttribute] = $marker

                    Set-ADComputer `
                        -Identity $computer.ObjectGUID `
                        -Replace $replaceValues

                    if ($null -eq $stateRecord) {
                        $stateRecord = New-StateRecord `
                            -Computer $computer `
                            -EntraDevice $entraDevice `
                            -IntuneDevice $intuneDevice `
                            -QuarantinedAtUtc $quarantinedAtUtc `
                            -AdLastLogonUtc $adLastLogonUtc `
                            -EntraLastActivityUtc $entraLastActivityUtc `
                            -IntuneLastSyncUtc $intuneLastSyncUtc

                        [void]$state.Add($stateRecord)
                    }

                    if ($null -ne $retireRequestedAtUtc) {
                        $stateRecord.RetireRequestedAtUtc = $retireRequestedAtUtc.ToString('o')
                    }

                    $stateRecord.LastError = $null
                    $stateRecord.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')

                    if ($anyChangeApplied) {
                        Register-ChangedDevice -RequiresSync:$adChangeApplied
                        $changeCounted = $true
                    }

                    $actionTaken = 'Quarantined'
                    Write-Log -Level INFO -Message "Device quarantined: $($computer.Name)."
                }
                catch {
                    $actionError = $_.Exception.Message
                    $actionTaken = 'Failed'

                    if ($anyChangeApplied -and -not $changeCounted) {
                        Register-ChangedDevice -RequiresSync:$adChangeApplied
                        $changeCounted = $true
                    }

                    if ($null -ne $stateRecord) {
                        $stateRecord.LastError = $actionError
                        $stateRecord.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
                    }

                    Write-Log -Level ERROR -Message "Failed to quarantine $($computer.Name): $actionError"
                }
            }
        }
        elseif (
            $status -eq 'DeleteCandidate' -and
            $script:Config.Mode -eq 'Enforce'
        ) {
            if (-not (Test-ActionBudget)) {
                $actionTaken = 'SkippedSafetyLimit'
            }
            elseif ($PSCmdlet.ShouldProcess($computer.Name, 'Delete from AD and Intune; allow Entra Connect to delete the Entra device')) {
                $anyChangeApplied = $false
                $adChangeApplied = $false
                $changeCounted = $false

                try {
                    if ($null -eq $stateRecord) {
                        $quarantinedAtUtc = Get-QuarantineTimestamp `
                            -StateRecord $null `
                            -Computer $computer `
                            -StateAttribute $script:Config.StateAttribute

                        $stateRecord = New-StateRecord `
                            -Computer $computer `
                            -EntraDevice $entraDevice `
                            -IntuneDevice $intuneDevice `
                            -QuarantinedAtUtc $quarantinedAtUtc `
                            -AdLastLogonUtc $adLastLogonUtc `
                            -EntraLastActivityUtc $entraLastActivityUtc `
                            -IntuneLastSyncUtc $intuneLastSyncUtc

                        [void]$state.Add($stateRecord)
                    }

                    Remove-ADComputer `
                        -Identity $computer.ObjectGUID `
                        -Confirm:$false

                    $anyChangeApplied = $true
                    $adChangeApplied = $true
                    $stateRecord.AdDeletedAtUtc = [datetime]::UtcNow.ToString('o')
                    $stateRecord.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')

                    if ($null -ne $intuneDevice) {
                        Remove-MgDeviceManagementManagedDevice `
                            -ManagedDeviceId ([string]$intuneDevice.Id) `
                            -Confirm:$false

                        $anyChangeApplied = $true
                        $stateRecord.IntuneDeletedAtUtc = [datetime]::UtcNow.ToString('o')
                    }
                    elseif ($intuneExpectedMissingAfterRetire) {
                        $stateRecord.IntuneDeletedAtUtc = [datetime]::UtcNow.ToString('o')
                    }

                    $stateRecord.LastError = $null

                    if ($anyChangeApplied) {
                        Register-ChangedDevice -RequiresSync:$adChangeApplied
                        $changeCounted = $true
                    }

                    $actionTaken = if ($null -ne $intuneDevice -or $intuneExpectedMissingAfterRetire) {
                        'DeletedFromADAndIntune'
                    }
                    else {
                        'DeletedFromAD'
                    }
                    Write-Log -Level INFO -Message "Device final deletion completed: $($computer.Name)."
                }
                catch {
                    $actionError = $_.Exception.Message
                    $actionTaken = 'Failed'

                    if ($anyChangeApplied -and -not $changeCounted) {
                        Register-ChangedDevice -RequiresSync:$adChangeApplied
                        $changeCounted = $true
                    }

                    if ($null -ne $stateRecord) {
                        $stateRecord.LastError = $actionError
                        $stateRecord.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
                    }

                    Write-Log -Level ERROR -Message "Failed final deletion for $($computer.Name): $actionError"
                }
            }
        }

        $reportRow = [pscustomobject]@{
            ComputerName = [string]$computer.Name
            Status = $status
            RecommendedAction = $recommendedAction
            Reason = $reason
            ActionTaken = $actionTaken
            ActionError = $actionError
            ADEnabled = [bool]$computer.Enabled
            ADOperatingSystem = [string]$computer.OperatingSystem
            InQuarantine = $inQuarantine
            ADLastLogonUtc = $(if ($null -ne $adLastLogonUtc) { $adLastLogonUtc.ToString('o') } else { $null })
            EntraLastActivityUtc = $(if ($null -ne $entraLastActivityUtc) { $entraLastActivityUtc.ToString('o') } else { $null })
            IntuneLastSyncUtc = $(if ($null -ne $intuneLastSyncUtc) { $intuneLastSyncUtc.ToString('o') } else { $null })
            DaysSinceLatestActivity = $daysSinceLatestActivity
            ADCreatedUtc = $(if ($null -ne $adCreatedUtc) { $adCreatedUtc.ToString('o') } else { $null })
            ADObjectGuid = $adObjectGuid
            ADSid = [string]$computer.SID
            ADDistinguishedName = [string]$computer.DistinguishedName
            EntraObjectId = $(if ($null -ne $entraDevice) { [string]$entraDevice.Id } else { $null })
            EntraDeviceId = $(if ($null -ne $entraDevice) { [string]$entraDevice.DeviceId } else { $null })
            EntraTrustType = $(if ($null -ne $entraDevice) { [string]$entraDevice.TrustType } else { $null })
            EntraOnPremisesSyncEnabled = $(if ($null -ne $entraDevice) { $entraDevice.OnPremisesSyncEnabled } else { $null })
            IntuneManagedDeviceId = $(if ($null -ne $intuneDevice) { [string]$intuneDevice.Id } else { $null })
            IntuneSerialNumber = $(if ($null -ne $intuneDevice) { [string]$intuneDevice.SerialNumber } else { $null })
            IntuneManagementState = $(if ($null -ne $intuneDevice) { [string]$intuneDevice.ManagementState } else { $null })
        }

        [void]$report.Add($reportRow)
    }

    # Process state records whose AD object was already deleted on a prior run.
    # Entra Connect is given time to remove the hybrid device. If it remains,
    # Enforce mode removes the residual Entra object after the configured delay.
    foreach ($record in @($state)) {
        if ([string]::IsNullOrWhiteSpace([string]$record.AdDeletedAtUtc)) {
            continue
        }

        $cloudAction = 'None'
        $cloudError = $null
        $adDeletedAtUtc = Convert-ToUtcDate -Value $record.AdDeletedAtUtc
        $daysSinceAdDeletion = [math]::Floor(($nowUtc - $adDeletedAtUtc).TotalDays)

        if ([string]::IsNullOrWhiteSpace([string]$record.IntuneDeletedAtUtc)) {
            $remainingIntune = @(
                Get-IndexValues `
                    -Index $intuneByObjectId `
                    -Key ([string]$record.IntuneManagedDeviceId)
            )

            if ($remainingIntune.Count -eq 0) {
                $record.IntuneDeletedAtUtc = [datetime]::UtcNow.ToString('o')
            }
            elseif (
                $script:Config.Mode -eq 'Enforce' -and
                (Test-ActionBudget)
            ) {
                try {
                    if ($PSCmdlet.ShouldProcess($record.ComputerName, 'Delete residual Intune managed device')) {
                        Remove-MgDeviceManagementManagedDevice `
                            -ManagedDeviceId ([string]$record.IntuneManagedDeviceId) `
                            -Confirm:$false

                        $record.IntuneDeletedAtUtc = [datetime]::UtcNow.ToString('o')
                        $record.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
                        $script:ActionCount++
                        $cloudAction = 'DeletedResidualIntune'
                    }
                }
                catch {
                    $cloudError = $_.Exception.Message
                    $record.LastError = $cloudError
                    $record.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
                    Write-Log -Level ERROR -Message "Residual Intune cleanup failed for $($record.ComputerName): $cloudError"
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$record.EntraDeletedAtUtc)) {
            $remainingEntra = @(
                Get-IndexValues `
                    -Index $entraByObjectId `
                    -Key ([string]$record.EntraObjectId)
            )

            if ($remainingEntra.Count -eq 0) {
                $record.EntraDeletedAtUtc = [datetime]::UtcNow.ToString('o')
            }
            elseif (
                $daysSinceAdDeletion -ge [int]$script:Config.ResidualEntraDeleteAfterDays -and
                $script:Config.Mode -eq 'Enforce' -and
                (Test-ActionBudget)
            ) {
                try {
                    if ($PSCmdlet.ShouldProcess($record.ComputerName, 'Delete residual Entra device after AD deletion')) {
                        Remove-MgDevice `
                            -DeviceId ([string]$record.EntraObjectId) `
                            -Confirm:$false

                        $record.EntraDeletedAtUtc = [datetime]::UtcNow.ToString('o')
                        $record.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
                        $script:ActionCount++
                        $cloudAction = if ($cloudAction -eq 'None') {
                            'DeletedResidualEntra'
                        }
                        else {
                            $cloudAction + ';DeletedResidualEntra'
                        }
                    }
                }
                catch {
                    $cloudError = $_.Exception.Message
                    $record.LastError = $cloudError
                    $record.LastUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
                    Write-Log -Level ERROR -Message "Residual Entra cleanup failed for $($record.ComputerName): $cloudError"
                }
            }
        }

        [void]$report.Add([pscustomobject]@{
            ComputerName = [string]$record.ComputerName
            Status = $(if (
                -not [string]::IsNullOrWhiteSpace([string]$record.IntuneDeletedAtUtc) -and
                -not [string]::IsNullOrWhiteSpace([string]$record.EntraDeletedAtUtc)
            ) {
                'CloudCleanupComplete'
            }
            else {
                'PendingCloudCleanup'
            })
            RecommendedAction = 'CloudCleanup'
            Reason = 'ADObjectAlreadyDeleted'
            ActionTaken = $cloudAction
            ActionError = $cloudError
            ADEnabled = $false
            ADOperatingSystem = $null
            InQuarantine = $false
            ADLastLogonUtc = $null
            EntraLastActivityUtc = $null
            IntuneLastSyncUtc = $null
            DaysSinceLatestActivity = $null
            ADCreatedUtc = $null
            ADObjectGuid = [string]$record.AdObjectGuid
            ADSid = [string]$record.AdSid
            ADDistinguishedName = $null
            EntraObjectId = [string]$record.EntraObjectId
            EntraDeviceId = [string]$record.EntraDeviceId
            EntraTrustType = $null
            EntraOnPremisesSyncEnabled = $null
            IntuneManagedDeviceId = [string]$record.IntuneManagedDeviceId
            IntuneSerialNumber = [string]$record.SerialNumber
            IntuneManagementState = $null
        })
    }

    if (
        $script:SyncRequired -and
        [bool]$script:Config.StartDeltaSyncAfterChanges -and
        $script:Config.Mode -ne 'ReportOnly'
    ) {
        try {
            Import-Module ADSync -ErrorAction Stop
            Start-ADSyncSyncCycle -PolicyType Delta | Out-Null
            Write-Log -Level INFO -Message 'Microsoft Entra Connect delta synchronization started.'
        }
        catch {
            Write-Log -Level WARN -Message "Could not start Entra Connect delta sync: $($_.Exception.Message)"
        }
    }

    @($report) |
        Sort-Object Status, ComputerName |
        Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8

    Copy-Item -LiteralPath $reportPath -Destination $latestReportPath -Force

    # Keep completed state for audit, then prune after the configured retention.
    $retentionCutoff = [datetime]::UtcNow.AddDays(-[int]$script:Config.CompletedStateRetentionDays)
    $retainedState = New-Object System.Collections.ArrayList

    foreach ($record in @($state)) {
        $isComplete = (
            -not [string]::IsNullOrWhiteSpace([string]$record.AdDeletedAtUtc) -and
            -not [string]::IsNullOrWhiteSpace([string]$record.IntuneDeletedAtUtc) -and
            -not [string]::IsNullOrWhiteSpace([string]$record.EntraDeletedAtUtc)
        )

        $lastUpdated = Convert-ToUtcDate -Value $record.LastUpdatedAtUtc
        if (-not $isComplete -or $null -eq $lastUpdated -or $lastUpdated -ge $retentionCutoff) {
            [void]$retainedState.Add($record)
        }
    }

    Save-State -State $retainedState -Path $script:Config.StateFile

    $summary = @($report) | Group-Object Status | Sort-Object Name
    foreach ($item in $summary) {
        Write-Log -Level INFO -Message ("Summary {0}: {1}" -f $item.Name, $item.Count)
    }

    Write-Log -Level INFO -Message "Run completed. ChangedDevices=$($script:ActionCount); Report=$reportPath"
}
catch {
    $errorDetails = $_.Exception.ToString()
    if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        $errorDetails += [Environment]::NewLine + $_.ScriptStackTrace
    }

    Write-Log -Level ERROR -Message $errorDetails
    throw
}
finally {
    if ($graphConnected) {
        Disconnect-MgGraph | Out-Null
    }
}
