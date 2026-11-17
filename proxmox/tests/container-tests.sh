#!/usr/bin/env bash
# Runs inside a plain debian:13 container (started by run-container-tests.sh)
# with the repo mounted read-only at /repo. Installs chomik-dl with the real
# install script (engine functions and systemctl stubbed, code from /repo) and
# checks the result: layout, secrets kept out of logs, settings changes, the
# admin link, the download-folder check and a re-run of the install.
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
not_in() { # description, needle, file...: the needle appears in none of the files
  local d="$1" needle="$2"
  shift 2
  if grep -qF -- "$needle" "$@" 2>/dev/null; then bad "$d"; else ok "$d"; fi
}
finish() {
  echo
  echo "container tests: $PASS passed, $FAIL failed"
  if ((FAIL > 0)); then
    echo "Failed checks:"
    printf '  - %s\n' "${FAILED[@]}"
  fi
  [[ $FAIL -eq 0 ]]
  exit
}

export DEBIAN_FRONTEND=noninteractive
# The app starts Chromium; give it time on a slow CI runner.
export CHOMIKDL_HEALTH_TIMEOUT=90
install -m 755 "$REPO/proxmox/tests/stubs/systemctl" /usr/local/bin/systemctl
install -m 755 "$REPO/proxmox/tests/stubs/journalctl" /usr/local/bin/journalctl

ENV_FILE=/etc/chomik-dl/chomik-dl.env
LIB=/usr/local/lib/chomik-dl/chomik-dl-lib.sh
SVC_LOG=/var/log/stub-systemd/chomik-dl.log
STD_LOG=/var/log/stub-std.log
DATA=/var/lib/chomik-dl
# The unattended install's password: quotes, $, #, backslash and a space.
PW=$'p\'a"$b#c\\ d'
health() { curl -fsS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null; }
app_pid() { cat /run/stub-systemd/chomik-dl.pid 2>/dev/null; }
uid_of() { awk '/^Uid:/{print $2}' "/proc/$1/status" 2>/dev/null; }
admin_code() { # token -> HTTP status of GET /admin/<token> (Host: 127.0.0.1:8080)
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:8080/admin/$1"
}
link_token() { sed -n 's|^Admin link: .*/admin/||p' /root/chomik-dl.creds 2>/dev/null; }

# --- 1. Unattended install -----------------------------------------------------
echo "== unattended install (Python packages and Chromium; several minutes) =="
FUNCTIONS_FILE_PATH="$(cat "$REPO/proxmox/tests/stub-functions.sh")"
export FUNCTIONS_FILE_PATH
if CHOMIKDL_SOURCE_DIR="$REPO" CHOMIKDL_UNATTENDED=1 CHOMIKDL_LOGIN=tester CHOMIKDL_PASSWORD="$PW" \
  bash "$REPO/proxmox/install/chomik-dl-install.sh" </dev/null >/tmp/install.out 2>&1; then
  ok "unattended install exits 0"
else
  bad "unattended install exits 0"
  echo "--- install output (last 60 lines) ---"
  tail -n 60 /tmp/install.out
  echo "--- engine log (last 40 lines) ---"
  tail -n 40 "$STD_LOG" 2>/dev/null
  echo "--- service log (last 40 lines) ---"
  tail -n 40 "$SVC_LOG" 2>/dev/null
  finish
fi

# shellcheck source-path=SCRIPTDIR source=../misc/chomik-dl-lib.sh
. "$LIB"

eq "/healthz answers ok" ok "$(health)"
check "lib installed" test -f "$LIB"
check "lib is the repo's" cmp -s "$REPO/proxmox/misc/chomik-dl-lib.sh" "$LIB"
check "chomik-dl-settings installed" test -x /usr/local/bin/chomik-dl-settings
check "unit installed" cmp -s "$REPO/proxmox/misc/chomik-dl.service" /etc/systemd/system/chomik-dl.service
check "unit enabled" test -e /etc/systemd/system/multi-user.target.wants/chomik-dl.service
check "venv in /opt/chomik-dl/.venv" test -x /opt/chomik-dl/.venv/bin/python
check "Chromium under /opt/chomik-dl-browsers" \
  bash -c 'compgen -G "/opt/chomik-dl-browsers/chromium-*/" >/dev/null'
