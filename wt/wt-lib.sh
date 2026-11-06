# shellcheck shell=bash
# wt-lib.sh: shared engine for per-worktree dev instances (own slot, ports, Postgres DB copy).
#
# VENDORED FILE. The source of truth is wt/wt-lib.sh in the t3-worktree-scripts repo; `wt sync` copies it into
# every project. Do not edit the copy in a project: change the source and sync.
#
# A project's wt.sh sets the config below, defines hooks, then sources this file and calls
# `wt_main "$@"`. Commands provided here:
#   setup [--no-install] [--no-build] [--no-db]   allocate slot, config, install, build, clone DB
#   info | list | describe | migrations | services | config
#   stop                 stop this worktree's dev servers and own containers (data kept)
#   settle               = stop; run by T3 Code when the thread settles (t3.json runOnSettle)
#   teardown [--stop]    drop DB + own resources, free the slot (refuses while servers run)
#   prune [--dry-run]    drop DBs/resources of worktrees that no longer exist
#   db reset [--fresh] | snapshot | psql [args] | drop | gc
# plus every `wt_cmd_<name>` function the project defines (`wt.sh <name>`).
#
# Config (required): WT_PROJECT WT_SCRIPT WT_MAIN_DB WT_DB_PREFIX WT_PG_CONTAINER WT_PG_USER
# Config (optional): WT_MIGRATE_HINT (command shown when migrations are pending), WT_MAX_SLOT (8), WT_STATE_DIR (.worktree), WT_GENERATED_FILES (paths removed
#   on teardown), WT_HTTPS_PORTS (WT_PORTS names served over https), WT_SLOT_KEYS / WT_ID_KEYS (state keys read for legacy state files)
# Hooks: wt_ports (required: set port vars for $SLOT and WT_PORTS=(name=port …)), wt_services,
#   wt_config, wt_install, wt_build, wt_setup_extra, wt_info, wt_pending_migrations,
#   wt_db_cloned (after a worktree DB was (re)cloned), wt_db_extra <sub> (after `db <sub>`),
#   wt_stop_extra, wt_teardown_extra, wt_gc_extra, wt_describe_extra.
# Setup exports WT_SETUP_INSTALL / WT_SETUP_BUILD / WT_SETUP_DB (1 or 0) for the hooks.
#
# Runs on Linux and macOS (WT_OS = `uname -s`). Linux uses /proc, ss, ip, flock and sha1sum; macOS uses
# lsof, ps, ifconfig, perl (for flock(2)) and shasum. Works with bash 3.2 (macOS /bin/bash) and later.
# wt_main checks the tools a command needs first (wt_preflight) and lists every missing one.

WT_LIB_VERSION=2

# --- basics --------------------------------------------------------------------------------------

log() { printf '\033[1;36m[wt]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[wt]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[wt]\033[0m %s\n' "$*" >&2; exit 1; }

WT_OS="$(uname -s)"
# Test suite only (tests/run.sh sets both): run the macOS code paths on Linux.
if [ "${WT_TEST_RUN:-}" = 1 ] && [ -n "${WT_TEST_FORCE_OS:-}" ]; then WT_OS=$WT_TEST_FORCE_OS; fi
case "$WT_OS" in
    Linux | Darwin) ;;
    *) die "unsupported OS: $WT_OS (wt-lib.sh runs on Linux and macOS)" ;;
