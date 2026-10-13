# Security policy

PairVox can approve actions taken by a coding agent on your machine, so security issues matter a lot here.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability reporting ("Report a vulnerability" on the repository's Security tab), or email the maintainers listed in the repository profile. We aim to acknowledge reports within 3 business days.

Especially interested in:

- ways to get a high-risk action approved by voice, or without the user's intent
- echo or background audio that triggers approvals
- credential exposure (API key, Claude login)
- issues in model download verification

## Scope

Vulnerabilities in Claude Code itself should go to Anthropic (https://hackerone.com/anthropic). Issues in WhisperKit, Kokoro or MLX go to their maintainers, but please also tell us if PairVox's use of them makes the issue worse.

See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the design.
