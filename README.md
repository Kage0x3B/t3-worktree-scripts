# t3-worktree-scripts

Every [T3 Code](https://t3.codes) thread in worktree mode gets its own git worktree. These scripts
turn each worktree into its own isolated dev instance, so several agents can run the backend and
frontends at the same time without fighting over ports, the database or the login cookie.

Works on Linux and macOS (macOS tested in CI only, via Homebrew Postgres; Docker Desktop not tested).

Per worktree you get:

- **A slot** (1, 2, 3 …) with its own port block. The main checkout stays slot 0 and keeps its ports.
- **Its own Postgres database**: a copy of your main dev DB, cloned in seconds via `CREATE DATABASE … TEMPLATE`.
- **Patched env files**: copied from the main checkout, with ports, DB name, CORS origins and cookie name moved to the slot.
- **Offline by default**: schedulers and outbound mail off, because the DB copy holds real data.
- **Lifecycle**: `settle` stops the servers when the T3 thread settles; `teardown` drops the DB and frees the slot; `prune` cleans up after worktrees T3 deleted.

## What's in here

| Path | What it is |
| --- | --- |
| `wt/wt-lib.sh` | The engine. Generic bash: slots, DB copies, stop/settle/teardown/prune, `db` commands. Each project vendors an identical copy. |
| `wt/wt` | Cross-project CLI (Python 3, no deps). `wt status` lists every worktree of every T3 project with its slot, thread state, RAM, ports, git state and a suggestion (stop / teardown). |
| `examples/wt.sh` | Project template: backend + frontend, shared Postgres from docker compose. Copy and adapt. |
| `examples/t3.json` | Matching T3 Code project scripts (Setup on worktree create, Settle on thread settle, server buttons). |
| `skill/t3-worktree-setup/` | Claude Code skill that walks an agent through setting this up in a new repo. |

## Requirements

bash, git, Docker with the dev Postgres in a container, Python 3 for `wt`.

The scripts detect the OS themselves.

- **Linux**: uses `/proc`, `ss`, `ip`, `flock` and `sha1sum` (all standard).
- **macOS** (12.3+): uses the built-in `lsof`, `ps`, `ifconfig` and `shasum`, and a `mkdir` lock instead of
  `flock`. The stock `/bin/bash` 3.2 works; Homebrew bash is fine too. `lsof` only sees your own
  processes, so a server another user started on a slot port is not detected.
- `wt` assumes T3 Code keeps its state in `~/.t3/userdata` on macOS too (unverified).

## Tests

```bash
tests/run.sh                         # needs Docker (or WT_TEST_PG=local with initdb/pg_ctl on PATH)
WT_TEST_FORCE_OS=Darwin tests/run.sh # the macOS code paths, run on Linux
```

It builds a throwaway repo with worktrees in a temp dir and starts its own Postgres (container
`wt-test-postgres`, databases `wttest_*`, ports 23100+), so it never touches your real projects.
CI runs it on Ubuntu and macOS (`.github/workflows/test.yml`), plus shellcheck.

## Install

```bash
git clone https://github.com/Kage0x3B/t3-worktree-scripts ~/dev/t3-worktree-scripts
ln -s ~/dev/t3-worktree-scripts/wt/wt ~/.local/bin/wt      # any dir on PATH
```

Optional, to let Claude Code set up a project for you:

```bash
ln -s ~/dev/t3-worktree-scripts/skill/t3-worktree-setup ~/.claude/skills/t3-worktree-setup
```

## Add it to a project

1. Copy the engine and the template:
   ```bash
   mkdir -p scripts/worktree
   cp ~/dev/t3-worktree-scripts/wt/wt-lib.sh scripts/worktree/
   cp ~/dev/t3-worktree-scripts/examples/wt.sh scripts/worktree/
   cp ~/dev/t3-worktree-scripts/examples/t3.json .
   chmod +x scripts/worktree/wt.sh
   echo .worktree/ >> .gitignore
   ```
2. Edit the config block at the top of `wt.sh` (project name, DB names, Postgres container, env files)
   and the hooks below it (`wt_ports`, `wt_config`, `wt_cmd_<server>`). The header of `wt-lib.sh`
   lists every config var and hook.
3. Make your app read the overrides: the backend must take `PORT`, the DB name, CORS origins and the
   session cookie name from env; the frontend's dev server must take its port from
   `DEV_SERVER_PORT` (e.g. in `vite.config.ts`).
4. Commit everything, including the vendored `wt-lib.sh`, so teammates without this repo can use it.
   T3 only picks up `t3.json` for worktrees branched from a commit that has it.

Or, with the skill installed, ask Claude Code: *"set up T3 worktree instances for this repo"*. It
surveys the apps, services, cookies and crons first, then builds and verifies the setup.

## Daily use

In T3 the buttons from `t3.json` cover it. From a shell inside a worktree:

```bash
scripts/worktree/wt.sh info          # slot, URLs, DB, what runs, pending migrations
scripts/worktree/wt.sh backend       # start a server on the slot's port
scripts/worktree/wt.sh db reset      # fresh copy of the main DB (--fresh: re-snapshot main first)
scripts/worktree/wt.sh teardown      # drop DB, free the slot (code and branch stay)
```

Across all projects:

```bash
wt status                 # what runs where, what can go
wt stop --suggested       # stop servers of settled/idle threads
wt teardown --suggested   # free slots of merged/archived worktrees with nothing unpushed
wt gc                     # drop DBs and stop servers of worktrees that no longer exist
wt sync                   # after `git pull` here: copy the new wt-lib.sh into every project (then commit)
```

`wt` finds projects through T3 Code's own database (`~/.t3/userdata/statev2.sqlite`, read-only)
plus any paths listed in `~/.config/wt/projects`, and looks for `scripts/worktree/wt.sh`,
`tools/worktree/wt.sh` or `scripts/wt.sh` in each.

## Safety

- The main database is never written to: worktree tooling only reads it to snapshot. Only databases with
  your `WT_DB_PREFIX` are ever dropped.
- `teardown` refuses while servers run (`--stop` overrides), warns about uncommitted or unpushed
  work, and never touches code or branches.
- `stop` only kills processes whose working directory is inside that worktree; shells and coding
  agents are skipped.
- Pending migrations are reported, never run.
- `WT_LIVE=1 wt.sh config` turns schedulers back on for one worktree when you need them.

## Good to know about T3 Code

- Archiving, settling or deleting a thread does not stop its dev servers. That's what the
  `runOnSettle` script is for.
- T3's storage cleanup removes old worktrees (per your settings) without running any hook, so their
  DBs stay behind. `setup` prunes them, or run `wt gc`.
