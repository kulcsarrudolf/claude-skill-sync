# claude-skill-sync

A Claude Code plugin that keeps your personal skills identical on every machine you use.

Claude Code stores skills in `~/.claude/skills`, one folder per skill, and has no built-in way to move them between computers.
This plugin adds that.
You pick one of two transports during setup: a git repository that both machines push to and pull from, or a zip file you carry across yourself.
Skills are always included.
Project memory (`~/.claude/projects/*/memory`) is included only if you ask for it.

Status: not released yet.
This README describes the plugin as it works at v1.0.0.
Progress is tracked in the issues of the [v1.0.0 milestone](https://github.com/kulcsarrudolf/claude-skill-sync/milestone/1), and the design is in [docs/PLAN.md](docs/PLAN.md).

## Install

Inside Claude Code:

```
/plugin marketplace add kulcsarrudolf/claude-skill-sync
/plugin install skill-sync@claude-skill-sync
```

Run `/reload-plugins` or restart Claude Code.
The skills appear as `/skill-sync:setup`, `/skill-sync:push`, and so on.

## Quick start with a git repository

This is the recommended transport.
Use a private repository: skills often contain internal hostnames, repository names, and team conventions you would not want indexed.

On the first machine:

1. Create an empty private repository, for example `gh repo create claude-skills --private`.
2. Run `/skill-sync:setup`. It asks where to sync (git or zip), what to sync (skills only, or skills and project memory), and for the repository URL.
3. Run `/skill-sync:push`.

On the second machine:

1. Install the plugin.
2. Run `/skill-sync:setup` and give it the same repository URL.
3. Run `/skill-sync:pull`, then restart Claude Code so it loads the new skills.

From then on, push after you change a skill and pull when you sit down at the other machine.
If you answer yes to auto-push during setup, every skill file Claude writes is committed and pushed in the background, and you only ever have to pull.

## Quick start with a zip file

Choose this when you do not want a remote at all, or the machines cannot reach the same git host.

1. Run `/skill-sync:setup` and choose zip. It asks for an output folder (Desktop by default).
2. Run `/skill-sync:export`. It writes `claude-skills-<machine>-<date>.zip` to that folder and prints the path.
3. Move the file to the other machine however you like: AirDrop, a USB stick, a shared drive.
4. There, run `/skill-sync:import ~/Downloads/claude-skills-<machine>-<date>.zip` and restart Claude Code.

Import merges by default: skills in the zip are added or overwritten, and skills that exist only on the receiving machine are left alone.
Pass `--mirror` to make the receiving machine match the zip exactly, including deletions.

## What is synced

| Path | Included |
|------|----------|
| `~/.claude/skills/**` | Always |
| `~/.claude/projects/*/memory/**` | Only when you choose "skills and memory" in setup |

Inside those paths, `.git` directories, `.DS_Store`, and `*.bak` files are skipped.
A skill that is itself a git clone arrives on the other machine as plain files.
The exclude list is a config value if you need to change it.

Nothing else in `~/.claude` is touched or uploaded.
That includes `settings.json`, `CLAUDE.md`, session transcripts, `history.jsonl`, credentials, and plugin caches.

Project memory is stored under a folder named after the project's absolute path, so it only lines up on the other machine if the project lives at the same path there.
If it does not, the files are copied but Claude will not read them.

## Safety

Before `pull` or `import` writes anything, the current skills (and memory, if in scope) are zipped into `~/.claude/skill-sync/backups/`.
The ten most recent backups are kept.
To roll back, unzip one over `~/.claude`.

Both commands show what would be added, changed, and deleted, and ask before continuing.
Deletions only happen inside the synced paths above.

The plugin never runs `git` inside `~/.claude` itself.
Its working clone lives in `~/.claude/skill-sync/repo`, so an existing git setup in your config directory is left alone.

## Commands

| Command | What it does |
|---------|--------------|
| `/skill-sync:setup` | Ask the two questions, store the answers, verify the remote or the output folder |
| `/skill-sync:status` | Show the mode, what would sync, the last push and pull, and whether the remote is ahead or behind |
| `/skill-sync:push` | Git mode. Copy the sync set into the clone, commit, push |
| `/skill-sync:pull` | Git mode. Fetch, show the diff, back up, apply |
| `/skill-sync:export` | Zip mode. Write a zip of the sync set to the output folder |
| `/skill-sync:import <file.zip>` | Zip mode. Validate, show the diff, back up, apply. `--mirror` to delete local extras |

Each command is a shell script under `scripts/`, and the skill's job is to run it and relay the result.
You can run the scripts directly from a terminal with the same flags; `--help` on any of them prints usage.

## Configuration

Setup writes `~/.claude/skill-sync/config`, a plain key=value file:

```
CONFIG_VERSION=1
MODE=git
SCOPE_MEMORY=0
GIT_REMOTE=git@github.com:you/claude-skills.git
GIT_BRANCH=main
AUTO_PUSH=0
ZIP_DIR=~/Desktop
EXCLUDE=.git:.DS_Store:*.bak
```

Re-running `/skill-sync:setup` rewrites it.
Two environment variables are honored: `CLAUDE_CONFIG_DIR`, the same one Claude Code uses to relocate `~/.claude`, and `SKILL_SYNC_HOME`, which moves the plugin's state directory (config, clone, backups, log) somewhere else.

## Requirements

Claude Code with plugin support, `bash` 3.2 or newer (the version macOS ships), and `zip` and `unzip`.
Git mode also needs `git` and SSH or HTTPS access to your remote.
`jq` is used when present and not required.
Tested on macOS and Linux.

## Caveats

Claude Code reads skills at startup.
After a pull or import, restart it or run `/reload-plugins`.

If you edit the same skill on both machines without syncing in between, `push` will refuse when the remote has moved.
Pull first, then push.
Conflicts are ordinary git conflicts inside `~/.claude/skill-sync/repo` and are resolved there.

Memory files are Markdown that Claude writes on its own.
Syncing them means one machine's notes about a project overwrite the other's.
That is usually what you want, and it is why memory is off by default.

## Uninstall

```
/plugin uninstall skill-sync@claude-skill-sync
```

Your skills stay where they are.
Delete `~/.claude/skill-sync` to remove the config, the clone, the backups, and the log.

## Development

```
claude --plugin-dir .
bats tests
shellcheck scripts/*.sh
claude plugin validate .
```

Scripts target bash 3.2 and avoid `rsync`, because macOS now ships `openrsync` with a different flag set.
The reasoning behind each decision is in [docs/PLAN.md](docs/PLAN.md).

## License

MIT.
