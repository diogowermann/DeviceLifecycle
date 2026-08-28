# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project does not yet publish versioned releases; changes remain grouped under `Unreleased` until a release strategy is adopted.

## [Unreleased]

### Added

- Bilingual project documentation in English and Brazilian Portuguese.
- Architecture documentation covering identity correlation, lifecycle states, trust boundaries, and safety controls.
- Mermaid diagrams for system context, device correlation, execution flow, and lifecycle progression.
- Marked placeholders for future sanitized screenshots and operational examples.
- MIT license.
- Security policy and responsible-disclosure guidance.
- Optional integration reference for `DeviceLifecycle-API`.
- Activity-policy tests covering AD-only, partial-cloud, recent-cloud, warning, and missing-timestamp scenarios.

### Changed

- Reorganized the main README around the engineering problem, architecture, safety model, rollout, recovery, and portfolio presentation.
- Corrected and clarified the relationship between `DeviceLifecycle` and the separate `DeviceLifecycle-API` repository.
- Changed lifecycle correlation so missing Entra ID or Intune records are treated as unavailable evidence instead of forcing `ManualReview`; ambiguous or inconsistent matches and missing timestamps on existing records remain fail-closed.
- Documented the split scheduled-execution model: the primary lifecycle task uses the configured mode, while the frequent snapshot task always forces `ReportOnly`.
- Documented the recommended production promotion sequence using `ReportOnly`, `Enforce -WhatIf`, a controlled `Enforce` run, and only then persistent `Mode = 'Enforce'`.
- Updated public documentation to reflect successful production validation of the optional cloud-correlation behavior without publishing environment-specific device identifiers or counts.

### Security

- Documented credential handling, least privilege, certificate storage, pilot validation, and disclosure requirements.
- Clarified that a successful cloud query returning zero records is different from a Graph query failure: missing records are optional evidence, while source-query failures remain fail-closed.
- Reaffirmed `MaximumActionsPerRun`, quarantine retention, `-WhatIf`, and explicit recovery as operational safeguards before persistent enforcement.
