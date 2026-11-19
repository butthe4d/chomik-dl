#!/usr/bin/env bash
# Runs inside the install test container (started by run-container-tests.sh)
# AFTER container-tests.sh, on the chomik-dl it installed. Checks the update
# routine (cd_update): upgrades with backups and keep-3 pruning, a new version
# that fails to start (rollback of code, database and admin token), the
# releases channel without any release, and an update interrupted by SIGTERM.
#
# "GitHub" is a local fake API (CHOMIKDL_GITHUB_API). The versions are commits
# in a temporary git repository made from /repo's working tree (/repo itself
# is never modified); each update builds the commit checked out there
# (CHOMIKDL_SOURCE_DIR) and records the sha the fake API reported.
set -uo pipefail

REPO="${REPO:-/repo}"
PASS=0
FAIL=0
FAILED=()
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); echo "FAIL: $1"; }
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
eq() { # description, expected, actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
finish() {
  kill "${api_pid:-}" 2>/dev/null
  echo
  echo "update tests: $PASS passed, $FAIL failed"
  if ((FAIL > 0)); then
    echo "Failed checks:"
    printf '  - %s\n' "${FAILED[@]}"
  fi
  [[ $FAIL -eq 0 ]]
  exit
}

if [[ "$(curl -fsS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null)" != ok ]]; then
  bad "precondition: chomik-dl installed and healthy (run container-tests.sh first)"
  finish
fi
# The repo's lib (what is under test); the installed copy came from the same
# checkout during container-tests.sh.
# shellcheck source-path=SCRIPTDIR source=../misc/chomik-dl-lib.sh
. "$REPO/proxmox/misc/chomik-dl-lib.sh"
# The app starts Chromium; give it time on a slow CI runner.
export CHOMIKDL_HEALTH_TIMEOUT=90

DATA=/var/lib/chomik-dl
DB="$DATA/jobs.db"
health() { curl -fsS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null; }
app_pid() { cat /run/stub-systemd/chomik-dl.pid 2>/dev/null; }
n_backups() { find "$CD_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }
version() { cat "$CD_VERSION_FILE"; }
inode() { stat -c %i "$CD_APP_DIR"; }
token() { tr -d '\n' <"$DATA/admin-token"; }
db() { cd_as_app_user sqlite3 "$DB" "$1" 2>&1; }
live_marker() { sed -n 's/^# update test: version //p' "$CD_APP_DIR/app/__init__.py" | tail -n 1; }
no_leftovers() { [[ ! -e "$CD_APP_DIR.new" && ! -e "$CD_APP_DIR.failed" ]]; }

# --- fake GitHub API --------------------------------------------------------------
F=/tmp/update-api
API_REPO="$F/repos/$CD_DEFAULT_REPO"
rm -rf "$F"
mkdir -p "$API_REPO/commits"
python3 -m http.server 8766 --bind 127.0.0.1 --directory "$F" >/dev/null 2>&1 &
api_pid=$!
export CHOMIKDL_GITHUB_API=http://127.0.0.1:8766
set_latest() { printf '{"sha": "%s", "commit": {}}\n' "$1" >"$API_REPO/commits/main"; }
for _ in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:8766/ && break; sleep 0.5; done

# --- versions: commits in a temporary repository ----------------------------------
G=/tmp/update-src
rm -rf "$G" && mkdir -p "$G"
# Owned by root (not /repo's owner), or git refuses the "dubious" repository.
tar -C "$REPO" --exclude=./.git --exclude=./.venv --exclude=./.superpowers --exclude=./.pytest_cache \
  --exclude=__pycache__ --exclude='*.egg-info' --exclude='*.db' -cf - . | tar -C "$G" --no-same-owner -xf -
gitc() { git -C "$G" -c user.name="update test" -c user.email=update-test@localhost -c commit.gpgsign=false "$@"; }
commit() { # message -> sha of the new commit
  gitc add -A && gitc commit -qm "$1" && gitc rev-parse HEAD
}
gitc init -q -b main
commit "working tree" >/dev/null
echo "# update test: version A" >>"$G/app/__init__.py"
SHA_A="$(commit A)"
# Imports fine (the build checks that), but the app never starts: it first
# changes the database and the admin token, which the rollback must undo.
cat >>"$G/app/main.py" <<'PY'


def build():  # update test: broken start
    import os
    import sqlite3
    data = Path(os.environ["DATA_DIR"])
    con = sqlite3.connect(data / "jobs.db")
    con.execute("CREATE TABLE update_test_broken (x)")
    con.commit()
    con.close()
    (data / "admin-token").write_text("broken-token\n")
    raise RuntimeError("update test: broken start")
PY
SHA_BROKEN="$(commit "broken start")"
gitc -c advice.detachedHead=false checkout -q "$SHA_A"
echo "# update test: version B" >>"$G/app/__init__.py"
SHA_B="$(commit B)"
echo "# update test: version C" >>"$G/app/__init__.py"
SHA_C="$(commit C)"
for s in "$SHA_A" "$SHA_BROKEN" "$SHA_B" "$SHA_C"; do
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || { bad "test setup: commits in $G"; finish; }
done
use_version() { # sha: what the next update builds and what "GitHub" reports
  gitc -c advice.detachedHead=false checkout -q "$1" && set_latest "$1"
}
export CHOMIKDL_SOURCE_DIR="$G"

# Data that every update, failed or not, must keep.
db "CREATE TABLE IF NOT EXISTS update_marker (x); DELETE FROM update_marker; INSERT INTO update_marker VALUES ('keep-me')" >/dev/null
start_version="$(version)"
start_token="$(token)"
rm -rf "$CD_BACKUP_DIR"

# --- upgrade: installed version -> A ------------------------------------------------
echo "== upgrade to version A (a few minutes) =="
use_version "$SHA_A"
out="$(cd_update 2>&1)"
rc=$?
eq "upgrade to A: exit 0" 0 "$rc"
[[ $rc == 0 ]] || echo "$out" | tail -n 40
eq "upgrade to A: version file updated" "$SHA_A" "$(version)"
eq "upgrade to A: new code is live" A "$(live_marker)"
eq "upgrade to A: /healthz ok" ok "$(health)"
eq "upgrade to A: one backup created" 1 "$(n_backups)"
b1="$(find "$CD_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
eq "upgrade to A: backup records the previous version" "$start_version" "$(cat "$b1/chomik-dl_version.txt" 2>/dev/null)"
check "upgrade to A: backup has the database" test -s "$b1/jobs.db"
check "upgrade to A: backup has the settings" test -f "$b1/chomik-dl.env"
eq "upgrade to A: database kept" keep-me "$(db 'SELECT x FROM update_marker')"
eq "upgrade to A: admin token kept" "$start_token" "$(token)"
check "upgrade to A: previous code kept as .prev" test -d "$CD_APP_DIR.prev"
check "upgrade to A: no staging dir left" test ! -e "$CD_APP_DIR.new"
check "upgrade to A: says it updated" grep -q "Updated chomik-dl to $SHA_A" <<<"$out"

# --- a version that fails to start -> rollback to A ----------------------------------
echo "== broken version: fails to start (a few minutes) =="
use_version "$SHA_BROKEN"
before_inode="$(inode)"
nb="$(n_backups)"
out="$(CHOMIKDL_HEALTH_TIMEOUT=45 cd_update 2>&1)"
rc=$?
check "broken: non-zero exit" test "$rc" -ne 0
check "broken: reports the rollback" grep -q "rolled back to $SHA_A" <<<"$out"
check "broken: shows the service log" grep -q "update test: broken start" <<<"$out"
eq "broken: version file back to A" "$SHA_A" "$(version)"
eq "broken: previous code dir restored" "$before_inode" "$(inode)"
eq "broken: A is live" A "$(live_marker)"
check "broken: the broken code is gone" bash -c "! grep -q 'update test: broken start' '$CD_APP_DIR/app/main.py'"
eq "broken: /healthz ok again" ok "$(health)"
eq "broken: admin token restored" "$start_token" "$(token)"
eq "broken: database restored (no table from the broken version)" "" \
  "$(db "SELECT name FROM sqlite_master WHERE name = 'update_test_broken'")"
eq "broken: database kept" keep-me "$(db 'SELECT x FROM update_marker')"
eq "broken: backup made before the change" $((nb + 1)) "$(n_backups)"
check "broken: no leftover dirs" no_leftovers
[[ $rc != 0 && "$(version)" == "$SHA_A" ]] || echo "$out" | tail -n 40

# --- upgrade: A -> B (B = A + a trivial commit) ----------------------------------------
echo "== upgrade from A to B (a few minutes) =="
use_version "$SHA_B"
out="$(cd_update 2>&1)"
rc=$?
eq "A to B: exit 0" 0 "$rc"
[[ $rc == 0 ]] || echo "$out" | tail -n 40
eq "A to B: version file updated" "$SHA_B" "$(version)"
eq "A to B: B is live" B "$(live_marker)"
eq "A to B: /healthz ok" ok "$(health)"
eq "A to B: backup created" 3 "$(n_backups)"
newest="$(find "$CD_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)"
eq "A to B: newest backup records A" "$SHA_A" "$(cat "$CD_BACKUP_DIR/$newest/chomik-dl_version.txt" 2>/dev/null)"
eq "A to B: admin token kept" "$start_token" "$(token)"
eq "A to B: database kept" keep-me "$(db 'SELECT x FROM update_marker')"

# --- releases channel without any release or tag ------------------------------------
echo "== releases channel, no release yet =="
cd_settings_set CHOMIKDL_CHANNEL releases
echo '[]' >"$API_REPO/tags"
pid="$(app_pid)"
before_inode="$(inode)"
nb="$(n_backups)"
out="$(cd_update 2>&1)"
rc=$?
eq "no release: exit 0" 0 "$rc"
check "no release: says so" grep -qF "No release yet; staying on $SHA_B." <<<"$out"
eq "no release: version unchanged" "$SHA_B" "$(version)"
eq "no release: code dir unchanged" "$before_inode" "$(inode)"
eq "no release: no backup" "$nb" "$(n_backups)"
eq "no release: service untouched" "$pid" "$(app_pid)"
cd_settings_set CHOMIKDL_CHANNEL main

# --- SIGTERM between the swap and the health check -> old version keeps running ----
echo "== interrupted update (a few minutes) =="
# A systemctl wrapper that, once, records who called `start` and stalls.
mkdir -p /tmp/slowsd
cat >/tmp/slowsd/systemctl <<'SH'
#!/usr/bin/env bash
if [[ "$1" == start && -e /tmp/slow-start ]]; then
  rm -f /tmp/slow-start
  echo "$PPID" >/tmp/start-caller
  sleep 4
fi
exec /usr/local/bin/systemctl "$@"
SH
chmod +x /tmp/slowsd/systemctl
rm -f /tmp/start-caller /tmp/sig.rc
touch /tmp/slow-start
use_version "$SHA_C"
before_inode="$(inode)"
(
  PATH=/tmp/slowsd:$PATH cd_update >/tmp/sig.out 2>&1
  echo $? >/tmp/sig.rc
) &
updater=$!
for _ in $(seq 1 1200); do [[ -s /tmp/start-caller ]] && break; sleep 0.5; done
if [[ -s /tmp/start-caller ]]; then
  kill -TERM "$(cat /tmp/start-caller)"
  wait "$updater"
  eq "interrupted: exits 143" 143 "$(cat /tmp/sig.rc 2>/dev/null)"
  check "interrupted: says so" grep -q "Update interrupted; putting the previous version back" /tmp/sig.out
  check "interrupted: rolled back" grep -q "rolled back to $SHA_B" /tmp/sig.out
  eq "interrupted: version file still B" "$SHA_B" "$(version)"
  eq "interrupted: code dir restored" "$before_inode" "$(inode)"
  eq "interrupted: B is running" B "$(live_marker)"
  eq "interrupted: /healthz ok" ok "$(health)"
  eq "interrupted: admin token kept" "$start_token" "$(token)"
  check "interrupted: no leftover dirs" no_leftovers
  check "interrupted: lock released" bash -c ". '$REPO/proxmox/misc/chomik-dl-lib.sh'; CD_LOCK_TIMEOUT=1 cd_with_lock true"
else
  bad "interrupted: the update never reached the start step"
  tail -n 30 /tmp/sig.out
  kill "$updater" 2>/dev/null
  wait "$updater"
fi
[[ "$(health)" == ok ]] || { cd_service start; cd_health >/dev/null 2>&1; }

# --- B -> C: keep the newest three backups -------------------------------------------
echo "== upgrade from B to C, backups pruned to 3 (a few minutes) =="
use_version "$SHA_C"
out="$(cd_update 2>&1)"
rc=$?
eq "B to C: exit 0" 0 "$rc"
[[ $rc == 0 ]] || echo "$out" | tail -n 40
eq "B to C: version file updated" "$SHA_C" "$(version)"
eq "B to C: C is live" C "$(live_marker)"
eq "B to C: /healthz ok" ok "$(health)"
eq "five backups made, the newest 3 kept" 3 "$(n_backups)"
newest="$(find "$CD_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)"
eq "the newest backup is the one before the last upgrade" "$SHA_B" "$(cat "$CD_BACKUP_DIR/$newest/chomik-dl_version.txt" 2>/dev/null)"
check "the oldest backups were removed" bash -c "! grep -qx -- '$start_version' '$CD_BACKUP_DIR'/*/chomik-dl_version.txt"
eq "B to C: admin token kept" "$start_token" "$(token)"
eq "B to C: database kept" keep-me "$(db 'SELECT x FROM update_marker')"

finish
