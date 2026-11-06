---
name: t3-worktree-setup
description: Set up a monorepo (backend + one or more frontends + docker compose services) so every git worktree / T3 Code thread runs as its own isolated dev instance — own ports, own DB copy, own session cookie, schedulers and outbound integrations off — plus a checked-in t3.json with setup, dev-server, check, DB and teardown scripts. Built on the shared bash engine wt-lib.sh from the t3-worktree-scripts repo (stop/settle/teardown/prune/describe) with the cross-project `wt status` overview. Use when asked to "set up T3 Code", "make worktrees work", add a t3.json, run backend/frontends from a worktree, tear down or clean up worktree instances, find which slots can be stopped, or audit an existing worktree setup.
---

# T3 Code + worktree dev instances for a monorepo

Goal: a T3 thread gets a fresh worktree, the **Setup** script makes it a ready, isolated instance,
and the agent (or user) starts only the servers the problem needs. The main checkout keeps working
byte-for-byte as before.

**Start from the shared engine.** `wt-lib.sh` (in the `wt/` folder of the t3-worktree-scripts repo) implements
the generic part (slot allocation, Postgres DB copies, stop/settle/teardown with safety checks, prune,
describe, db commands). A repo vendors an identical copy next to its `wt.sh`; `wt.sh` sets config
vars, defines hooks (`wt_ports`, `wt_config`, `wt_*_extra`, `wt_cmd_<server>`), sources the lib and
calls `wt_main "$@"`. Read the lib header for the full contract. Never edit a vendored copy: change
the source, then `wt sync` copies it everywhere (commit the copies). Vendoring keeps the repo working
for teammates who have not cloned the tooling.

Reference implementation: `examples/wt.sh` + `examples/t3.json` in the same repo (backend + frontend,
shared Postgres from docker compose, one DB copy per worktree). Read it before building a new one.

Bigger setups with many services, strict security needs or a tested-tooling culture can use Node
scripts with tests and a per-slot docker compose project instead of the bash engine.

## 1. Survey first

Before writing anything, find out (and write down for the user):

1. **Every** app (list `apps/*` — marketing sites and MCP servers too, not only the ones in `pnpm dev`) and how each one gets its config: env files (`.env`, `.env.development.local`, TOML), which
   are gitignored and must come from the main checkout, how ports are set (`vite.config.ts`
   `server.port`, backend config `port`).
2. Services in `docker-compose.yml` (Postgres, Redis, search, object storage, mail) and their ports.
3. Session/auth: cookie name, cookie domain, CORS origins, anything bound to one origin (passkeys /
   WebAuthn, OAuth redirect URIs).
4. Everything that runs on its own or talks to the outside: crons (`@Cron`, `@Interval`, schedulers
   in feature modules — not only the module a config flag gates), job queues, mail/SMS/push, payment
   and bank integrations, third-party syncs, webhooks, uploads to shared buckets.
5. Build steps a fresh checkout needs before `dev` works (shared libs, generated files such as
   Swagger metadata, codegen) and whether the build cache restores them (turbo `outputs`!).
6. Does `t3.json` exist? Is there a project-level script list in T3 already (`t3_project_read`)?

## 2. Instance identity

- **Main checkout = slot 0** with today's ports, DB and cookie. Never change its behaviour.
- **Detect a linked worktree** by comparing `git rev-parse --git-dir` with `--git-common-dir`
  (or: `.git` is a *file* whose `gitdir:` contains `/.git/worktrees/`; submodules are not worktrees).
  Main checkout root = parent of `--git-common-dir`.
- **Allocate the smallest free slot ≥ 1** under a lock (`flock` on a file in the common git dir, or
  an atomic `mkdir` lock). Free = not claimed by a worktree that still exists, so slots of deleted
  worktrees are reused automatically.
- **Store the slot in a gitignored file** in the worktree (`.worktree/env`, `.env.slot`), add it to
  `.gitignore`. Derive everything else (ports, DB name, cookie name, compose project) from the slot.
- Never let a slot leak into child processes through inherited env vars (strip them).

## 3. Ports

- Fixed block per slot: `base + slot·stride`, same offsets as main (e.g. 13100 + 100·N,
  backend +0, app +1, admin +2, member +3; or 16000 + 10·N for app *and* service ports).
