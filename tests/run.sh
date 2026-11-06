#!/usr/bin/env bash
# End-to-end tests for wt/wt-lib.sh, examples/wt.sh and wt/wt.
#
#   tests/run.sh
#
# Builds a throwaway git repo with worktrees in a temp dir and a throwaway Postgres, runs the
# engine's commands against them and checks the results. Everything it creates is removed on exit.
#
# Environment:
#   WT_TEST_PG=docker|local   Postgres source (default: docker when it answers, else local).
#                             docker: container wt-test-postgres (postgres:16-alpine), removed after.
#                             local: initdb/pg_ctl from PATH, plus a docker shim first on PATH.
#   WT_TEST_BASH=<path>       bash binary to run every script with (e.g. /bin/bash 3.2 on macOS).
#   WT_TEST_PORT_BASE=23000   slot N uses base + 100·N (+0 backend, +1 frontend); multiple of 100.
#   WT_TEST_FORCE_OS=Darwin   run the macOS code paths of wt-lib.sh and wt (on Linux, for coverage).
#   WT_TEST_KEEP=1            keep the temp dir and Postgres for debugging.
#
# Never touches other containers or databases: the only container it uses is wt-test-postgres, the
# only databases are wttest_* inside it.
# shellcheck disable=SC2016,SC2329 # checks are single-quoted strings run by eval; helpers are called from them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SRC="$(dirname "$HERE")"
PG_CONTAINER=wt-test-postgres
PG_IMAGE=${WT_TEST_PG_IMAGE:-postgres:16-alpine}
PORT_BASE=${WT_TEST_PORT_BASE:-23000}
[ $((PORT_BASE % 100)) = 0 ] || { echo "WT_TEST_PORT_BASE must be a multiple of 100" >&2; exit 2; }

# Isolation from the user's git config (signing, hooks, templates) and identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=wt-test GIT_AUTHOR_EMAIL=wt-test@example.invalid
export GIT_COMMITTER_NAME=wt-test GIT_COMMITTER_EMAIL=wt-test@example.invalid
unset SLOT ID DB WT_SLOT WT_ID
# Lets wt-lib.sh and wt honour WT_TEST_FORCE_OS (ignored outside tests).
export WT_TEST_RUN=1

# Everything runs below a symlink (as on macOS, where /var and /tmp point into /private): git and
# lsof report physical paths ($TMP_P/…), the commands are started from the symlinked ones ($TMP/…).
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/wt-test.XXXXXX")"
mkdir "$TMP_BASE/real"
ln -s real "$TMP_BASE/link"
TMP="$TMP_BASE/link"
TMP_P="$(cd "$TMP_BASE" && pwd -P)/real"
OUT="$TMP/out"
BG_PIDS=""
PG_MODE=""
SOCK_DIR=""

PASS=0 FAIL=0 FAILED=""

cleanup() {
    local p
    for p in $BG_PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    if [ "${WT_TEST_KEEP:-0}" = 1 ]; then
        echo "kept: $TMP_BASE (postgres: $PG_MODE)"
        return
    fi
    case "$PG_MODE" in
        docker) docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true ;;
        local) pg_ctl -D "$TMP/pgdata" -m immediate stop >/dev/null 2>&1 || true ;;
    esac
    rm -rf "$TMP_BASE"
    [ -n "$SOCK_DIR" ] && rm -rf "$SOCK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- helpers ----------------------------------------------------------------------------------------

ok() {
    PASS=$((PASS + 1))
    printf 'ok    %s\n' "$1"
}
fail() {
    FAIL=$((FAIL + 1))
    FAILED="$FAILED  $1
"
    printf 'FAIL  %s\n' "$1"
    if [ -s "$OUT" ]; then tail -n 25 "$OUT" | sed 's/^/      | /'; fi
}
# check <description> <command…>: pass when the command succeeds.
check() {
    local desc=$1
    shift
    if "$@"; then ok "$desc"; else fail "$desc"; fi
}
has() { grep -qF -- "$1" "$OUT"; }        # output of the last wt call contains a string
lacks() { ! grep -qF -- "$1" "$OUT"; }
file_has() { grep -qxF -- "$2" "$1" 2>/dev/null; } # file has this exact line
rc_is() { [ "$RC" = "$1" ]; }