esac
if [ "${BASH_VERSINFO[0]}" -lt 3 ] || { [ "${BASH_VERSINFO[0]}" = 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    die "bash $BASH_VERSION is too old: wt-lib.sh needs bash 3.2 or later"
fi
command -v git >/dev/null 2>&1 || die "missing required tool: git"

ROOT="$(git rev-parse --show-toplevel)"
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN_ROOT="$(dirname "$COMMON_DIR")"
# Never inherit another instance's identity from the parent shell.
unset SLOT ID DB WT_SLOT WT_ID

# macOS before 12.3 has no readlink -f: fall back to the script's physical directory.
WT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s/%s\n' "$(cd "$(dirname "$0")" && pwd -P)" "$(basename "$0")")"
is_main() { [ "$ROOT" = "$MAIN_ROOT" ]; }

wt_defaults() {
    : "${WT_MAX_SLOT:=8}" "${WT_STATE_DIR:=.worktree}"
    STATE_DIR="$ROOT/$WT_STATE_DIR"
    STATE_FILE="$STATE_DIR/env"
    TEMPLATE_DB="${WT_DB_PREFIX}template"
    [ -n "${WT_SLOT_KEYS+x}" ] || WT_SLOT_KEYS=(SLOT WT_SLOT)
    [ -n "${WT_ID_KEYS+x}" ] || WT_ID_KEYS=(ID WT_ID)
    [ -n "${WT_GENERATED_FILES+x}" ] || WT_GENERATED_FILES=()
    local v
    for v in WT_PROJECT WT_SCRIPT WT_MAIN_DB WT_DB_PREFIX WT_PG_CONTAINER WT_PG_USER; do
        [ -n "${!v:-}" ] || die "wt.sh does not set $v"
    done
}

# Paths of all registered worktrees whose directory still exists (main first).
wt_worktree_paths() {
    git -C "$MAIN_ROOT" worktree list --porcelain | sed -n 's/^worktree //p' | while read -r p; do
        [ -d "$p" ] && echo "$p"
    done
}

# Read KEY from a state file; first of several candidate keys wins.
state_get() {
    local file=$1 key
    shift
    for key in "$@"; do
        if grep -q "^$key=" "$file" 2>/dev/null; then
            sed -n "s/^$key=//p" "$file" | head -n1
            return
        fi
    done
}

# Identity of a worktree from its state file: "slot id db" (empty when it has none).
state_identity() {
    local file="$1/$WT_STATE_DIR/env" slot id db
    [ -f "$file" ] || return 0
    slot=$(state_get "$file" "${WT_SLOT_KEYS[@]}")
    id=$(state_get "$file" "${WT_ID_KEYS[@]}")
    db=$(state_get "$file" DB)
    [ -z "$db" ] && [ -n "$id" ] && db="$WT_DB_PREFIX$id"
    [ -z "$id" ] && [ -n "$db" ] && id="${db#"$WT_DB_PREFIX"}"
    echo "$slot $id $db"
}

has_state() { is_main || [ -f "$STATE_FILE" ]; }

load_state() {
    if is_main; then
        SLOT=0 ID=main DB=$WT_MAIN_DB
    else
        [ -f "$STATE_FILE" ] || die "no slot yet — run: $WT_SCRIPT setup"
        read -r SLOT ID DB <<<"$(state_identity "$ROOT")"
        [ -n "$SLOT" ] && [ -n "$DB" ] || die "$STATE_FILE is incomplete — run: $WT_SCRIPT teardown && $WT_SCRIPT setup"
    fi
    WT_PORTS=()
    wt_ports
}

# Worktree id: sanitized dir name plus a short hash of the full path, so two worktrees with the same
# dir name never share a database. Postgres identifiers stop at 63 bytes.
new_id() {
    local name hash
    # Byte-wise in the C locale, so GNU and BSD tr/cut give the same name (non-ASCII bytes → _).
    name="$(basename "$ROOT" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c '[:lower:][:digit:]\n' '_' | LC_ALL=C cut -c1-32)"
    if [ "$WT_OS" = Darwin ]; then
        hash="$(printf '%s' "$ROOT" | shasum -a 1 | cut -c1-6)"
    else
        hash="$(printf '%s' "$ROOT" | sha1sum | cut -c1-6)"
    fi
    echo "${name}_$hash"
}

# macOS has no flock(1): perl takes the same flock(2) lock on the shell's fd 9. The lock belongs to the
# open file, so it outlives the perl process and ends when the fd is closed or this script exits,
# exactly like `flock 9` (no stale locks).
slot_lock_darwin() {
    # shellcheck disable=SC2016 # perl code, not shell
    perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or die "fd 9: $!\n"; flock($f, LOCK_EX) or die "flock: $!\n"' ||
        die "could not lock $COMMON_DIR/wt-slots.lock"
}

# Lowest slot not claimed by another live worktree.
allocate_slot() {
    mkdir -p "$STATE_DIR"
    [ -f "$STATE_FILE" ] && return
    exec 9>"$COMMON_DIR/wt-slots.lock"
    if [ "$WT_OS" = Darwin ]; then slot_lock_darwin; else flock 9; fi
    local used=" " path slot id
    while read -r path; do
        [ "$path" = "$ROOT" ] && continue
        read -r slot _ <<<"$(state_identity "$path")"
        [ -n "$slot" ] && used+="$slot "
    done < <(wt_worktree_paths)
    for ((slot = 1; slot <= WT_MAX_SLOT; slot++)); do
        if [[ "$used" != *" $slot "* ]]; then
            # A slot whose ports are taken (e.g. a server left from a deleted worktree) is not free.
            local busy
            # shellcheck disable=SC1007 # ID= and DB= deliberately empty in this subshell
            busy="$(SLOT=$slot ID= DB=; WT_PORTS=(); wt_ports; listening_ports | tr '\n' ' ')"
            if [ -n "$busy" ]; then
                warn "slot $slot skipped: ports in use ($busy) — 'wt gc' stops servers of deleted worktrees"
                continue
            fi
            id="$(new_id)"
            printf 'SLOT=%s\nID=%s\nDB=%s\n' "$slot" "$id" "$WT_DB_PREFIX$id" >"$STATE_FILE"
            log "allocated slot $slot"
            exec 9>&-
            return
        fi
    done
    die "all $WT_MAX_SLOT slots in use — run 'wt status' to see which can be torn down"
}

# --- env file helpers (for wt_config hooks) -------------------------------------------------------

# Set KEY=value in a dotenv file, replacing an existing line or appending one.
set_env() {
    touch "$1"
    if grep -q "^$2=" "$1" 2>/dev/null; then
        local tmp="$1.tmp"
        awk -v k="$2" -v v="$3" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$1" >"$tmp" && mv "$tmp" "$1"
    else
        printf '%s=%s\n' "$2" "$3" >>"$1"
    fi
}

# A value as an app's dev env files set it (.local wins, as in Vite): app_env <app dir> <KEY>.
app_env() {
    local file
    for file in "$ROOT/apps/$1/.env.development.local" "$ROOT/apps/$1/.env.development" "$ROOT/apps/$1/.env"; do
        if [ -f "$file" ] && grep -q "^$2=" "$file"; then
            grep -m1 "^$2=" "$file" | cut -d= -f2- | tr -d '"'
            return
        fi
    done
}

# Copy gitignored files from the main checkout: copy_from_main <path>…
copy_from_main() {
    local file
    for file in "$@"; do
        if [ -f "$MAIN_ROOT/$file" ]; then
            mkdir -p "$(dirname "$ROOT/$file")"
            cp "$MAIN_ROOT/$file" "$ROOT/$file"
        else
            log "missing in main checkout, skipped: $file"
        fi
    done
}

# This machine's private LAN IPv4 addresses (docker bridges and VPN tunnels skipped).
lan_ips() {
    if [ "$WT_OS" = Darwin ]; then
        # Skip loopback, VPN tunnels, VM/container bridges and Apple's peer-to-peer links.
        ifconfig 2>/dev/null |
            awk '/^[^ \t]/ { iface = $1; sub(/:$/, "", iface) }
                 $1 == "inet" && iface !~ /^(lo|utun|tun|tap|wg|ipsec|ppp|gif|stf|bridge|vmenet|vnic|feth|awdl|llw|anpi|ap[0-9]|docker|tailscale)/ { print $2 }' |
            grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' || true
        return 0
    fi
    ip -4 -o addr show scope global 2>/dev/null |
        awk '$2 !~ /^(docker|br-|veth|virbr|tun|wg|tailscale|CloudflareWARP)/ { sub(/\/.*/, "", $4); print $4 }' |
        grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' || true
}

# CORS origins for the given ports on loopback and the current LAN IPs, http and https.
cors_origins() {
    local origins="" host port scheme
    for host in 127.0.0.1 localhost $(lan_ips); do
        for port in "$@"; do
            for scheme in http https; do
                origins+="${origins:+,}$scheme://$host:$port"
            done
        done
    done
    echo "$origins"
}

port_of() { # port_of <name>: port of a WT_PORTS entry
    local entry
    for entry in ${WT_PORTS[@]+"${WT_PORTS[@]}"}; do
        [ "${entry%%=*}" = "$1" ] && { echo "${entry#*=}"; return; }
    done
    die "no port named $1"
}

# --- postgres --------------------------------------------------------------------------------------

wt_pg() { docker exec -i "$WT_PG_CONTAINER" "$@"; }
sql() { wt_pg env PGOPTIONS='-c client_min_messages=warning' psql -U "$WT_PG_USER" -d postgres -v ON_ERROR_STOP=1 -qAt -c "$1"; }
sql_db() { wt_pg psql -U "$WT_PG_USER" -d "$1" -v ON_ERROR_STOP=1 -qAt -c "$2"; }
db_exists() { [ "$(sql "SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]; }
kick_connections() { sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$1' AND pid <> pg_backend_pid()" >/dev/null; }
pg_ready() { wt_pg pg_isready -U "$WT_PG_USER" -q >/dev/null 2>&1; }

wait_pg() {
    local i
    for ((i = 1; i <= 30; i++)); do
        pg_ready && return
        # Name the real cause instead of waiting 30s for a Docker daemon that is not running.
        [ $i = 1 ] && ! docker info >/dev/null 2>&1 && die "the Docker daemon is not reachable (docker info failed) — start Docker, then retry"
        sleep 1
    done
    die "postgres ($WT_PG_CONTAINER) did not become ready"
}

WT_SERVICES_UP=0
ensure_services() {
    [ "$WT_SERVICES_UP" = 1 ] && return
    if declare -F wt_services >/dev/null; then wt_services; else docker start "$WT_PG_CONTAINER" >/dev/null; fi
    wait_pg
    WT_SERVICES_UP=1
}

# Postgres for a one-off maintenance step: start it if it is down, and stop it again afterwards.
PG_STARTED_BY_US=0
with_pg_begin() {
    pg_ready && return
    log "postgres is down — starting $WT_PG_CONTAINER for this step"
    docker start "$WT_PG_CONTAINER" >/dev/null
    PG_STARTED_BY_US=1
    # Stop it again even when a later step fails under set -e.
    trap with_pg_end EXIT
    wait_pg
}
with_pg_end() {
    [ "$PG_STARTED_BY_US" = 1 ] || return 0
    PG_STARTED_BY_US=0
    docker stop "$WT_PG_CONTAINER" >/dev/null && log "stopped $WT_PG_CONTAINER again"
    return 0
}

db_snapshot() {
    ensure_services
    local tmp=${TEMPLATE_DB}_new
    log "snapshotting $WT_MAIN_DB → $TEMPLATE_DB"
    sql "DROP DATABASE IF EXISTS $tmp"
    sql "CREATE DATABASE $tmp"
    # Dump and restore inside the container: same pg version, no data leaves the box.
    wt_pg sh -c "pg_dump -U $WT_PG_USER -Fc $WT_MAIN_DB | pg_restore -U $WT_PG_USER -d $tmp --no-owner --no-privileges" ||
        log "pg_restore reported warnings (usually harmless)"
    kick_connections "$TEMPLATE_DB"
    sql "DROP DATABASE IF EXISTS $TEMPLATE_DB"
    sql "ALTER DATABASE $tmp RENAME TO $TEMPLATE_DB"
    log "template ready"
}

db_clone() {
    is_main && die "the main checkout uses $WT_MAIN_DB directly"
    ensure_services
    db_exists "$TEMPLATE_DB" || db_snapshot
    kick_connections "$DB"
    sql "DROP DATABASE IF EXISTS $DB"
    sql "CREATE DATABASE $DB TEMPLATE $TEMPLATE_DB STRATEGY FILE_COPY"
    log "database $DB cloned from $TEMPLATE_DB (snapshot of $WT_MAIN_DB)"
    if declare -F wt_db_cloned >/dev/null; then wt_db_cloned; fi
}

db_drop() {
    is_main && die "refusing to drop $WT_MAIN_DB"
    case "$DB" in "$WT_DB_PREFIX"*) ;; *) die "refusing to drop $DB: not a worktree database ($WT_DB_PREFIX*)" ;; esac
    kick_connections "$DB"
    sql "DROP DATABASE IF EXISTS $DB"
    log "dropped $DB"
}

# Ids, slots and DBs of all worktrees that still exist and have a slot.
live_identities() {
    local path
    while read -r path; do
        [ "$path" = "$MAIN_ROOT" ] && continue
        state_identity "$path"
    done < <(wt_worktree_paths)
}

# Drop worktree DBs (and, via wt_gc_extra, other resources) whose worktree no longer exists.
prune() {
    local dry=0
    [ "${1:-}" = --dry-run ] && dry=1
    local live
    live=" $(live_identities | tr '\n' ' ') "
    WT_LIVE_SLOTS=" " WT_LIVE_IDS=" "
    local slot id db
    while read -r slot id db; do
        [ -n "$slot" ] && WT_LIVE_SLOTS+="$slot " WT_LIVE_IDS+="$id "
    done < <(live_identities)
    export WT_LIVE_SLOTS WT_LIVE_IDS WT_DRY_RUN=$dry
    if pg_ready; then
        local name
        for name in $(sql "SELECT datname FROM pg_database WHERE datname LIKE '$(sed 's/_/\\_/g' <<<"$WT_DB_PREFIX")%'"); do
            case "$name" in "$TEMPLATE_DB" | "${TEMPLATE_DB}_new" | *_new) continue ;; esac
            [[ "$live" == *" $name "* ]] && continue
            if [ $dry = 1 ]; then
                log "would drop orphaned $name"
            else
                kick_connections "$name"
                sql "DROP DATABASE IF EXISTS $name"
                log "dropped orphaned $name"
            fi
        done
    else
        log "postgres is down — orphaned databases are checked on the next prune"
    fi
    if declare -F wt_gc_extra >/dev/null; then wt_gc_extra; fi
}

