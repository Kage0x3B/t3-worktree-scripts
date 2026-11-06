#!/usr/bin/env bash
# Run myapp from a git worktree beside the main checkout: own ports, own database copy,
# schedulers off. Template: copy to scripts/worktree/wt.sh next to wt-lib.sh and adapt.
#
#   wt.sh setup [--no-install] [--no-build] [--no-db]   allocate slot, copy+patch env, install, build, clone DB
#   wt.sh info                                          slot, URLs, database, what runs, pending migrations
#   wt.sh list                                          all worktree slots of this repo and what runs in them
#   wt.sh backend | frontend                            start one dev server in the foreground
#   wt.sh stop                                          stop this worktree's dev servers (data kept)
#   wt.sh settle                                        same as stop; T3 Code runs it when the thread settles
#   wt.sh teardown [--stop]                             drop DB, free the slot (refused while servers run)
#   wt.sh prune [--dry-run]                             drop DBs of worktrees that no longer exist
#   wt.sh migrations                                    list migrations this DB has not run (read-only)
#   wt.sh services                                      start the docker compose services
#   wt.sh config                                        re-copy env files from the main checkout and re-patch them
#                                                       (WT_LIVE=1: keep schedulers on)
#   wt.sh db reset [--fresh] | snapshot | psql | drop | gc
#
# In the main checkout every command runs with the stock config (slot 0, ports 130xx, DB myapp).
# The generic part lives in wt-lib.sh (vendored; edit its source, then `wt sync`).
set -euo pipefail

# --- config: adapt these ---------------------------------------------------------------------------
WT_PROJECT=myapp
WT_SCRIPT=scripts/worktree/wt.sh
WT_MAIN_DB=myapp                       # main checkout's dev database
WT_DB_PREFIX=myapp_wt_                 # worktree DBs: myapp_wt_<dir>_<hash>, template: myapp_wt_template
WT_PG_CONTAINER=myapp-postgres-1       # `docker ps` name of the dev Postgres
WT_PG_USER=postgres
WT_MAX_SLOT=8
WT_GENERATED_FILES=(apps/backend/.env) # removed on teardown
WT_MIGRATE_HINT="pnpm --filter backend migration:run"
# Gitignored env files a worktree needs from the main checkout.
ENV_FILES=(
    apps/backend/.env.development
    apps/frontend/.env
)

# shellcheck source=wt-lib.sh
. "$(dirname "$(readlink -f "$0")")/wt-lib.sh"

dc() { docker compose -p myapp -f "$MAIN_ROOT/docker-compose.yml" "$@"; }

# Slot N gets 13000 + 100·N: backend +0, frontend +1. Slot 0 (main) keeps today's ports.
wt_ports() {
    BASE=$((13000 + SLOT * 100))
    BACKEND_PORT=$BASE FRONTEND_PORT=$((BASE + 1))
    WT_PORTS=("backend=$BACKEND_PORT" "frontend=$FRONTEND_PORT")
}

# Shared services from the main checkout's compose file. Postgres stays shared: each worktree
# only gets its own database inside it.
wt_services() { dc up -d --wait postgres >/dev/null 2>&1 || dc up -d postgres; }

# Rewrite main's dev ports (:13000, :13001) in a text to this slot's ports; hosts stay.
shift_ports() { sed -E "s/:1300([01])([^0-9]|$)/:$((BASE / 100))0\1\2/g"; }

wt_config() {
    copy_from_main "${ENV_FILES[@]}"

    # Backend overrides go into apps/backend/.env, assumed to be read after .env.development.
    local env="$ROOT/apps/backend/.env"
    mkdir -p "$(dirname "$env")"
    : >"$env"
    set_env "$env" PORT "$BACKEND_PORT"
    set_env "$env" DATABASE_NAME "$DB"
    set_env "$env" CORS_ORIGINS "$(cors_origins "$FRONTEND_PORT")"
    # Cookies ignore ports: without its own name, logging in here logs you out of main.
    set_env "$env" SESSION_COOKIE_NAME "sid-wt$SLOT"
    # The DB copy holds real data: no crons, no outbound mail from a worktree by default.
    if [ "${WT_LIVE:-0}" != 1 ]; then
        set_env "$env" DISABLE_SCHEDULERS true
        set_env "$env" MAIL_TRANSPORT capture
    fi

    # Make plain `pnpm dev` in apps/frontend slot-aware too (vite.config reads DEV_SERVER_PORT).
    local fe="$ROOT/apps/frontend/.env.development.local" api
    mkdir -p "$(dirname "$fe")"
    touch "$fe"
    api="$(app_env frontend PUBLIC_API_URL | shift_ports)"
    [ -n "$api" ] && set_env "$fe" PUBLIC_API_URL "$api"
    set_env "$fe" DEV_SERVER_PORT "$FRONTEND_PORT"

    log "patched config (backend $BACKEND_PORT, frontend $FRONTEND_PORT, db $DB$([ "${WT_LIVE:-0}" = 1 ] && echo ', LIVE schedulers' || echo ', schedulers off'))"
}

wt_install() { (cd "$ROOT" && pnpm install --frozen-lockfile --prefer-offline); }

# Whatever `pnpm dev` needs in a fresh checkout (shared libs, codegen). Reusing main's turbo cache
# makes this near-instant on an unchanged base.
wt_build() { (cd "$ROOT" && pnpm exec turbo run build --filter='./packages/*' --cache-dir="$MAIN_ROOT/.turbo/cache"); }

# Migration files this DB has not run yet (read-only). Adapt table/column/dir to your ORM.
wt_pending_migrations() {
    local ran file name
    ran=" $(sql_db "$DB" 'SELECT name FROM migrations' 2>/dev/null | tr '\n' ' ') "
    for file in "$ROOT"/apps/backend/src/migrations/*.ts; do
        [ -e "$file" ] || continue
        name="$(basename "$file" .ts)"
        [[ "$ran" == *" $name "* ]] || echo "$name"
    done
}

# Never start a worktree backend that still points at the main database.
guard_backend_db() {
    is_main && return
    local configured
    configured="$(sed -n 's/^DATABASE_NAME=//p' "$ROOT/apps/backend/.env" 2>/dev/null)"
    [ "$configured" = "$DB" ] || die "apps/backend/.env points at database '${configured:-?}', not $DB — run: $WT_SCRIPT config"
}

wt_cmd_backend() {
    load_state
    # LAN IPs change with DHCP: refresh CORS on every start.
    is_main || set_env "$ROOT/apps/backend/.env" CORS_ORIGINS "$(cors_origins "$FRONTEND_PORT")"
    guard_backend_db
    ensure_services
    log "backend → port $BACKEND_PORT (db $DB)"
    cd "$ROOT/apps/backend" && exec pnpm dev
}

wt_cmd_frontend() {
    load_state
    if ! is_main; then
        [ "$(app_env frontend DEV_SERVER_PORT)" = "$FRONTEND_PORT" ] || die "apps/frontend has no slot config — run: $WT_SCRIPT config"
    fi
    log "frontend → port $FRONTEND_PORT"
    exec pnpm --dir "$ROOT/apps/frontend" dev
}

wt_main "$@"