- Deterministic, not probed. Use `strictPort` so a taken port fails loudly instead of hopping.
- **Make plain `pnpm dev` slot-aware**, not only the wrapper script: generate per-app env
  (`.env.development.local` with `DEV_SERVER_PORT` + shifted `PUBLIC_*` URLs, or a
  `.env.slot` that outranks `.env`) and have `vite.config.ts` / the backend config read it.
  Agents will run `pnpm dev:admin` directly.
- Keep main's hosts, move only the ports: shift `:<mainPort>` occurrences in the copied config
  (`sed -E 's/:1310([0-3])([^0-9]|$)/:13N0\1\2/g'`) instead of rewriting URLs from scratch.

## 4. Sessions, cookies, CORS

- **Cookies ignore ports.** Two backends on one host overwrite each other's session cookie. Give
  each instance its own cookie name (`sid-wtN`, or `<name>_<frontendPort>` on loopback hosts)
  via a backend config key with the old name as default. Then update every frontend place that
  reads/relays the cookie by name (SSR cookie relay, JWT/SSO hooks) to accept the pattern.
- Alternatives and why not: per-loopback-IP hosts (`127.0.0.1N`) work but break LAN/phone access;
  `*.localhost` subdomains break when other tooling hard-codes `127.0.0.1`.
- Any hard-coded backend port in frontend server hooks (e.g. "forward cookies if port === 13100")
  must come from the configured API URL instead.
- **CORS**: list every frontend origin of the slot for `127.0.0.1`, `localhost` and — if the repo
  supports phone/LAN testing — the current LAN IPs (skip docker/VPN interfaces). Regenerate on each
  backend start; DHCP moves the IP. Origin-bound features (passkeys, OAuth redirect URIs) need the
  slot's origin too.

## 5. Database

- Copy the main dev DB, never share it. Main DB is read-only for worktree tooling.
- **Shared Postgres** (the engine default): snapshot main once into `<db>_wt_template` (`pg_dump -Fc | pg_restore`
  *inside* the container — same version, no data on the host), then per worktree
  `CREATE DATABASE <db>_wt_<dir> TEMPLATE <db>_wt_template STRATEGY FILE_COPY` (seconds).
  `db reset [--fresh]` re-clones (fresh = re-snapshot first).
- **Per-slot container**: dump main → restore into `<db>_clone` → rename-swap with rollback.
- Name worktree DBs with a prefix (`<db>_wt_`) so garbage collection can find them; drop DBs whose
  worktree is gone on every `setup` (git/T3 delete worktrees without a hook).
- **Guard**: refuse to start a worktree backend whose config still points at the main DB (setup not
  run, file copied by hand). Stricter option: a guard package every DB entry point must call,
  enforced by a CI lint.
- **Migrations: report, never run.** Show pending migrations at the end of setup and in `info`
  (compare migration file timestamps with the `migrations` table — fast, read-only). Running them
  stays a user action (a T3 script button is fine).

## 6. Schedulers and outbound side effects — offline by default

The DB copy holds real people and real credentials. A worktree must not become a second job runner
or reach real customers, banks or partners.

- **Schedulers**: a config flag that unschedules *every* cron/interval/timeout after `app.init()`
  (NestJS: `SchedulerRegistry.getCronJobs()/getIntervals()/getTimeouts()` → delete), set only in
  worktrees. Module-level "cron enabled" flags usually miss feature-module crons — check.
- **Mail / SMS / push**: route to a local catcher (Mailpit per slot, or the app's own capture mode,
  e.g. `mailer.provider = "capture"` shown in an admin inbox).
- **Payments / banking**: remove the credential that unlocks them (e.g. drop the config block that holds the
  payment or bank keys, so they cannot be used).
- **Third-party syncs**: a single "external sync off" switch that holds (not fails) such jobs, and
  optionally a socket-level egress fence with an allow-list for LLM APIs.
- Shared services you don't copy (search index, buckets) must be listed as caveats.
- Provide an explicit opt-out (`WT_LIVE=1`) rather than making live mode the default.

## 7. Setup script (runs on worktree creation)

Idempotent; in the main checkout it is a no-op or runs the stock config. Order:

1. Allocate slot (prune orphans first).
2. Copy gitignored env files from the main checkout; patch them (ports, DB, cookie, CORS, offline
   settings). Never generate or print secrets.
