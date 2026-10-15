# Security Policy

## Supported Versions

Use this section to tell people about which versions of your project are
currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 5.1.x   | :white_check_mark: |
| 5.0.x   | :x:                |
| 4.0.x   | :white_check_mark: |
| < 4.0   | :x:                |

## Reporting a Vulnerability

Use this section to tell people how to report a vulnerability.

Tell them where to go, how often they can expect to get an update on a
reported vulnerability, what to expect if the vulnerability is accepted or
declined, etc.

## Vision AI inspection (Stage A)

No AI provider is integrated and AI is disabled unless an operator configures
one. Provider credentials, if ever added, must be server environment variables
only — never in the Flutter apps, the repository, logs or API responses. See
`docs/VISION_AI.md` for configuration, image handling (nothing is persisted),
guardrails, restart behaviour and the privacy / legal review required before
real use.
