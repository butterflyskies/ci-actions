# Security Policy

## Reporting a vulnerability

If you discover a security issue in this repository, please report it
privately via [GitHub Security Advisories][advisory] rather than opening a
public issue.

For urgent issues, email lina@butterflysky.dev with subject line
`[ci-actions security]`.

## Threat model

This repository contains GitHub Actions composite actions used across the
butterflyskies org. The primary threat we defend against is **supply chain
compromise through dependency manipulation** — the class of attack described
in Dan Lorenc's analysis of GitHub Actions security weaknesses.

### In scope

- Silent rewriting of git tags or commits in upstream action repositories
- Template injection through unsanitized `${{ }}` expressions
- Overly broad `GITHUB_TOKEN` permissions
- Transitive dependency manipulation (actions referencing other actions
  with mutable refs)

### Mitigations

- All action references use full 40-character commit SHAs
- `DEPS.lock` records tree hashes for every pinned dependency
- CI verifies lockfile integrity on every push and weekly
- Composite actions declare no permissions; callers must be explicit
- No `pull_request_target` usage
- No shell interpolation of untrusted inputs

[advisory]: https://github.com/butterflyskies/ci-actions/security/advisories/new