# --- processes ------------------------------------------------------------------------------------

# PIDs of this process and its ancestors (never stop the shell running this script).
self_chain() {
    local pid=$$
    while [ "${pid:-0}" -gt 1 ]; do
        echo "$pid"
        if [ "$WT_OS" = Darwin ]; then
            pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
        else
            pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || break
        fi
    done
}

# "pid cwd" of every process we may inspect (macOS: from lsof; Linux reads /proc directly).
proc_cwds_darwin() {
    lsof -n -d cwd -Fpn 2>/dev/null | awk '/^p/ { pid = substr($0, 2) } /^n/ { print pid, substr($0, 2) }' || true
}

# Process name like /proc/<pid>/comm: basename of the executable, login shells' "-" dropped.
proc_comm_darwin() {
    local comm
    comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
    [ -n "$comm" ] || return 1
    comm=${comm#-}
    echo "${comm##*/}"
}

# PIDs of processes working inside this worktree: cwd below $ROOT and not below a nested worktree,
# excluding interactive shells, coding agents and this script itself.
worktree_pids() {
    local self others p cwd comm o nested
    # Never this script, its ancestors, its own children (subshells, helpers) or the other commands
    # of its pipeline (`wt.sh teardown | tail`: same parent and process group).
    # shellcheck disable=SC2054 # commas belong to the ps format list
    local ps_all=(ps -eo pid=,ppid=,pgid=)
    # shellcheck disable=SC2054
    [ "$WT_OS" = Darwin ] && ps_all=(ps -A -o pid=,ppid=,pgid=)
    self=" $(self_chain | tr '\n' ' ') $("${ps_all[@]}" | awk -v root=$$ '
        { parent[$1] = $2; group[$1] = $3 }
        END {
            for (p in parent) {
                if (parent[p] == parent[root] && group[p] == group[root]) { print p; continue }
                q = p
                while (q > 1) { if (parent[q] == root) { print p; break } q = parent[q] }
            }
        }' | tr '\n' ' ') "
    others="$(wt_worktree_paths | grep -vxF "$ROOT" || true)"
    if [ "$WT_OS" = Darwin ]; then
        # Captured first: lsof and awk list themselves, and are gone (no comm) when checked below.
        # lsof prints physical paths (/private/var/…): compare against physical paths.
        local pid cwds root_p others_p=""
        cwds="$(proc_cwds_darwin)"
        root_p="$(cd "$ROOT" 2>/dev/null && pwd -P || printf '%s\n' "$ROOT")"
        while read -r o; do
            [ -n "$o" ] && others_p+="$(cd "$o" 2>/dev/null && pwd -P || printf '%s\n' "$o")"$'\n'
        done <<<"$others"
        while read -r pid cwd; do
            [ -n "$pid" ] || continue
            cwd=${cwd% (deleted)}
            [[ "$cwd" == "$root_p" || "$cwd" == "$root_p/"* ]] || continue
            nested=0
            while read -r o; do
                [ -n "$o" ] && [[ "$cwd" == "$o" || "$cwd" == "$o/"* ]] && nested=1 && break
            done <<<"$others_p"
            [ $nested = 1 ] && continue
            [[ "$self" == *" $pid "* ]] && continue
            comm=$(proc_comm_darwin "$pid") || continue
            case "$comm" in bash | zsh | sh | fish | claude | codex | tmux*) continue ;; esac
            echo "$pid"
        done <<<"$cwds"
        return 0
    fi
    for p in /proc/[0-9]*; do
        cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
        cwd=${cwd% (deleted)}
        [[ "$cwd" == "$ROOT" || "$cwd" == "$ROOT/"* ]] || continue
        nested=0
        while read -r o; do
            [ -n "$o" ] && [[ "$cwd" == "$o" || "$cwd" == "$o/"* ]] && nested=1 && break
        done <<<"$others"
        [ $nested = 1 ] && continue
        [[ "$self" == *" ${p#/proc/} "* ]] && continue
        comm=$(cat "$p/comm" 2>/dev/null) || continue
        case "$comm" in bash | zsh | sh | fish | claude | codex | tmux*) continue ;; esac
        echo "${p#/proc/}"
    done
    return 0
}