eq "version file records the ref" local "$(cat /opt/chomik-dl_version.txt 2>/dev/null)"
eq "user chomik-dl has UID 1000" 1000 "$(id -u chomik-dl 2>/dev/null)"
eq "group chomik-dl has GID 1000" 1000 "$(getent group chomik-dl | cut -d: -f3)"
check "/data created" test -d /data
eq "/data owned by chomik-dl" chomik-dl "$(stat -c %U /data 2>/dev/null)"
eq "data dir 750 chomik-dl" "750 chomik-dl" "$(stat -c '%a %U' "$DATA" 2>/dev/null)"
eq "settings file 640 root:chomik-dl" "640 root:chomik-dl" "$(stat -c '%a %U:%G' "$ENV_FILE" 2>/dev/null)"
check "database created" test -f "$DATA/jobs.db"
eq "app runs as chomik-dl" 1000 "$(uid_of "$(app_pid)")"
chromium_up=0
for p in /proc/[0-9]*; do
  [[ "$(uid_of "${p##*/}")" == 1000 ]] || continue
  tr '\0' ' ' <"$p/cmdline" 2>/dev/null | grep -q '/opt/chomik-dl-browsers/' && chromium_up=1
done
eq "the app started Chromium from /opt/chomik-dl-browsers" 1 "$chromium_up"

eq "login from CHOMIKDL_LOGIN" tester "$(cd_settings_get CHOMIKUJ_LOGIN)"
eq "password stored byte for byte" "$PW" "$(cd_settings_get CHOMIKUJ_PASSWORD)"
eq "the service got the password byte for byte" "$PW" \
  "$(tr '\0' '\n' <"/proc/$(app_pid)/environ" | sed -n 's/^CHOMIKUJ_PASSWORD=//p')"
eq "DOWNLOAD_REQUIRE_MOUNT" true "$(cd_settings_get DOWNLOAD_REQUIRE_MOUNT)"
eq "DOWNLOAD_DIR" /data "$(cd_settings_get DOWNLOAD_DIR)"
eq "DATA_DIR" "$DATA" "$(cd_settings_get DATA_DIR)"
eq "PLAYWRIGHT_BROWSERS_PATH" /opt/chomik-dl-browsers "$(cd_settings_get PLAYWRIGHT_BROWSERS_PATH)"
eq "default channel" main "$(cd_settings_get CHOMIKDL_CHANNEL)"
public_url="$(cd_settings_get PUBLIC_URL)"
check "PUBLIC_URL defaults to the container's IPv4 address (got $public_url)" \
  bash -c '[[ "$1" =~ ^http://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8080$ && "$1" != http://127.0.0.1:8080 ]]' _ "$public_url"

check "creds file has the admin link" grep -q '^Admin link: http://' /root/chomik-dl.creds
eq "creds file is 600 root" "600 root" "$(stat -c '%a %U' /root/chomik-dl.creds 2>/dev/null)"
check "install output (not a terminal) points to the creds file" grep -q 'admin link is in /root/chomik-dl.creds' /tmp/install.out
token="$(link_token)"
check "admin token found in the creds file" test "${#token}" -ge 20
eq "creds token is the app's token" "$token" "$(tr -d '\n' <"$DATA/admin-token" 2>/dev/null)"
not_in "admin token not in install output (not a terminal)" "$token" /tmp/install.out
not_in "admin token not in service log" "$token" "$SVC_LOG"
not_in "admin token not in engine log" "$token" "$STD_LOG"
not_in "password not in install output" "$PW" /tmp/install.out
not_in "password not in service log" "$PW" "$SVC_LOG"
not_in "password not in engine log" "$PW" "$STD_LOG"
# Compared in bash: a grep given the password would put it on its own argv.
argv_leak=0
for p in /proc/[0-9]*; do
  cmdline="$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)"
  [[ "$cmdline" == *"$PW"* ]] && argv_leak=1
done
eq "password on no process command line" 0 "$argv_leak"

app_env="$(CD_LEAK_CHECK=1 cd_run_as_app /usr/bin/env)"
check "cd_run_as_app passes the settings" grep -qx 'CHOMIKUJ_LOGIN=tester' <<<"$app_env"
check "cd_run_as_app drops the caller's environment" bash -c '! grep -q "^CD_LEAK_CHECK=" <<<"$1"' _ "$app_env"
eq "cd_run_as_app runs as chomik-dl" chomik-dl "$(cd_run_as_app /usr/bin/id -un)"
eq "cd_run_as_app runs in the code dir" /opt/chomik-dl "$(cd_run_as_app /bin/pwd)"

# --- 2. Settings changes -----------------------------------------------------------
echo "== chomik-dl-settings --set PUBLIC_URL =="
pid_before="$(app_pid)"
out="$(chomik-dl-settings --set PUBLIC_URL http://10.0.0.9:8080 2>&1)"
rc=$?
eq "--set PUBLIC_URL exits 0" 0 "$rc"
[[ $rc == 0 ]] || echo "$out" | tail -n 30
check "--set PUBLIC_URL restarted the service" test "$pid_before" != "$(app_pid)"
eq "healthy after --set" ok "$(health)"
eq "--get PUBLIC_URL" http://10.0.0.9:8080 "$(chomik-dl-settings --get PUBLIC_URL)"
eq "creds file has the new URL, same token" "Admin link: http://10.0.0.9:8080/admin/$token" \
  "$(grep '^Admin link: ' /root/chomik-dl.creds)"
eq "admin-link.txt has the new URL, same token" "http://10.0.0.9:8080/admin/$token" "$(head -n 1 "$DATA/admin-link.txt" 2>/dev/null)"
eq "creds file still 600 root" "600 root" "$(stat -c '%a %U' /root/chomik-dl.creds 2>/dev/null)"
not_in "admin token not in --set output" "$token" <(printf '%s' "$out")
before="$(sha256sum <"$ENV_FILE")"
out="$(chomik-dl-settings --set PUBLIC_URL ftp://x 2>&1)"
check "--set with an invalid value fails" test $? -ne 0
check "--set with an invalid value says why" grep -q PUBLIC_URL <<<"$out"
eq "invalid value leaves the file unchanged" "$before" "$(sha256sum <"$ENV_FILE")"

# --- 3. Admin link ---------------------------------------------------------------------
echo "== admin link: open and regenerate =="
eq "current admin link opens /admin" 200 "$(admin_code "$token")"
eq "a wrong token gets 404" 404 "$(admin_code wrong-token-0123456789abcdef)"
check "cd_regenerate_admin succeeds" cd_regenerate_admin
new_token="$(link_token)"
check "regenerate wrote a token to the creds file" test "${#new_token}" -ge 20
check "regenerate changed the token" test "$new_token" != "$token"
eq "the running app knows the new token (no restart)" 200 "$(admin_code "$new_token")"
eq "the old token no longer opens /admin" 404 "$(admin_code "$token")"
eq "admin-link.txt has the new token" "http://10.0.0.9:8080/admin/$new_token" "$(head -n 1 "$DATA/admin-link.txt" 2>/dev/null)"
not_in "new admin token not in service log (access log redacted)" "$new_token" "$SVC_LOG"
token="$new_token"

# --- 4. Download folder that is not a mount ------------------------------------------
echo "== storage_unavailable =="
# shellcheck disable=SC2016
storage_check='
import sys
from pathlib import Path
from app.errors import ChomikError
from app.worker import check_download_dir
try:
    check_download_dir(Path("/data"), sys.argv[1] == "true")
except ChomikError as e:
    print(e.code)
else:
    print("ok")
'
eq "/data (a plain dir) with DOWNLOAD_REQUIRE_MOUNT: storage_unavailable" storage_unavailable \
  "$(cd_run_as_app /opt/chomik-dl/.venv/bin/python -c "$storage_check" true 2>&1)"
eq "control: the same dir is fine without the mount requirement" ok \
  "$(cd_run_as_app /opt/chomik-dl/.venv/bin/python -c "$storage_check" false 2>&1)"

# --- 5. Re-running the install keeps data, token and settings -------------------------
echo "== install re-run (several minutes) =="
cd_as_app_user sqlite3 "$DATA/jobs.db" "CREATE TABLE IF NOT EXISTS harness_marker (x); INSERT INTO harness_marker VALUES ('keep-me')"
settings_before="$(sha256sum <"$ENV_FILE")"
if CHOMIKDL_SOURCE_DIR="$REPO" CHOMIKDL_UNATTENDED=1 \
  bash "$REPO/proxmox/install/chomik-dl-install.sh" </dev/null >/tmp/install2.out 2>&1; then
  ok "install re-run exits 0"
else
  bad "install re-run exits 0"
  tail -n 40 /tmp/install2.out
fi
eq "re-run: healthy" ok "$(health)"
eq "re-run: database kept" keep-me "$(cd_as_app_user sqlite3 "$DATA/jobs.db" 'SELECT x FROM harness_marker' 2>&1)"
eq "re-run: admin token kept" "$token" "$(tr -d '\n' <"$DATA/admin-token" 2>/dev/null)"
eq "re-run: creds file keeps the link" "Admin link: http://10.0.0.9:8080/admin/$token" "$(grep '^Admin link: ' /root/chomik-dl.creds)"
eq "re-run: settings file unchanged" "$settings_before" "$(sha256sum <"$ENV_FILE")"
eq "re-run: password kept" "$PW" "$(cd_settings_get CHOMIKUJ_PASSWORD)"
eq "re-run: old token still opens /admin" 200 "$(admin_code "$token")"
check "re-run kept the previous code as .prev" test -x /opt/chomik-dl.prev/.venv/bin/python
not_in "re-run: admin token not in install output" "$token" /tmp/install2.out
not_in "re-run: password not in install output" "$PW" /tmp/install2.out

finish