# wt_in <dir> <args…>: run the worktree's wt.sh there; output in $OUT, exit code in $RC.
wt_in() {
    local dir=$1
    shift
    (cd "$dir" && ./scripts/worktree/wt.sh "$@") >"$OUT" 2>&1
    RC=$?
}

pgq() { docker exec -i "$PG_CONTAINER" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qAt -c "$2"; }
db_present() { [ "$(pgq postgres "SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]; }
db_absent() { ! db_present "$1"; }

port_open() {
    python3 -c 'import socket, sys
s = socket.socket(); s.settimeout(0.5)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1"
}
port_closed() { ! port_open "$1"; }
alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! alive "$1"; }

# detach <dir> <cmd…>: start cmd with cwd <dir> in its own session (not a child or pipeline sibling
# of anything wt.sh runs); prints its pid.
detach() {
    local dir=$1 pidf="$TMP/detach.$$.$RANDOM"
    shift
    (
        cd "$dir" || exit 1
        python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" </dev/null >/dev/null 2>&1 &
        echo $! >"$pidf"
    )
    cat "$pidf"
    rm -f "$pidf"
}

# start_server <dir> <port>: fake dev server; sets SERVER_PID once it listens.
start_server() {
    SERVER_PID=$(detach "$1" python3 -m http.server "$2" --bind 127.0.0.1)
    BG_PIDS="$BG_PIDS $SERVER_PID"
    for ((n = 0; n < 100; n++)); do
        port_open "$2" && return 0
        sleep 0.1
    done
    echo "fake server on port $2 did not start" >&2
    return 1
}

wait_dead() { # wait_dead <pid>: up to 5s
    for ((n = 0; n < 50; n++)); do
        dead "$1" && return 0
        sleep 0.1
    done
    return 1
}

state_val() { sed -n "s/^$2=//p" "$1/.worktree/env" 2>/dev/null; }

# --- environment ------------------------------------------------------------------------------------

if [ -n "${WT_TEST_BASH:-}" ]; then
    mkdir -p "$TMP/bin"
    ln -s "$WT_TEST_BASH" "$TMP/bin/bash"
    export PATH="$TMP/bin:$PATH"
fi

PG_MODE=${WT_TEST_PG:-}
if [ -z "$PG_MODE" ]; then
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then PG_MODE=docker; else PG_MODE=local; fi
fi

start_pg_docker() {
    docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$PG_CONTAINER" -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1::5432 \
        "$PG_IMAGE" >/dev/null || return 1
    # Ready over TCP: the image's init server (socket only) is not the final one.
    for ((n = 0; n < 120; n++)); do
        docker exec "$PG_CONTAINER" pg_isready -h 127.0.0.1 -U postgres -q >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    return 1
}

start_pg_local() {
    command -v initdb >/dev/null && command -v pg_ctl >/dev/null || {
        echo "local mode needs initdb and pg_ctl on PATH" >&2
        return 1
    }
    # Unix socket paths are limited to ~100 bytes; macOS's TMPDIR is long.
    SOCK_DIR="$(mktemp -d /tmp/wtpg.XXXXXX)"
    initdb -U postgres -A trust -D "$TMP/pgdata" >"$TMP/initdb.log" 2>&1 || { cat "$TMP/initdb.log" >&2; return 1; }
    pg_ctl -D "$TMP/pgdata" -l "$TMP/pg.log" -w \
        -o "-k $SOCK_DIR -c listen_addresses='' -p 5432" start >/dev/null || { cat "$TMP/pg.log" >&2; return 1; }
    export PGHOST="$SOCK_DIR" PGPORT=5432
    mkdir -p "$TMP/shim"
    cp "$HERE/docker-shim/docker" "$TMP/shim/docker"
    chmod +x "$TMP/shim/docker"
    export PATH="$TMP/shim:$PATH" WT_TEST_SHIM=1
}

case "$PG_MODE" in
    docker) start_pg_docker || { echo "could not start $PG_CONTAINER" >&2; exit 1; } ;;
    local) start_pg_local || { echo "could not start a local postgres" >&2; exit 1; } ;;
    *) echo "WT_TEST_PG must be docker or local" >&2; exit 2 ;;
esac