3. `pnpm install --frozen-lockfile --prefer-offline`.
4. Build what `dev` needs (shared libs, generated metadata). Verify cache hits restore the outputs:
   every package's build output dir must be in turbo `outputs`, or a cached task restores nothing.
5. Start docker services (`up -d --wait`, protocol-level readiness), clone DB if missing.
6. Garbage-collect orphaned DBs/containers; print URLs and pending migrations.

Other commands (the engine provides all but the server ones): `info` (URLs incl. LAN, DB, what
runs, pending migrations), one command per server (`backend` ensures services first), `list`,
`describe` (key=value identity for tooling), `stop`, `settle`, `teardown [--stop]`,
`prune [--dry-run]`, `db reset|snapshot|psql|drop`, `config` (re-copy + re-patch).

## 7b. Lifecycle: stop, settle, teardown, prune

What T3 Code does on its own (verified in the T3 0.1 bundle):

- **Archive/settle/delete never removes the worktree.** A separate hourly *storage cleanup* does,
  per settings (`storageCleanup`: after N days, on merge, on thread delete, unchanged branch). It
  runs `git worktree remove` (no `--force`: dirty worktrees stay), never deletes the branch, and
  runs **no hook** — the instance's DB and containers are left behind.
- **Processes are not stopped.** Agents run in `t3code-claude-*.scope` units; a dev server an
  agent started keeps its scope alive for days. Closing a thread terminal only SIGTERMs the shell.
- **`runOnSettle`** in t3.json runs one script in the worktree each time the thread settles
  (manually, PR merged, or N idle days). It is the only lifecycle hook besides worktree creation.

So the tooling must provide:

- **stop**: kill processes whose cwd is inside the worktree (not inside a nested worktree; not
  shells, agents or the script itself) and stop the slot's own containers; keep data.
- **settle** = stop, wired as `runOnSettle` → a settled thread frees its RAM automatically.
- **teardown**: refuse while servers run (`--stop` stops them), report uncommitted/unpushed work
  (teardown never touches code), no-op with exit 0 without a slot, never leave Docker running
  that it had to start (start shared Postgres temporarily, stop it again), remove everything setup
  created (DBs in every engine, own containers + volumes, generated env files, state dir).
- **prune** (also on every setup): drop resources of worktrees whose dir is gone, `--dry-run`.
- **describe**: machine-readable slot/ports/db/containers. Label own containers with
  `wt.root=<worktree path>` so tools can map them.

Cross-project overview: `wt status` (`wt/wt` from the t3-worktree-scripts repo, on PATH) lists every worktree of
every T3 project with slot, T3 thread state, agent, RAM, ports, git state and a verdict (stop /
teardown / active); `wt stop|teardown --suggested`, `wt gc`, `wt sync`.

## 8. t3.json

Checked in at the repo root (schema `https://t3.codes/schema/t3.json`; fields: `iconPath`,
`defaultThreadEnvMode`, `worktreeSubmodules`, `scripts[]` with `name`, `command`, `icon`
(`play|test|lint|configure|build|debug`), `runOnWorktreeCreate`, `async`, `runOnSettle`,
`previewUrl`, `autoOpenPreview`). Commands run at the worktree root.

```json
{
    "$schema": "https://t3.codes/schema/t3.json",
    "iconPath": "apps/admin/src/lib/assets/favicon.svg",
    "defaultThreadEnvMode": "worktree",
    "scripts": [
        { "name": "Setup", "command": "tools/worktree/wt.sh setup", "icon": "configure", "runOnWorktreeCreate": true, "async": false },
        { "name": "Info", "command": "tools/worktree/wt.sh info", "icon": "debug" },
        { "name": "All dev servers", "command": "pnpm dev", "icon": "play" },
        { "name": "Backend", "command": "tools/worktree/wt.sh backend", "icon": "play" },
        { "name": "Admin", "command": "tools/worktree/wt.sh admin", "icon": "play" },
        { "name": "Build libs", "command": "pnpm build:lib", "icon": "build" },
        { "name": "Lint", "command": "pnpm lint", "icon": "lint" },
        { "name": "Format", "command": "pnpm format", "icon": "lint" },
        { "name": "Unit tests", "command": "pnpm test 2>&1 | tail -200", "icon": "test" },
        { "name": "Pending migrations", "command": "tools/worktree/wt.sh migrations", "icon": "debug" },
        { "name": "Run migrations", "command": "pnpm --filter <backend> typeorm migration:run", "icon": "build" },
        { "name": "DB reset", "command": "tools/worktree/wt.sh db reset", "icon": "configure" },
        { "name": "List worktree instances", "command": "tools/worktree/wt.sh list", "icon": "debug" },
        { "name": "Prune removed worktrees", "command": "tools/worktree/wt.sh prune", "icon": "configure" },
        { "name": "Stop servers", "command": "tools/worktree/wt.sh stop", "icon": "configure" },
        { "name": "Settle: stop servers", "command": "tools/worktree/wt.sh settle", "icon": "configure", "runOnSettle": true },
        { "name": "Teardown", "command": "tools/worktree/wt.sh teardown --stop", "icon": "configure" }
    ]
}
```

