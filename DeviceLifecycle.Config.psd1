@{
    # ============================================================
    # Organization Identity
    #   Change OrganizationName to your company / customer name.
    #   All paths, task names and certificate identifiers are
    #   derived from this single value unless explicitly overridden.
    # ============================================================
    OrganizationName = 'orgname'

    # Modes:
    # ReportOnly  = inventory and CSV only
    # Quarantine  = report + retire in Intune + disable/move in AD
    # Enforce     = quarantine + final deletion + residual cloud cleanup
    Mode = 'ReportOnly'

    TenantId = '0000000-000000-0000000-0000000'
    ClientId = '0000000-000000-0000000-0000000'
    CertificateThumbprint = 'REPLACE_WITH_LOCAL_MACHINE_CERT_THUMBPRINT'

    ActiveComputersOU = 'OU=Computadores,DC=corp,DC=orgname,DC=com,DC=br'
    QuarantineOU = 'OU=Quarentena,OU=Computadores,DC=corp,DC=orgname,DC=com,DC=br'
    ExclusionGroup = 'GG-DeviceCleanup-Exclusions'

    # Exchange schema is already present in the environment. Change this if
    # extensionAttribute15 is used by another process.
    StateAttribute = 'extensionAttribute15'

    ReportAfterDays = 75
    QuarantineAfterDays = 90
    DeleteAfterQuarantineDays = 30
    ResidualEntraDeleteAfterDays = 7

    # Safety gate for lifecycle actions. Objects younger than this are still
    # inventoried and correlated with Entra/Intune, but cannot become action
    # candidates until the minimum age has elapsed.
    MinimumObjectAgeDays = 30

    # Conservative correlation. A missing or duplicated cloud record is sent
    # to manual review instead of being changed.
    RequireEntraMatch = $true
    RequireIntuneMatch = $true
    ExcludeAutopilotDevices = $true

    # Hard safety brake: maximum number of devices changed in one execution.
    MaximumActionsPerRun = 10

    # Servers, domain controllers, the execution server, group exclusions and
    # protected objects are never changed automatically.
    ExcludedComputerNames = @(
        'CLOUD-SYNC'
    )
    ExcludedNamePatterns = @()
    ExcludedOperatingSystemPatterns = @(
        '*Windows Server*'
    )

    # ---- Derived paths (leave blank to auto-derive from OrganizationName) ----

    # InstallRoot       → C:\ProgramData\{OrganizationName}\DeviceLifecycle
    # StateFile          → {InstallRoot}\state.json
    # LogDirectory       → {InstallRoot}\Logs
    # ReportDirectory    → {InstallRoot}\Reports
    # TaskName           → {OrganizationName} - Device Lifecycle
    # CertificateSubjectName → CN={OrganizationName} Device Lifecycle Automation
    # CertificateFileName    → {OrganizationName}-DeviceLifecycle.cer

    InstallRoot = ''
    StateFile = ''
    LogDirectory = ''
    ReportDirectory = ''

    TaskName = ''
    TaskTime = '02:15'

    CertificateSubjectName = ''
    CertificateFileName = ''

    StartDeltaSyncAfterChanges = $true
    CompletedStateRetentionDays = 180
}