# Slot ports something listens on.
listening_ports() {
    local entry port open
    if [ "$WT_OS" = Darwin ]; then
        # lsof exits 1 when nothing listens. It only sees sockets of processes we may inspect.
        open=" $({ lsof -nP -iTCP -sTCP:LISTEN -Fn 2>/dev/null || true; } | awk '/^n/ {n = split($0, a, ":"); print a[n]}' | tr '\n' ' ') "
    else
        open=" $(ss -Hltn 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' | tr '\n' ' ') "
    fi
    for entry in ${WT_PORTS[@]+"${WT_PORTS[@]}"}; do
        port=${entry#*=}
        [[ "$open" == *" $port "* ]] && echo "${entry%%=*}:$port"
    done
    return 0
}

stop_servers() {
    local pids
    pids="$(worktree_pids | tr '\n' ' ')"
    if [ -n "${pids// /}" ]; then
        log "stopping $(wc -w <<<"$pids" | tr -d ' ') process(es) in $ROOT"
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
        local i
        for ((i = 1; i <= 10; i++)); do
            if [ "$WT_OS" = Darwin ]; then
                pids="$(for p in $pids; do if kill -0 "$p" 2>/dev/null; then echo "$p"; fi; done | tr '\n' ' ')"
            else
                pids="$(for p in $pids; do if [ -d "/proc/$p" ]; then echo "$p"; fi; done | tr '\n' ' ')"
            fi
            [ -z "${pids// /}" ] && break
            sleep 0.5
        done
        # shellcheck disable=SC2086
        [ -n "${pids// /}" ] && kill -KILL $pids 2>/dev/null || true
    fi
    if has_state && declare -F wt_stop_extra >/dev/null; then wt_stop_extra; fi
    local left
    left="$(listening_ports | tr '\n' ' ')"
    [ -n "$left" ] && warn "still listening (started outside this worktree?): $left"
    return 0
}

# --- git safety -----------------------------------------------------------------------------------

git_report() {
    local dirty ahead branch
    dirty=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    branch=$(git -C "$ROOT" branch --show-current)
    ahead=$(git -C "$ROOT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    [ "$dirty" -gt 0 ] && warn "$dirty uncommitted change(s) in $ROOT (kept — teardown never touches code)"
    if [ "$ahead" = "?" ]; then
        [ -n "$branch" ] && warn "branch $branch has no upstream (never pushed?)"
    elif [ "$ahead" -gt 0 ]; then
        warn "branch $branch has $ahead unpushed commit(s)"
    fi
    return 0
}

# --- commands ------------------------------------------------------------------------------------

cmd_setup() {
    local install=1 build=1 db=1 arg
    for arg in "$@"; do
        case "$arg" in
            --no-install) install=0 ;;
            --no-build) build=0 ;;
            --no-db) db=0 ;;
            *) die "unknown option $arg" ;;
        esac
    done
    export WT_SETUP_INSTALL=$install WT_SETUP_BUILD=$build WT_SETUP_DB=$db
    is_main || allocate_slot
    load_state
    if ! is_main && declare -F wt_config >/dev/null; then wt_config; fi
    if [ $install = 1 ]; then
        if declare -F wt_install >/dev/null; then wt_install; else (cd "$ROOT" && pnpm install --frozen-lockfile --prefer-offline); fi
    fi
    if [ $build = 1 ] && declare -F wt_build >/dev/null; then wt_build; fi
    if [ $db = 1 ] && ! is_main; then
        ensure_services
        if db_exists "$DB"; then log "database $DB exists, kept ($WT_SCRIPT db reset to re-clone)"; else db_clone; fi
        prune
    fi
    if declare -F wt_setup_extra >/dev/null; then wt_setup_extra; fi
    cmd_info
    if [ $db = 1 ]; then report_migrations; fi
}