- `async: false` on Setup holds the agent until the instance is ready (install + builds); use
  `true` only if setup is long and the agent can usefully read code meanwhile.
- Only the first script with `runOnSettle: true` runs; it gets `T3CODE_WORKTREE_PATH`.
- `previewUrl` is static; with per-slot ports leave it out and have agents read `info` instead.
- Pipe test scripts through `tail` so output stays readable in the terminal.
- `t3_project_update` (project-level scripts) needs a full-access thread; `t3.json` needs nothing
  but a commit — and it only reaches new worktrees once it is on the branch they start from.

## 9. Documentation and agent instructions

- `docs/WORKTREES.md`: table main vs slot N (ports, cookie, DB, schedulers, integrations, docker),
  the why of each choice, commands, T3 scripts, caveats (shared services, opt-out risks).
- One line in the repo's `CLAUDE.md`/`AGENTS.md`: "In a worktree the servers run on its own ports
  and DB; `<info command>` prints the URLs."

## 10. Verify before calling it done

Run in an actual worktree, with the main dev servers running:

- [ ] `setup` from scratch succeeds; second run is a no-op that keeps the DB.
- [ ] Backend health on the slot port; plain `pnpm dev:<frontend>` binds the slot port.
- [ ] Login on the worktree sets the slot cookie; the main instance stays logged in; frontend SSR
      works with the cookie and redirects without it; a main-style cookie is ignored by the worktree.
- [ ] CORS allows the slot's frontend origins (and LAN origin if supported).
- [ ] Log shows schedulers unscheduled and mail/push captured; nothing outbound for a few minutes.
- [ ] `info`, `list`, `describe`, `migrations` (probe with a fake future migration file).
- [ ] Lifecycle: fake server on the slot's backend port (`setsid python3 -m http.server <port>`
      with cwd in the worktree) → `teardown` refuses, `stop` kills it, `teardown --stop` drops
      everything; `teardown` without a slot exits 0; `prune --dry-run` lists only real orphans;
      `describe` from an existing (legacy) worktree loads its state unchanged; `wt status` shows
      the slot and its containers.
- [ ] Lint/typecheck/build of every touched app; tests of touched config code.
- Stop test servers by PID from `pgrep` on the *server* command; never `pkill -f` a pattern that
  also matches your own shell command line, never kill by port.

## Pitfalls seen in practice

- Turbo cache hit restores nothing when a package builds to `dist/` but the task declares `lib/**`.
- Generated files (Swagger `metadata.ts`) go stale after a rebase onto a branch without some DTOs →
  "Cannot find module …dto.js"; regenerate in setup and offer a "Build libs" script.
- A frontend that hard-codes the dev API port in server hooks silently drops cookies on other ports.
- `enableCron`-style flags often gate only one module; feature crons keep running.
- Under `set -eo pipefail`, a `for … do [ … ] && echo; done | …` whose last test is false fails
  the whole assignment and exits the script silently — use `if` inside loops feeding pipes.
- Scanning `/proc` for "processes in this worktree" also finds the script's own subshells,
  helpers (`tr`, `cat`) and the other commands of its pipeline (`wt.sh teardown | tail`). Exclude
  descendants of `$$` and processes with the same parent and process group — not "cmdline contains
  wt.sh", which also hides servers started via `sh -c "wt.sh backend"`.
- Allocate only slots whose ports are free: servers of deleted worktrees keep running (cwd shows
  `(deleted)`) and hold their old slot's ports.
- zsh has no `PIPESTATUS`; inline python heredocs whose body contains a line `EOF` end the heredoc.
