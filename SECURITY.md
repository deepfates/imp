# Security Policy

## Supported Versions

Imp has not published its first stable release. Security fixes currently land
on the default branch and will be included in the next release artifact.

## Reporting a Vulnerability

Do not open a public issue for a suspected vulnerability or leaked credential.
Use GitHub's private vulnerability reporting for the Imp repository. Include
the affected version or commit, impact, reproduction steps, and any proposed
mitigation.

Imp handles model credentials, tool execution, external MCP and retrieval
services, generated code, serialized programs, and provider responses. Reports
about secret exposure, unsafe deserialization, sandbox escape, tool-policy
bypass, request forgery, or unbounded resource consumption are especially
important.

## Operational Guidance

- Keep credentials in runtime environment variables or a secrets manager.
- Never commit `.env` files or serialize API keys into programs.
- Treat loaded artifacts and executable tools as trusted code unless a stricter
  application boundary is documented.
- Restrict tool catalogs and network access according to application policy.
- Run `mix quality.check` before release to check dependency advisories.
