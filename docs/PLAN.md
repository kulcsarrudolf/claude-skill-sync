# Plan for claude-skill-sync v1.0.0

This document is the design.
Each numbered step at the end is one GitHub issue in the v1.0.0 milestone, and the issues are implemented in order.

## Goal

Move a user's Claude Code skills between machines with two commands, through a git repository or a zip file, without ever touching the parts of `~/.claude` that must stay private.
Project memory is an opt-in extra.

## Not in v1

Syncing `settings.json`, `CLAUDE.md`, agents, or hooks.
Selective sync of individual skills.
Windows.
A restore command (backups are plain zips; unzipping one is the restore).
A conflict UI beyond what git already gives.

## How the user sees it

The plugin is named `skill-sync` and installs from this repository, which is also the marketplace.
Six skills: `setup`, `status`, `push`, `pull`, `export`, `import`.

`setup` asks two questions and then whatever the chosen transport needs:

1. Where to sync: a git repository (recommended, and the skill tells the user to make it private) or a zip file.
2. What to sync: skills only (default) or skills and project memory.

For git it then asks for the remote URL, the branch (default `main`), and whether to auto-push.
For zip it asks for the output folder (default `~/Desktop`).

`push` and `pull` exist in git mode, `export` and `import` in zip mode.
Running a command that does not match the configured mode prints a one-line explanation and exits 1.

## Architecture

Every command is a shell script in `scripts/`.
The matching `SKILL.md` tells Claude which script to run, how to present the output, and what to do on each exit code.
Nothing that changes files happens in Claude's reasoning; it happens in a script that can be run and tested without Claude.

Reasons: scripts are deterministic and testable with bats, a user can run them from a terminal when Claude is not around, and the SKILL.md stays short enough to cost almost nothing in context.

```
claude-skill-sync/
  .claude-plugin/
    plugin.json          name, version, description, author, repository, license
    marketplace.json     name claude-skill-sync, one plugin entry with source "./"
  skills/
    setup/SKILL.md
    status/SKILL.md
    push/SKILL.md
    pull/SKILL.md
    export/SKILL.md
    import/SKILL.md
  scripts/
    lib.sh               shared functions, sourced by every other script
    setup.sh
    status.sh
    push.sh
    pull.sh
    export.sh
    import.sh
    hook-autopush.sh     PostToolUse hook, opt-in through config
  hooks/
    hooks.json
  tests/
    helpers.bash
    *.bats
  docs/PLAN.md
  README.md
  LICENSE
```

Scripts reference each other through their own directory (`$(dirname "$0")`), never through a repository-relative path, because marketplace installs are copied to `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` and that path changes on every update.
SKILL.md files reference scripts as `"${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh"`, which Claude Code substitutes when it loads the skill.

## State and config

Everything the plugin owns lives in one directory, `$SKILL_SYNC_HOME`, which defaults to `$CLAUDE_CONFIG_DIR/skill-sync`, which defaults to `~/.claude/skill-sync`.

```
skill-sync/
  config          key=value, written by setup.sh
  repo/           git mode: the working clone
  backups/        zips taken before every pull or import, newest ten kept
  sync.log        one line per operation
  last-push       timestamp files, read by status.sh
  last-pull
  last-export
  last-import
```

`config` is a plain key=value file, one pair per line, keys matching `[A-Z_]+`.
It is parsed with grep, never sourced, so a damaged file cannot execute anything.

| Key | Values | Default |
|-----|--------|---------|
| `CONFIG_VERSION` | `1` | `1` |
| `MODE` | `git`, `zip` | required |
| `SCOPE_MEMORY` | `0`, `1` | `0` |
| `GIT_REMOTE` | any URL git accepts | required in git mode |
| `GIT_BRANCH` | branch name | `main` |
| `AUTO_PUSH` | `0`, `1` | `0` |
| `ZIP_DIR` | directory, `~` allowed | `~/Desktop` |
| `EXCLUDE` | colon-separated patterns | `.git:.DS_Store:*.bak` |