echo "# wt tests: $(uname -s)${WT_TEST_FORCE_OS:+ (forced $WT_TEST_FORCE_OS paths)}, bash $(bash -c 'echo $BASH_VERSION'), postgres: $PG_MODE, ports $((PORT_BASE + 100))+"

# --- fixture repo -----------------------------------------------------------------------------------

REPO="$TMP/repo" WT1="$TMP/wt1" WT2="$TMP/wt2" WT3="$TMP/wt3" WT4="$TMP/wt4"
REPO_P="$TMP_P/repo" WT1_P="$TMP_P/wt1" WT3_P="$TMP_P/wt3"
export WT_TEST_DIR="$TMP/fixture"
mkdir -p "$WT_TEST_DIR" "$REPO/scripts/worktree" "$REPO/apps/backend/src/migrations" "$REPO/apps/frontend"

# Overrides of examples/wt.sh, sourced by the test copy of it (see the awk below).
cat >"$WT_TEST_DIR/config.sh" <<'EOF'
WT_PROJECT=wttest
WT_MAIN_DB=wttest_main
WT_DB_PREFIX=wttest_wt_
WT_PG_CONTAINER=wt-test-postgres
WT_PG_USER=postgres
WT_MIGRATE_HINT="run them"
EOF
cat >"$WT_TEST_DIR/hooks.sh" <<EOF
wt_ports() {
    BASE=\$(($PORT_BASE + SLOT * 100))
    BACKEND_PORT=\$BASE FRONTEND_PORT=\$((BASE + 1))
    WT_PORTS=("backend=\$BACKEND_PORT" "frontend=\$FRONTEND_PORT")
}
wt_services() { docker start "\$WT_PG_CONTAINER" >/dev/null; }
wt_install() { :; }
wt_build() { :; }
EOF

cp "$SRC/wt/wt-lib.sh" "$REPO/scripts/worktree/wt-lib.sh"
awk '
    /^# shellcheck source=wt-lib.sh/ { print ". \"$WT_TEST_DIR/config.sh\"" }
    /^wt_main "\$@"$/ { print ". \"$WT_TEST_DIR/hooks.sh\"" }
    { print }
' "$SRC/examples/wt.sh" >"$REPO/scripts/worktree/wt.sh"
chmod +x "$REPO/scripts/worktree/wt.sh"
grep -q 'hooks.sh' "$REPO/scripts/worktree/wt.sh" && grep -q 'config.sh' "$REPO/scripts/worktree/wt.sh" ||
    { echo "examples/wt.sh changed shape: test overrides not injected" >&2; exit 1; }

printf '.worktree/\napps/backend/.env*\napps/frontend/.env*\n' >"$REPO/.gitignore"
echo "export const up = 1;" >"$REPO/apps/backend/src/migrations/0001_init.ts"
# Gitignored env files of the main checkout, copied and patched by wt_config.
printf 'PORT=13000\nDATABASE_NAME=wttest_main\n' >"$REPO/apps/backend/.env.development"
printf 'PUBLIC_API_URL="http://localhost:13000/api"\n' >"$REPO/apps/frontend/.env"
(
    cd "$REPO" && git init -q -b main && git add -A && git commit -qm init &&
        git worktree add -q "$WT1" -b wt1 && git worktree add -q "$WT2" -b wt2
) || { echo "fixture repo failed" >&2; exit 1; }

pgq postgres "CREATE DATABASE wttest_main" >/dev/null &&
    pgq wttest_main "CREATE TABLE migrations (name text); INSERT INTO migrations VALUES ('0001_init');
        CREATE TABLE items (name text); INSERT INTO items VALUES ('hello');" >/dev/null ||
    { echo "could not create wttest_main" >&2; exit 1; }

# --- new_id: same ids as the original Linux implementation --------------------------------------------

