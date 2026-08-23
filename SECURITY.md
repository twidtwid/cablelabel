# Security Policy

## Supported versions

Security fixes are made against the latest version on the default branch.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting feature in the repository's **Security** tab.

Useful reports include reproduction steps, affected versions, impact, and any
suggested mitigation. In particular, please report:

- requests that bypass the allowed host or origin checks;
- command construction that could execute unintended programs or arguments;
- remote access that contradicts the documented localhost/tailnet boundary;
- exposure of label contents or local filesystem data; and
- ways an untrusted remote user could trigger physical printing.

## Deployment boundary

Cable Labelmaker has no application-level authentication. It listens on
localhost by default. Remote deployment must use an authenticated private
network boundary such as Tailscale Serve with suitable tailnet access controls.
Do not expose it through Tailscale Funnel or a public reverse proxy.