cmd_info() {
    load_state
    echo "worktree  $ROOT"
    echo "slot      $SLOT"
    echo "database  $DB"
    local entry
    local scheme
    for entry in ${WT_PORTS[@]+"${WT_PORTS[@]}"}; do
        scheme=http
        [[ " ${WT_HTTPS_PORTS[*]:-} " == *" ${entry%%=*} "* ]] && scheme=https
        printf '%-9s %s\n' "${entry%%=*}" "$scheme://127.0.0.1:${entry#*=}"
    done
    if declare -F wt_info >/dev/null; then wt_info; fi
    local lan
    lan="$(lan_ips | head -n1)"
    [ -n "$lan" ] && echo "LAN       same ports on $lan"
    local running
    running="$(listening_ports | tr '\n' ' ')"
    echo "running   ${running:-nothing}"
    return 0
}

report_migrations() {
    declare -F wt_pending_migrations >/dev/null || return 0
    pg_ready || { log "migrations: postgres is down, not checked"; return 0; }
    local pending
    pending="$(wt_pending_migrations)"
    if [ -z "$pending" ]; then
        log "migrations: $DB is up to date"
    else
        log "migrations not yet run on $DB${WT_MIGRATE_HINT:+ (run them: $WT_MIGRATE_HINT)}:"
        printf '    %s\n' $pending >&2
    fi
}