ref_id_sh() { # the pre-port implementation, verbatim (GNU tr/cut and sha1sum: Linux only)
    local name hash
    name="$(basename "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '_' | cut -c1-32)"
    hash="$(printf '%s' "$1" | sha1sum | cut -c1-6)"
    echo "${name}_$hash"
}
ref_id_py() { # the same, byte by byte in python (checked against ref_id_sh on Linux)
    python3 -c 'import hashlib, os, sys
p = os.fsencode(sys.argv[1])
name = bytes(c + 32 if 65 <= c <= 90 else c for c in os.path.basename(p))
name = bytes(c if 97 <= c <= 122 or 48 <= c <= 57 or c == 10 else 95 for c in name)[:32]
print(name.decode() + "_" + hashlib.sha1(p).hexdigest()[:6])' "$1"
}
ref_id() { if [ "$(uname -s)" = Linux ]; then ref_id_sh "$1"; else ref_id_py "$1"; fi; }
lib_id() { # new_id from wt-lib.sh for ROOT=<path> (os: Linux, Darwin or the host's)
    (cd "$REPO" && WT_TEST_FORCE_OS=${2:-${WT_TEST_FORCE_OS:-}} bash -c '. scripts/worktree/wt-lib.sh; ROOT=$1; new_id' _ "$1")
}
id_ok=1
for p in /home/u/dev/worktrees/t3-1a2b3c4d "/tmp/My Repo.Name" /x/a-very-long-directory-name-well-over-thirty-two-chars \
    "/tmp/Ünïcödé Dir ÄÖ" "/tmp/ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ" "$WT1_P"; do
    want=$(ref_id "$p")
    if [ "$(uname -s)" = Linux ] && [ "$(ref_id_py "$p")" != "$want" ]; then
        id_ok=0
        echo "ref_id_py($p) = $(ref_id_py "$p"), want $want" >"$OUT"
    fi
    for os in "" Darwin; do
        [ "$os" = Darwin ] && ! command -v shasum >/dev/null && continue
        got=$(lib_id "$p" "$os")
        [ "$got" = "$want" ] || { id_ok=0; echo "new_id($p, ${os:-native}) = $got, want $want" >"$OUT"; }
    done
done
check "new_id matches the original sha1sum implementation" [ $id_ok = 1 ]

