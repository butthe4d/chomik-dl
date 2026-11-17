#!/usr/bin/env bash
# Runs inside a debian:13 container booted with systemd (see
# run-container-tests.sh). Checks that systemd's EnvironmentFile parser reads
# the settings file exactly as the lib's cd_settings_get does, that
# chomik-dl.service passes `systemd-analyze verify`, and that quick settings
# changes survive the unit's start limit.
set -uo pipefail

REPO="${REPO:-/repo}"
PASS=0
FAIL=0
FAILED=()
eq() {
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    echo "PASS: $1"
  else
    FAIL=$((FAIL + 1))
    FAILED+=("$1")
    echo "FAIL: $1 (expected [$2], got [$3])"
  fi
}

# shellcheck source-path=SCRIPTDIR source=../misc/chomik-dl-lib.sh
. "$REPO/proxmox/misc/chomik-dl-lib.sh"
export CHOMIKDL_ENV=/tmp/systemd-check.env

values=(
  $'p\'a"$b#c\\ d'
  "p'a\"\$b#c\\ d=e"
  'back\slash \n \\ end\'
  "  lead 'and' trail  "
  'dq"x ${HOME} $HOME `id` $(id) %h %%'
  "'"
  "x''y"
  "tab	here"
  "#hash ; & |"
  "a=b=c"
  "plain"
)
i=0
for v in "${values[@]}"; do
  i=$((i + 1))
  cd_settings_set CHOMIKUJ_PASSWORD "$v"
  eq "lib reads password $i back" "$v" "$(cd_settings_get CHOMIKUJ_PASSWORD)"
  # shellcheck disable=SC2016
  got="$(systemd-run -q --pipe --wait -p EnvironmentFile="$CHOMIKDL_ENV" \
    python3 -c 'import os, sys; sys.stdout.write(os.environ.get("CHOMIKUJ_PASSWORD", "<unset>"))')"
  eq "systemd reads password $i identically" "$v" "$got"
done

# Unit sanity: real user, code dir and interpreter, so verify checks the unit itself.
groupadd --gid 1000 chomik-dl
useradd --system --uid 1000 --gid 1000 --home-dir /var/lib/chomik-dl --no-create-home \
  --shell /usr/sbin/nologin chomik-dl
mkdir -p /var/lib/chomik-dl /opt/chomik-dl/.venv/bin /etc/chomik-dl
chown chomik-dl:chomik-dl /var/lib/chomik-dl
ln -sf /usr/bin/python3 /opt/chomik-dl/.venv/bin/python
touch /etc/chomik-dl/chomik-dl.env
cp "$REPO/proxmox/misc/chomik-dl.service" /etc/systemd/system/chomik-dl.service
out="$(systemd-analyze verify /etc/systemd/system/chomik-dl.service 2>&1)"
eq "systemd-analyze verify is clean" "" "$out"

# Start limit on real systemd (StartLimitBurst=5 per StartLimitIntervalSec=120
# in the unit): manual restarts count, so quick settings changes must clear
# it (reset-failed) or the app ends up down. The unit runs a tiny stand-in
# app answering /healthz on port 8080 (drop-in); everything else is real:
# the unit's limits, chomik-dl-settings and the lib.
cat >/tmp/fakeapp.py <<'PY'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ok" if self.path == "/healthz" else b"no"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer.allow_reuse_address = True
http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()
PY
chmod 644 /tmp/fakeapp.py
mkdir -p /etc/systemd/system/chomik-dl.service.d
printf '%s\n' '[Service]' 'ExecStart=' 'ExecStart=/usr/bin/python3 /tmp/fakeapp.py' \
  >/etc/systemd/system/chomik-dl.service.d/test.conf
export CHOMIKDL_ENV=/etc/chomik-dl/chomik-dl.env
: >"$CHOMIKDL_ENV"
cd_settings_set CHOMIKUJ_LOGIN tester
cd_settings_set CHOMIKUJ_PASSWORD "${values[0]}"
cd_settings_set MIN_JOB_GAP_SECONDS 20
chown root:chomik-dl "$CHOMIKDL_ENV" && chmod 640 "$CHOMIKDL_ENV"
systemctl daemon-reload
first_refused=""
for i in 1 2 3 4 5 6; do systemctl restart chomik-dl >/dev/null 2>&1 || { first_refused=$i; break; }; done
eq "real systemd refuses the 6th quick restart" 6 "$first_refused"
eq "the refusal is the start limit" start-limit-hit "$(systemctl show -p Result --value chomik-dl)"
systemctl reset-failed chomik-dl
systemctl start chomik-dl
cd_health 30 >/dev/null 2>&1
fails=0
for i in 1 2 3 4 5 6 7; do
  CHOMIKDL_LIB="$REPO/proxmox/misc/chomik-dl-lib.sh" bash "$REPO/proxmox/misc/chomik-dl-settings" \
    --set MIN_JOB_GAP_SECONDS "$((20 + i))" >/tmp/quick.out 2>&1 || { fails=$((fails + 1)); tail -n 5 /tmp/quick.out; }
done
eq "7 consecutive --set calls succeed on real systemd" 0 "$fails"
eq "last value saved" 27 "$(cd_settings_get MIN_JOB_GAP_SECONDS)"
eq "service active after 7 quick --set calls" active "$(systemctl is-active chomik-dl)"
eq "app answers after 7 quick --set calls" ok "$(curl -fsS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null)"
eq "the service got the password byte for byte" "${values[0]}" \
  "$(tr '\0' '\n' <"/proc/$(systemctl show -p MainPID --value chomik-dl)/environ" 2>/dev/null | sed -n 's/^CHOMIKUJ_PASSWORD=//p')"
systemctl stop chomik-dl

echo
echo "systemd tests: $PASS passed, $FAIL failed"
if ((FAIL > 0)); then
  echo "Failed checks:"
  printf '  - %s\n' "${FAILED[@]}"
fi
[[ $FAIL -eq 0 ]]