cmd_list() {
    local path slot id db running base
    printf '%-5s %-44s %-7s %-22s %s\n' slot database base running worktree
    while read -r path; do
        if [ "$path" = "$MAIN_ROOT" ]; then
            slot=0 db=$WT_MAIN_DB
        else
            read -r slot id db <<<"$(state_identity "$path")"
            [ -z "$slot" ] && slot=- db=-
        fi
        running=$(cd "$path" && "$WT_SELF" describe 2>/dev/null | sed -n 's/^listening=//p')
        base=$(cd "$path" && "$WT_SELF" describe 2>/dev/null | sed -n 's/^ports=[^=]*=\([0-9]*\).*/\1/p')
        printf '%-5s %-44s %-7s %-22s %s\n' "$slot" "$db" "${base:--}" "${running:--}" "$path"
    done < <(wt_worktree_paths)
}

# Machine-readable identity, used by the cross-project `wt` tool.
cmd_describe() {
    echo "lib_version=$WT_LIB_VERSION"
    echo "project=$WT_PROJECT"
    echo "root=$ROOT"
    echo "main_root=$MAIN_ROOT"
    echo "is_main=$(is_main && echo 1 || echo 0)"
    if has_state; then
        load_state
        echo "slot=$SLOT"
        echo "id=$ID"
        echo "db=$DB"
        echo "ports=${WT_PORTS[*]:-}"
        echo "listening=$(listening_ports | tr '\n' ' ' | sed 's/ $//')"
    else
        echo "slot="
    fi
    if declare -F wt_describe_extra >/dev/null; then wt_describe_extra; fi
    return 0
}

