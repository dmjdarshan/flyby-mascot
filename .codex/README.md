# Codex project setup

This directory contains project-scoped Codex configuration. It complements the engineering instructions in the repository-root `AGENTS.md`.

## Contents

- `config.toml` keeps commands in a workspace-write sandbox, requires on-request approval, disables sandboxed network access by default, and recognizes `Package.swift` as a project-root marker.
- `rules/project.rules` prompts before destructive Git operations, recursive deletion, or privileged commands are allowed outside the sandbox.
- `verify.sh` provides one stable verification entry point for both full Xcode and the currently installed Command Line Tools setup.

Run verification with:

```sh
sh .codex/verify.sh
```

Project `.codex` configuration and rules load only when the repository is trusted. Restart Codex after changing configuration or rules so a new session loads them. `AGENTS.md` is discovered from the project root at the start of a run; place narrower overrides only in subdirectories that genuinely need different standards.

Official references:

- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/config-reference
- https://developers.openai.com/codex/guides/rules
