#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'DeviceLifecycle.Config.psd1'),

    [Parameter()]
    [switch]$InstallModules,

    [Parameter()]
    [switch]$CreateAdObjects,

    [Parameter()]
    [switch]$CreateCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

Import-Module (Join-Path $PSScriptRoot 'DeviceLifecycle.Helpers.psm1') -Force

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$config = Resolve-DeviceLifecycleConfig -Config $config

foreach ($directory in @(
    $config.InstallRoot,
    $config.LogDirectory,
    $config.ReportDirectory
)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
}

if ($InstallModules) {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    }

    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    foreach ($moduleName in @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'Microsoft.Graph.DeviceManagement',
        'Microsoft.Graph.DeviceManagement.Enrollment'
    )) {
        Install-Module `
            -Name $moduleName `
            -Scope AllUsers `
            -Repository PSGallery `
            -Force `
            -AllowClobber
    }
}

Import-Module ActiveDirectory -ErrorAction Stop

if ($CreateAdObjects) {
    try {
        Get-ADOrganizationalUnit -Identity $config.ActiveComputersOU -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Active computers OU was not found: $($config.ActiveComputersOU)"
    }

    try {
        Get-ADOrganizationalUnit -Identity $config.QuarantineOU -ErrorAction Stop | Out-Null
    }
    catch {
        New-ADOrganizationalUnit `
            -Name 'Quarentena' `
            -Path $config.ActiveComputersOU `
            -ProtectedFromAccidentalDeletion $true

        Write-Host "Created OU: $($config.QuarantineOU)"
    }

    try {
        Get-ADGroup -Identity $config.ExclusionGroup -ErrorAction Stop | Out-Null
    }
    catch {
        New-ADGroup `
            -Name $config.ExclusionGroup `
            -SamAccountName $config.ExclusionGroup `
            -GroupCategory Security `
            -GroupScope Global `
            -Path $config.ActiveComputersOU `
            -Description 'Computers excluded from automated stale-device lifecycle actions.'

        Write-Host "Created group: $($config.ExclusionGroup)"
    }

    $schemaNamingContext = (Get-ADRootDSE).SchemaNamingContext
    $stateAttribute = Get-ADObject `
        -SearchBase $schemaNamingContext `
        -LDAPFilter ('(lDAPDisplayName={0})' -f $config.StateAttribute)

    if ($null -eq $stateAttribute) {
        throw "The configured state attribute does not exist in the AD schema: $($config.StateAttribute)"
    }

    Write-Host "Verified AD state attribute: $($config.StateAttribute)"
}

if ($CreateCertificate) {
    $existingCertificate = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object {
            $_.Subject -eq $config.CertificateSubjectName -and
            $_.NotAfter -gt (Get-Date).AddDays(90)
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($null -eq $existingCertificate) {
        $existingCertificate = New-SelfSignedCertificate `
            -Subject $config.CertificateSubjectName `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -KeyExportPolicy NonExportable `
            -KeySpec Signature `
            -NotAfter (Get-Date).AddYears(2)
    }

    $publicCertificatePath = Join-Path $config.InstallRoot $config.CertificateFileName
    Export-Certificate `
        -Cert $existingCertificate `
        -FilePath $publicCertificatePath `
        -Force | Out-Null

    Write-Host ''
    Write-Host 'Certificate created or reused.'
    Write-Host "Thumbprint: $($existingCertificate.Thumbprint)"
    Write-Host "Public certificate: $publicCertificatePath"
    Write-Host 'Upload the .cer file to the Entra application registration.'
}

Write-Host ''
Write-Host 'Initialization completed.'