cmd_stop() {
    has_state && load_state || WT_PORTS=()
    stop_servers
    log "stopped (data kept; start again with the server scripts)"
}

cmd_teardown() {
    local force_stop=0 arg
    for arg in "$@"; do
        case "$arg" in
            --stop) force_stop=1 ;;
            *) die "unknown option $arg" ;;
        esac
    done
    if is_main; then log "main checkout: nothing to tear down"; return 0; fi
    if [ ! -f "$STATE_FILE" ]; then
        log "no slot: nothing to tear down"
        return 0
    fi
    load_state
    local pids ports
    pids="$(worktree_pids | tr '\n' ' ')"
    ports="$(listening_ports | tr '\n' ' ')"
    if [ -n "${pids// /}${ports// /}" ]; then
        if [ $force_stop = 0 ]; then
            [ -n "${pids// /}" ] && { ps -o pid=,etime=,args= -p "$(tr -s ' ' ',' <<<"${pids% }")" | cut -c1-140 >&2 || true; }
            [ -n "$ports" ] && warn "listening: $ports"
            die "dev servers of slot $SLOT still run — stop them first ($WT_SCRIPT stop) or run: $WT_SCRIPT teardown --stop"
        fi
        stop_servers
    fi
    git_report
    with_pg_begin
    db_drop
    with_pg_end
    if declare -F wt_teardown_extra >/dev/null; then wt_teardown_extra; fi
    local file
    for file in ${WT_GENERATED_FILES[@]+"${WT_GENERATED_FILES[@]}"}; do rm -f "${ROOT:?}/$file"; done
    rm -rf "${STATE_DIR:?}"
    log "slot $SLOT released"
}