# WT_TEST_FORCE_OS alone (a stray export outside the tests) must not switch the code paths.
os_lib=$(cd "$REPO" && env -u WT_TEST_RUN WT_TEST_FORCE_OS=Bogus bash -c '. scripts/worktree/wt-lib.sh; echo "$WT_OS"' 2>&1)
os_py=$(env -u WT_TEST_RUN WT_TEST_FORCE_OS=Bogus python3 -c 'import importlib.machinery as m, importlib.util as u, sys
spec = u.spec_from_loader("wt", m.SourceFileLoader("wt", sys.argv[1]))
mod = u.module_from_spec(spec); spec.loader.exec_module(mod); print(mod.OS)' "$SRC/wt/wt" 2>&1)
echo "lib: $os_lib, wt: $os_py" >"$OUT"
check "WT_TEST_FORCE_OS is ignored outside tests" eval '[ "$os_lib" = "$(uname -s)" ] && [ "$os_py" = "$(uname -s)" ]'

# --- setup ------------------------------------------------------------------------------------------

wt_in "$WT1" setup --no-install --no-build
check "setup wt1 exits 0" rc_is 0
DB1=$(state_val "$WT1" DB)
check "wt1 gets slot 1" [ "$(state_val "$WT1" SLOT)" = 1 ]
check "state file: id and db" eval '[ "$DB1" = "wttest_wt_$(ref_id "$WT1_P")" ] && [ "$(state_val "$WT1" ID)" = "$(ref_id "$WT1_P")" ]'
check "env copied from main" file_has "$WT1/apps/backend/.env.development" "PORT=13000"
B="$WT1/apps/backend/.env" F="$WT1/apps/frontend/.env.development.local"
check "backend env: shifted port" file_has "$B" "PORT=$((PORT_BASE + 100))"
check "backend env: own database" file_has "$B" "DATABASE_NAME=$DB1"
check "backend env: own cookie, schedulers off" eval 'file_has "$B" SESSION_COOKIE_NAME=sid-wt1 && file_has "$B" DISABLE_SCHEDULERS=true'
check "backend env: CORS for the slot frontend" grep -qF "http://127.0.0.1:$((PORT_BASE + 101))" "$B"
check "frontend env: API URL moved to the slot" file_has "$F" "PUBLIC_API_URL=http://localhost:$((PORT_BASE + 100))/api"
check "frontend env: dev server port" file_has "$F" "DEV_SERVER_PORT=$((PORT_BASE + 101))"
check "worktree DB cloned from main" [ "$(pgq "$DB1" "SELECT name FROM items")" = hello ]
check "template DB exists" db_present wttest_wt_template

pgq "$DB1" "INSERT INTO items VALUES ('marker')" >/dev/null
wt_in "$WT1" setup --no-install --no-build
check "second setup exits 0, keeps the DB" eval 'rc_is 0 && has "exists, kept"'
check "second setup keeps data and slot" eval '[ "$(pgq "$DB1" "SELECT count(*) FROM items")" = 2 ] && [ "$(state_val "$WT1" SLOT)" = 1 ]'

wt_in "$WT2" setup --no-install --no-build
# shellcheck disable=SC2034 # DB2/DB3 are read inside eval'd checks
DB2=$(state_val "$WT2" DB)
check "wt2 gets slot 2" eval 'rc_is 0 && [ "$(state_val "$WT2" SLOT)" = 2 ] && db_present "$DB2"'
check "wt2 backend port" file_has "$WT2/apps/backend/.env" "PORT=$((PORT_BASE + 200))"

# --- info / list / describe / migrations ---------------------------------------------------------------

wt_in "$WT1" info
check "info" eval 'rc_is 0 && has "slot      1" && has "database  $DB1" && has "backend   http://127.0.0.1:$((PORT_BASE + 100))" && has "running   nothing"'
check "info: migrations up to date" has "is up to date"

wt_in "$REPO" list
check "list shows main, slot 1 and 2" eval 'rc_is 0 && grep -q "^0 .*wttest_main" "$OUT" && grep -q "^1 .*$DB1" "$OUT" && grep -q "^2 .*$DB2" "$OUT"'

wt_in "$WT1" describe
check "describe" eval 'rc_is 0 && has "lib_version=2" && has "project=wttest" && has "slot=1" && has "db=$DB1" && has "is_main=0" &&
    has "ports=backend=$((PORT_BASE + 100)) frontend=$((PORT_BASE + 101))" && has "main_root=$REPO_P" && lacks "missing" && lacks "optional tool"'
wt_in "$REPO" describe
check "describe in main" eval 'rc_is 0 && has "is_main=1" && has "slot=0" && has "db=wttest_main"'

# --- preflight: missing tools ----------------------------------------------------------------------------

# fake_path <tool…>: a PATH of symlinks to every tool the scripts use, minus the given ones.
fake_path() {
    local dir="$TMP/fakebin.$1" t src
    rm -rf "$dir" && mkdir -p "$dir"
    for t in bash env git uname readlink dirname basename awk sed grep ps cut tr head tail wc sleep cat \
        docker flock ss ip sha1sum shasum lsof perl ifconfig python3 sort mkdir rm cp mv touch ln; do
        case " $* " in *" $t "*) continue ;; esac
        src=$(command -v "$t" 2>/dev/null) && [ -n "$src" ] && [ "${src#/}" != "$src" ] && ln -s "$src" "$dir/$t"
    done
    echo "$dir"
}
if [ "$(uname -s)" = Darwin ] || [ "${WT_TEST_FORCE_OS:-}" = Darwin ]; then HIDE="lsof perl"; else HIDE="flock ss"; fi
FP=$(fake_path $HIDE)
(cd "$WT1" && PATH="$FP" ./scripts/worktree/wt.sh stop) >"$OUT" 2>&1
RC=$?
check "preflight: one error naming every missing tool" eval 'rc_is 1 && has "missing required tools" && has "${HIDE% *} (" && has "${HIDE#* } (" && [ "$(grep -c "missing required" "$OUT")" = 1 ] && lacks "git ("'
FP=$(fake_path docker)
(cd "$WT1" && PATH="$FP" ./scripts/worktree/wt.sh describe) >"$OUT" 2>&1
RC=$?
check "preflight: describe runs without docker" eval 'rc_is 0 && has "slot=1"'
(cd "$WT1" && PATH="$FP" ./scripts/worktree/wt.sh stop) >"$OUT" 2>&1
RC=$?
check "preflight: stop needs docker" eval 'rc_is 1 && has "docker ("'
if [ "$(uname -s)" = Darwin ] || [ "${WT_TEST_FORCE_OS:-}" = Darwin ]; then HIDE=ifconfig; else HIDE=ip; fi
FP=$(fake_path $HIDE)
(cd "$WT1" && PATH="$FP" ./scripts/worktree/wt.sh describe) >"$OUT" 2>&1
RC=$?
check "preflight: missing optional tool only warns" eval 'rc_is 0 && has "optional tool missing: $HIDE" && has "slot=1"'
if [ "$(uname -s)" = Darwin ] || [ "${WT_TEST_FORCE_OS:-}" = Darwin ]; then HIDE=lsof; else HIDE=ss; fi
FP=$(fake_path $HIDE)
HOME="$TMP/home" PATH="$FP" python3 "$SRC/wt/wt" status >"$OUT" 2>&1
RC=$?
check "wt preflight: names the missing tool" eval 'rc_is 1 && has "missing required tools" && has "$HIDE ("'
HOME="$TMP/home" PATH="$FP" python3 "$SRC/wt/wt" --help >"$OUT" 2>&1
RC=$?
check "wt --help needs no tools" rc_is 0

