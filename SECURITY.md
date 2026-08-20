# Security Policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability or include API tokens, signing material, customer data, or exploit details in an issue.

Use GitHub's **Security** tab and select **Report a vulnerability** to send a private report. Include the affected version, a minimal reproduction, impact, and any suggested mitigation. You should receive an acknowledgement within five business days.

Security fixes are applied to the latest release line and may require upgrading to the newest gem version.

## Protecting signing material

Never commit Apple private keys, certificates, Android keystores, Google service-account JSON, API tokens, or generated build artifacts. Prefer `--local-only` when credentials must remain on the workstation, and review CI logs before sharing them.