`${CLAUDE_PLUGIN_DATA}` was considered for the state directory and rejected: it is exported to hook processes but not to scripts Claude runs through the Bash tool, so the scripts would need a fallback anyway.
One explicit location is simpler.

## The sync set

The sync set is the list of files a push, pull, export, or import operates on.
It is computed by one function in `lib.sh` and used everywhere, so the four commands cannot disagree about what is in scope.

Roots, relative to the config directory:

- `skills/`, always.
- `projects/*/memory/`, when `SCOPE_MEMORY=1`.

Inside a root, a path is excluded when any component matches a pattern in `EXCLUDE`.
The default excludes `.git` (a skill that is its own clone travels as plain files), `.DS_Store`, and `*.bak`.

Every exported zip and every push writes `skill-sync.json` at the top level of the payload:

```json
{"format":1,"host":"macbook-air","createdAt":"2026-09-23T10:15:00Z","memory":false,"pluginVersion":"1.0.0"}
```

`import` and `pull` refuse a payload without it, or with a `format` they do not know, unless `--force` is passed.
The file is written with `printf`, so `jq` is not needed to produce it, and read with `grep`, so it is not needed to consume it.

## Mode semantics

### Git

The clone at `state/repo` is the only place git runs.
`~/.claude` itself is never a repository as far as this plugin is concerned, so users who already keep it under version control are unaffected.

`push`:

1. Ensure the clone exists. If the remote is empty, `git init`, set the branch name, add the remote.
2. `git fetch` and `git merge --ff-only`. If that fails the clone has diverged; exit 5 and tell the user to `pull` first.
3. Mirror the sync set into the clone: copy, then delete anything under the clone's `skills/` and `projects/` that is not in the sync set.
4. Write `skill-sync.json`.
5. `git add -A`. If nothing is staged, print "nothing to push" and exit 0.
6. Commit as `skill-sync: push from <host>` and push. If the push is rejected, fetch and `git rebase`; on conflict, `git rebase --abort` and exit 5.
7. Touch `last-push`.

`pull`:

1. Ensure the clone exists, fetch, `git merge --ff-only`. On failure exit 5 with the same advice.
2. Diff the clone's payload against the local sync set and print added, changed, deleted.
3. Without `--yes`, exit 6. The skill turns exit 6 into a question to the user and reruns with `--yes`.
4. Back up the local sync set.
5. Apply in mirror mode: copy, then delete local files inside the roots that the payload does not have.
6. Touch `last-pull` and print the restart reminder.

Mirror is the right default for pull because the repository is the source of truth: a skill deleted on machine A should disappear from machine B.

### Zip

`export` stages the sync set into a temporary directory, writes the manifest, zips it as `claude-skills-<host>-<YYYYMMDD-HHMMSS>.zip` into `ZIP_DIR`, prints the absolute path, and touches `last-export`.

`import <file>`:

1. Unzip to a temporary directory and check the manifest.
2. If the zip carries memory but `SCOPE_MEMORY=0`, skip the memory and say so.
3. Diff and print, exit 6 without `--yes`, back up, apply.
4. Apply in merge mode by default (add and overwrite, never delete) because a zip may be older than what the receiving machine has. `--mirror` switches to mirror mode.

## Safety rules

These hold for every command and every test asserts at least one of them.

- A backup zip is written before any file under the config directory is modified or deleted. The newest ten backups are kept.
- Deletion never reaches outside the sync roots. The mirror function receives the root list and refuses paths that do not start with one of them.
- Nothing outside the sync set is read for upload. `settings.json`, `CLAUDE.md`, sessions, history, and credentials are never staged.
- Any command that would delete or overwrite requires `--yes`, and `--dry-run` prints the plan and exits 0 without touching anything.
- Scripts run under `set -euo pipefail` and clean their temporary directories on exit through a trap.