cmd_db() {
    local sub=${1:-}
    shift || true
    load_state
    case "$sub" in
        reset)
            [ "${1:-}" = --fresh ] && db_snapshot
            db_clone
            ;;
        snapshot) db_snapshot ;;
        psql)
            ensure_services
            local tty=-i
            [ -t 0 ] && tty=-it
            docker exec $tty "$WT_PG_CONTAINER" psql -U "$WT_PG_USER" -d "$DB" "$@"
            ;;
        drop) ensure_services && db_drop ;;
        gc) prune "$@" ;;
        *) die "usage: $WT_SCRIPT db reset [--fresh] | snapshot | psql [args] | drop | gc" ;;
    esac
    if declare -F wt_db_extra >/dev/null; then wt_db_extra "$sub" "$@"; fi
}

wt_usage() {
    sed -n '2,/^[^#]/p' "$0" | sed -n 's/^# \{0,1\}//p'
    cat >&2 <<EOF
Shared commands (wt-lib.sh v$WT_LIB_VERSION): setup info list describe stop settle teardown prune
  migrations services config db; cross-project overview: wt status
EOF
}

# Package that provides a tool, for the "missing tools" hint.
wt_tool_hint() {
    if [ "$WT_OS" = Darwin ]; then
        case "$1" in
            docker) echo "Docker Desktop, OrbStack or colima" ;;
            git) echo "xcode-select --install, or brew install git" ;;
            lsof | shasum | perl | ifconfig | ps | readlink) echo "part of macOS: check PATH" ;;
            *) echo "brew install $1" ;;
        esac
    else
        case "$1" in
            flock) echo "util-linux" ;;
            ss | ip) echo "iproute2" ;;
            ps) echo "procps / procps-ng" ;;
            awk) echo "gawk or mawk" ;;
            docker) echo "docker.io / docker" ;;
            sha1sum | readlink | cut | tr | head | wc | sleep | basename | dirname) echo "coreutils" ;;
            *) echo "$1" ;;
        esac
    fi
}

# Tools a command needs, checked with `command -v` only (no subprocesses): one error naming every
# missing required tool, one warning for missing optional ones. help needs nothing; describe/info/list
# only read state and ports, so they run without docker.
wt_preflight() {
    local cmd=$1 need opt tool missing="" absent=""
    case "$cmd" in "" | help | -h | --help) return 0 ;; esac
    need="git awk sed grep ps cut tr head wc sleep basename dirname"
    case "$cmd" in describe | info | list) ;; *) need="$need docker" ;; esac
    if [ "$WT_OS" = Darwin ]; then
        need="$need lsof shasum perl readlink"
        opt="ifconfig"
    else
        need="$need flock ss sha1sum readlink"
        opt="ip"
    fi
    for tool in $need; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing, $tool ($(wt_tool_hint "$tool"))"
    done
    for tool in $opt; do
        command -v "$tool" >/dev/null 2>&1 || absent="$absent $tool"
    done
    [ -n "$absent" ] && warn "optional tool missing:$absent (LAN IPs are left out of CORS origins)"
    [ -z "$missing" ] || die "missing required tools on $WT_OS: ${missing#, } — install them (package in parentheses) and retry"
    return 0
}

wt_main() {
    wt_preflight "${1:-}"
    wt_defaults
    local cmd=${1:-}
    shift || true
    case "$cmd" in
        setup) cmd_setup "$@" ;;
        info) cmd_info && report_migrations ;;
        list) cmd_list ;;
        describe) cmd_describe ;;
        stop) cmd_stop ;;
        settle)
            # Runs from T3 Code when the thread settles: free RAM, keep everything else.
            is_main && { log "main checkout: settle does nothing"; return 0; }
            cmd_stop
            ;;
        teardown) cmd_teardown "$@" ;;
        prune) prune "$@" ;;
        migrations) load_state && ensure_services && { declare -F wt_pending_migrations >/dev/null && wt_pending_migrations || true; } ;;
        services) load_state && ensure_services ;;
        config)
            is_main && die "the main checkout owns its env files"
            load_state
            declare -F wt_config >/dev/null && wt_config
            ;;
        db) cmd_db "$@" ;;
        "" | help | -h | --help) wt_usage ;;
        *)
            local fn="wt_cmd_${cmd//-/_}"
            declare -F "$fn" >/dev/null || { wt_usage; exit 1; }
            "$fn" "$@"
            ;;
    esac
}