wt_in "$WT1" migrations
check "migrations: none pending" eval 'rc_is 0 && lacks 0001_init'
echo "export const up = 2;" >"$WT1/apps/backend/src/migrations/0002_more.ts"
wt_in "$WT1" migrations
check "migrations: new file pending" eval 'rc_is 0 && has 0002_more && lacks 0001_init'
wt_in "$WT1" info
check "info reports the pending migration" eval 'has "migrations not yet run" && has 0002_more'
rm -f "$WT1/apps/backend/src/migrations/0002_more.ts"

# --- db reset ---------------------------------------------------------------------------------------

wt_in "$WT1" db reset
check "db reset re-clones (marker gone)" eval 'rc_is 0 && [ "$(pgq "$DB1" "SELECT count(*) FROM items")" = 1 ]'

# --- stop / teardown with a running server -------------------------------------------------------------

P1=$((PORT_BASE + 100))
start_server "$WT1" "$P1" || fail "fake server started"
OUTSIDE1=$(detach "$TMP" sleep 300)
OUTSIDE2=$(detach "$REPO" sleep 300)
BG_PIDS="$BG_PIDS $OUTSIDE1 $OUTSIDE2"

wt_in "$WT1" info
check "info shows the server" has "running   backend:$P1"
wt_in "$WT1" teardown
check "teardown refuses while a server runs" eval '! rc_is 0 && has "still run" && db_present "$DB1" && alive "$SERVER_PID"'

# Run stop from inside the worktree through a pipe: the `cat` is a pipeline sibling with its cwd
# inside the worktree and must survive, as must this runner and processes outside the worktree.
(cd "$WT1" && ./scripts/worktree/wt.sh stop 2>&1 | cat >"$OUT.pipe"; exit "${PIPESTATUS[0]}") >/dev/null 2>&1
RC=$?
cp "$OUT.pipe" "$OUT"
check "stop exits 0, pipe output intact" eval 'rc_is 0 && has "stopped (data kept"'
check "stop kills the server, port is free" eval 'wait_dead "$SERVER_PID" && port_closed "$P1"'
check "stop spares processes outside the worktree" eval 'alive "$OUTSIDE1" && alive "$OUTSIDE2"'
check "stop keeps the DB and slot" eval 'db_present "$DB1" && [ "$(state_val "$WT1" SLOT)" = 1 ]'

start_server "$WT1" "$P1" || fail "fake server restarted"
wt_in "$WT1" teardown --stop
check "teardown --stop exits 0" rc_is 0
check "teardown --stop: server stopped" eval 'wait_dead "$SERVER_PID" && port_closed "$P1"'
check "teardown --stop: DB dropped, state and generated files gone" eval 'db_absent "$DB1" && [ ! -e "$WT1/.worktree" ] && [ ! -e "$WT1/apps/backend/.env" ]'
check "teardown spares processes outside the worktree" eval 'alive "$OUTSIDE1" && alive "$OUTSIDE2"'
wt_in "$WT1" teardown
check "teardown without slot exits 0" eval 'rc_is 0 && has "no slot"'
wt_in "$WT1" stop
check "stop without slot exits 0" rc_is 0

# --- slot reuse and prune -------------------------------------------------------------------------------

