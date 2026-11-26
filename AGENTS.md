# Agent rules for this repository

This repository is public on GitHub. Everything committed is published.

## Never commit local machine paths
- No absolute paths from a developer machine: home directories under `/Users`, temp folders under `/var/folders` or `/private/tmp`.
- Use repo-relative paths (`docs/phases/phase-2/design.md:12`) or `~/` for paths under the home directory.
- Reviewer reports (Codex or Claude) link files by absolute path. Rewrite those links to repo-relative paths before adding a report to `docs/phases/*/reviews/`.
- The pre-commit hook in `.githooks/` blocks commits that add such paths. Enable it once per clone: `git config core.hooksPath .githooks`.
- Before pushing, run `Scripts/check-local-paths.sh`; it must print nothing.

If a local path was already pushed, removing it means a history rewrite and force-push (D-007, D-011). Ask the owner first.

## Process
Work follows the phase layout in `docs/` (`roadmap.md`, `phase-status.md`, `decisions.md`, `phases/`). `docs/phase-status.md` is the source of truth for what is active.
