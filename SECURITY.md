# Security Policy

## Supported versions

DeviceLifecycle does not currently publish versioned releases. Security fixes are applied to the latest state of the default branch.

| Version | Supported |
|---|---|
| Latest default branch | Yes |
| Older commits, copies, and forks | No guaranteed support |

## Reporting a vulnerability

Do not disclose suspected vulnerabilities, credentials, tenant identifiers, certificate material, or exploit details in a public issue.

Use GitHub's private **Report a vulnerability** option in the repository Security tab when it is available. Otherwise, contact the repository owner privately through the GitHub profile before publishing technical details.

A useful report should include:

- the affected script, module, or configuration;
- the tested commit or version;
- the expected and observed behavior;
- the security impact;
- reproducible steps or a minimal proof of concept;
- any proposed mitigation.

Do not test a finding against systems, tenants, directories, or devices that you do not own or have explicit authorization to assess.

## Operational security requirements

DeviceLifecycle performs privileged endpoint and identity administration. Deployments should preserve the following controls:

- start and validate the solution in `ReportOnly` mode;
- use certificate-based Microsoft Graph application authentication;
- keep the certificate private key in the local machine certificate store and never commit it;
- grant only the required Microsoft Graph and Active Directory permissions;
- keep tenant IDs, client IDs, thumbprints, distinguished names, hostnames, and organization-specific values out of public commits unless they are intentionally sanitized;
- retain `MaximumActionsPerRun`, exclusions, manual-review handling, and `-WhatIf` validation;
- keep the quarantine OU inside the intended Microsoft Entra Connect synchronization scope;
- review logs and reports for sensitive operational data before sharing them.

Configuration mistakes that bypass documented safeguards may produce destructive results even when the source code is unchanged. Validate the complete deployment in a non-production or pilot scope before enabling `Quarantine` or `Enforce`.

## Disclosure expectations

The maintainer will assess reports based on reproducibility, impact, and whether the issue originates in the project or in environment-specific configuration. No response-time or remediation-time guarantee is currently provided.
