# Project instructions

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for every commit message and PR title.
PRs are squash-merged, so the PR title becomes the commit on `main` and must follow the format too.
- Format: `<type>(<optional scope>): <summary>`, summary in the imperative, lowercase, no trailing period.
- Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `ci`, `build`, `perf`, `style`, `revert`.
- Scopes, when useful: the script or skill touched (`lib`, `status`, `setup`, `push`, `pull`, `export`, `import`, `hook`), or `plugin` for the manifests.
- For milestone issues, put the step number in the body or a trailing `(step N)` instead of a `Step N:` prefix.
Example: `ci: run shellcheck, bats, and plugin validate on macOS and Ubuntu (step 2)`.
- Mark breaking changes with `!` after the type or scope and a `BREAKING CHANGE:` footer.

## Branches

- Name branches `<type>/<short-kebab-description>`, using the same types as commits.
Examples: `feat/setup-skill`, `fix/config-get-default`, `docs/branch-naming`.
- For milestone issues, start the description with the step number: `ci/step-2-macos-ubuntu`, `feat/step-3-sync-set`.
- Keep names lowercase, ASCII letters, digits, and hyphens only after the slash.