(cd "$REPO" && git worktree add -q "$WT3" -b wt3 && git worktree add -q "$WT4" -b wt4)
# Two setups at once: the slot lock must hand out the free slot 1 and the next one, 3, once each.
(cd "$WT3" && ./scripts/worktree/wt.sh setup --no-install --no-build >"$OUT.3" 2>&1) &
job3=$!
(cd "$WT4" && ./scripts/worktree/wt.sh setup --no-install --no-build >"$OUT.4" 2>&1) &
job4=$!
wait $job3
RC=$?
wait $job4
RC=$((RC + $?))
cat "$OUT.3" "$OUT.4" >"$OUT"
# shellcheck disable=SC2034
DB3=$(state_val "$WT3" DB) DB4=$(state_val "$WT4" DB)
check "parallel setups exit 0" rc_is 0
check "parallel setups get slots 1 and 3" eval '[ "$(printf "%s\n" "$(state_val "$WT3" SLOT)" "$(state_val "$WT4" SLOT)" | sort | tr "\n" " ")" = "1 3 " ]'
check "parallel setups get their DBs" eval 'db_present "$DB3" && db_present "$DB4"'
wt_in "$WT4" teardown
check "teardown wt4" eval 'rc_is 0 && db_absent "$DB4"'

rm -rf "$WT2"
wt_in "$REPO" prune --dry-run
check "prune --dry-run lists only the orphan" eval 'rc_is 0 && has "would drop orphaned $DB2" && lacks "$DB3" && lacks wttest_main && lacks template && [ "$(grep -c "would drop" "$OUT")" = 1 ]'
check "prune --dry-run drops nothing" eval 'db_present "$DB2" && db_present "$DB3"'
wt_in "$REPO" prune
check "prune drops the orphan only" eval 'rc_is 0 && db_absent "$DB2" && db_present "$DB3" && db_present wttest_main && db_present wttest_wt_template'

# --- wt CLI -----------------------------------------------------------------------------------------------

# T3 stores physical paths, as git reports them.
export_home() { mkdir -p "$TMP/home/.config/wt" && echo "$REPO_P" >"$TMP/home/.config/wt/projects"; }
export_home
wt_cli() { HOME="$TMP/home" python3 "$SRC/wt/wt" "$@" >"$OUT" 2>&1; RC=$?; }

wt_cli --help
check "wt --help" eval 'rc_is 0 && has "wt status"'
P3=$((PORT_BASE + 100 * $(state_val "$WT3" SLOT)))
start_server "$WT3" "$P3" || fail "fake server in wt3 started"
wt_cli status --json
check "wt status --json" eval 'rc_is 0 && python3 - "$OUT" "$WT3_P" "$P3" "$SERVER_PID" "$(state_val "$WT3" SLOT)" <<"EOF"
import json, sys
rows = json.load(open(sys.argv[1]))
w = [r for r in rows if r["path"] == sys.argv[2]]
assert w, "wt3 missing"
w = w[0]
assert w["slot"] == sys.argv[5], w
assert int(sys.argv[4]) in w["pids"], w
assert sys.argv[3] in w["ports"], w
assert w["verdict"] == "running", w
assert any(r["is_main"] for r in rows), "main missing"
EOF'
wt_cli status --all
check "wt status (table)" eval 'rc_is 0 && has wt3 && has "(main)"'
# macOS: the symlinked path must match too (wt resolves it); Linux matches the path as given.
WT3_ARG=$WT3_P
if [ "$(uname -s)" = Darwin ] || [ "${WT_TEST_FORCE_OS:-}" = Darwin ]; then WT3_ARG=$WT3; fi
wt_cli stop "$WT3_ARG"
check "wt stop <path> stops the server" eval 'rc_is 0 && wait_dead "$SERVER_PID" && port_closed "$P3" && alive "$OUTSIDE1"'
wt_cli teardown "$WT3_ARG"
check "wt teardown <path>" eval 'rc_is 0 && db_absent "$DB3" && [ ! -e "$WT3/.worktree" ]'

# --- summary ----------------------------------------------------------------------------------------------

echo
if [ "$FAIL" = 0 ]; then
    echo "# all $PASS checks passed"
    exit 0
fi
echo "# $FAIL of $((PASS + FAIL)) checks failed:"
printf '%s' "$FAILED"
exit 1