Exit codes are fixed so SKILL.md files can branch on them:

| Code | Meaning |
|------|---------|
| 0 | Success, or nothing to do |
| 1 | Usage error, or command does not match the configured mode |
| 2 | Not configured; run setup |
| 3 | A required tool is missing |
| 4 | Remote unreachable or network failure |
| 5 | Diverged or conflicted; manual git step needed |
| 6 | Confirmation required; rerun with `--yes` |

## Portability decisions

Target bash 3.2, because that is what macOS ships and users will not have upgraded it.
No associative arrays, no `mapfile`, no `${var,,}`.

No `rsync`.
macOS 15 and later ship `openrsync`, whose flags differ from GNU rsync in ways that matter (`--itemize-changes`, `--delete` edge cases).
Copying is done with a `tar` pipe (`tar -C src -cf - . | tar -C dst -xf -`), which behaves the same with bsdtar and GNU tar.
Deletions for mirror mode are computed with `find` and `comm`.
Diffs are computed with `diff -rq`, which is POSIX.

`zip` and `unzip` are required.
They are on every macOS install and one `apt install` away on Linux.
`tar.gz` was rejected because the user asked for a file they can double-click.

`jq` is optional.
The hook parses `file_path` from stdin with `jq` when present and with `sed` otherwise.
Config and manifests never need it.

`CLAUDE_CONFIG_DIR` is honored so users who relocate their config directory are not silently synced from the wrong place.

## Testing

Tests use bats-core.
`tests/helpers.bash` points `HOME` and `CLAUDE_CONFIG_DIR` at a fresh temporary directory, populates it with a few fake skills, and for git tests creates a bare repository under the same temporary directory and uses its `file://` URL as the remote.
No test touches the network or the real `~/.claude`.

Every script gets a `.bats` file.
Shared assertions: the backup exists after a destructive command, nothing outside the roots changed (checksum the whole fake config directory before and after), and the exit codes above are returned in the documented situations.

CI runs on `macos-latest` and `ubuntu-latest`: `shellcheck scripts/*.sh`, `bats tests`, and `claude plugin validate .`.

## Steps

One issue per row.
Each issue lists its prerequisites with a command that checks whether the previous issue is done.

| Step | Issue | Depends on |
|------|-------|------------|
| 1 | Plugin scaffold, `lib.sh` foundations, test harness | none |
| 2 | CI on macOS and Ubuntu | 1 |
| 3 | Sync set: enumerate, stage, apply, diff, backup, manifest | 1 |
| 4 | `setup` skill and script | 3 |
| 5 | `status` skill and script | 4 |
| 6 | `export` skill and script | 4 |
| 7 | `import` skill and script | 6 |
| 8 | `push` skill and script | 4 |
| 9 | `pull` skill and script | 8 |
| 10 | Auto-push hook | 8 |
| 11 | Release v1.0.0 | all |

Steps 6 and 8 are independent and can be done in either order.

## Release checklist

Part of step 11, repeated here so it is not lost.

1. `bats tests`, `shellcheck`, and `claude plugin validate .` pass on both platforms in CI.
2. Set `version` to `1.0.0` in both `plugin.json` and the marketplace entry.
3. From a terminal with `CLAUDE_CONFIG_DIR` pointing at an empty temporary directory, run the two install commands from the README and every quick-start step, in both modes.
4. Repeat on a second physical machine.
5. Run the de-slop scan on the README and fix what it finds.
6. Tag `v1.0.0`, push the tag, write the GitHub release from the commit log.
7. Optionally submit to the community marketplace through the Console form.

## Later ideas

Kept here so they do not creep into v1.

- Sync `CLAUDE.md` and a whitelist of `settings.json` keys.
- `restore` skill that lists backups and applies one.
- Per-skill include and exclude lists.
- A `SessionStart` hook that runs `pull` when the remote is ahead.
- Windows support once the scripts have a PowerShell twin or are rewritten in a portable language.
