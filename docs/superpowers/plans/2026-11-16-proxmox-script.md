# Proxmox Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command on a Proxmox host creates a Debian 13 LXC running chomik-dl natively, with `chomik-dl-settings`, `update` (backup + rollback) and downloads going to a NAS mount at `/data`.

**Architecture:** A copy of wish-list's `proxmox/` adapted to chomik-dl (`cd_` function prefix instead of `wl_`): the ct script sources the pinned community-scripts engine; the install script runs inside the LXC and uses `misc/chomik-dl-lib.sh` for settings, install, backup, update and rollback; a systemd unit runs uvicorn. A small app change makes downloads refuse to start when `/data` isn't a writable mount point.

**Tech Stack:** bash, whiptail, systemd, community-scripts/core engine (pinned), Python venv, Playwright 1.65.1 Chromium, GitHub Actions, shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-16-proxmox-script-design.md`
**Copy source (read, don't modify):** `/workspace/wish-list/proxmox/` and its design `/workspace/wish-list/docs/superpowers/specs/2026-11-13-proxmox-script-design.md`.

## Global Constraints

- Engine pin: `https://raw.githubusercontent.com/community-scripts/core/665635b6aff5cf1486400d47e6c5aa38f9ba333d` (same as wish-list); `COMMUNITY_SCRIPTS_URL` default `https://raw.githubusercontent.com/butthe4d/chomik-dl/main/proxmox`.
- `APP="chomik-dl"`, `SCRIPT_SLUG="butthe4d-chomik-dl"`, `REPO_SLUG="butthe4d/chomik-dl"`, tags `chomik-dl`; defaults `var_cpu=1`, `var_ram=1536`, `var_disk=6`, `var_os=debian`, `var_version=13`, `var_unprivileged=1`.
- Container layout: user/group `chomik-dl` with UID/GID **1000**; code `/opt/chomik-dl` (venv `.venv`); browsers `PLAYWRIGHT_BROWSERS_PATH=/opt/chomik-dl-browsers`; state `DATA_DIR=/var/lib/chomik-dl` (mode 750, app user); `DOWNLOAD_DIR=/data`; `DOWNLOAD_REQUIRE_MOUNT=true`; settings `/etc/chomik-dl/chomik-dl.env` (root:chomik-dl 640); version file `/opt/chomik-dl_version.txt`; lib `/usr/local/lib/chomik-dl/chomik-dl-lib.sh`; settings command `/usr/local/bin/chomik-dl-settings`; unit `/etc/systemd/system/chomik-dl.service`; creds `/root/chomik-dl.creds` (600); backups `/var/backups/chomik-dl/` keep last 3.
- Service: `ExecStart=/opt/chomik-dl/.venv/bin/uvicorn --factory app.main:build --host 0.0.0.0 --port 8080`, `User=chomik-dl`, `EnvironmentFile=/etc/chomik-dl/chomik-dl.env`, `WorkingDirectory=/opt/chomik-dl`, `Restart=on-failure`; health URL `http://127.0.0.1:8080/healthz`.
- User settings (prompted / editable): `CHOMIKUJ_LOGIN` (required), `CHOMIKUJ_PASSWORD` (required, secret, masked), `PUBLIC_URL` (default `http://<container-IP>:8080`, must be http(s) URL without trailing slash), `ALLOWED_HOSTS` (optional, comma-separated hostnames), `MIN_JOB_GAP_SECONDS` (default 20), `HUMAN_PAUSE_MIN` (1.0), `HUMAN_PAUSE_MAX` (4.0; numbers ≥ 0, min ≤ max), `CHOMIKDL_CHANNEL` (`main` default | `releases`). Fixed (written, not offered in the menu): `DATA_DIR`, `DOWNLOAD_DIR`, `DOWNLOAD_REQUIRE_MOUNT`, `PLAYWRIGHT_BROWSERS_PATH`, `HEADLESS=true`.
- Values may contain any characters except newline; quoting via the copied `wl_quote`/`wl_unquote` logic (renamed `cd_…`).
- Secrets (chomikuj password, admin token) never in install output (non-TTY), service log, engine log or argv.
- New app error: `storage_unavailable` "Download folder is not available — is the NAS mounted?".
- Playwright pinned in `pyproject.toml` as `playwright==1.65.1`; install and every update run `.venv/bin/playwright install --with-deps chromium` with `PLAYWRIGHT_BROWSERS_PATH` set.
- `releases` channel with no GitHub release/tag: update prints "No release yet; staying on <current>." and exits 0 without changes.
- English prompts/messages; README in English.

## Review Focus

1. `/data` exists but is just a plain directory (NAS not attached) → downloads fail `storage_unavailable` before resolving (no transfer spent); requests still accepted → test in Task 1.
2. Password with `'`, `"`, `$`, `#`, `\`, spaces, `=` → reaches the app's environment byte-for-byte via systemd EnvironmentFile → test in Task 4 (systemd-tests) and Task 2 (lib-tests round trip).
3. Update to a version whose app fails to start → rollback restores previous code and `/var/lib/chomik-dl` state; service healthy on the old version → test in Task 4 (test-update).
4. Re-running the install on an existing container (or `update` interrupted) → keeps settings, DB and admin token; no second admin token → test in Task 4.
5. Changing `PUBLIC_URL` in `chomik-dl-settings` → creds file and `admin-link.txt` show the new URL with the same token → test in Task 4.

---

## File Structure

```
app/worker.py, app/config.py, app/errors.py   storage check (Task 1)
pyproject.toml                                playwright==1.65.1 (Task 1)
proxmox/misc/chomik-dl-lib.sh                 settings, prompts, install, backup, update, rollback (Task 2)
proxmox/misc/chomik-dl-settings               whiptail menu + --set/--get CLI (Task 2)
proxmox/misc/chomik-dl.service                systemd unit (Task 2)
proxmox/tests/lib-tests.sh                    local, no docker: settings/quote/validate (Task 2)
proxmox/install/chomik-dl-install.sh          runs inside the LXC (Task 3)
proxmox/ct/chomik-dl.sh                       runs on the Proxmox host (Task 3)
proxmox/tests/{run-container-tests.sh,container-tests.sh,test-update.sh,systemd-tests.sh,stub-functions.sh,stubs/}  (Task 4)
.github/workflows/ci.yml                      pytest + shellcheck + container harness (Task 4)
README.md                                     Proxmox section (Task 5)
```

---

### Task 1: Storage check in the app

**Files:** Modify `app/config.py`, `app/errors.py`, `app/worker.py`, `pyproject.toml`; Test `tests/test_worker.py`, `tests/test_config.py`.

**Interfaces:**
- Produces: `Settings.download_require_mount: bool = False` (env `DOWNLOAD_REQUIRE_MOUNT`, parsed like `HEADLESS`); `check_download_dir(path: Path, require_mount: bool) -> None` in `app/worker.py` raising `ChomikError("storage_unavailable")` when the dir is missing, not writable (write+delete a temp file), or `require_mount and not os.path.ismount(path)`; `Worker._process` calls it **before** `session.resolve`. `MESSAGES["storage_unavailable"]` exact text from Global Constraints. `storage_unavailable` is not retryable.
- [ ] **Step 1: Failing tests:** `test_require_mount_plain_dir_fails_before_resolve` (settings with `download_require_mount=True`, download dir a plain tmp dir → job `failed`, `error_code == "storage_unavailable"`, FakeSession.calls == 0); `test_require_mount_false_plain_dir_ok` (default → done); `test_unwritable_dir_fails` (dir chmod 0o500, skip if running as root); `test_missing_dir_fails`; monkeypatch `os.path.ismount` → True with require_mount → done. Config test: `DOWNLOAD_REQUIRE_MOUNT=true` → True, default False.
- [ ] **Step 2:** `.venv/bin/pytest -q tests/test_worker.py tests/test_config.py` → FAIL.
- [ ] **Step 3:** Implement; pin `playwright==1.65.1` in `pyproject.toml`; reinstall `.venv/bin/pip install -e '.[dev]'`.
- [ ] **Step 4:** Full suite `.venv/bin/pytest -q` → PASS.
- [ ] **Step 5:** Commit `feat: refuse downloads when the download folder isn't a writable mount`.

### Task 2: Container lib, settings command, unit

**Files:** Create `proxmox/misc/chomik-dl-lib.sh`, `proxmox/misc/chomik-dl-settings`, `proxmox/misc/chomik-dl.service`, `proxmox/tests/lib-tests.sh`.

**Interfaces (functions later tasks call — `cd_` versions of wish-list's `wl_` ones unless noted):**
- Constants: `CD_USER=chomik-dl`, `CD_UID=1000`, `CD_APP_DIR=/opt/chomik-dl`, `CD_BROWSERS_DIR=/opt/chomik-dl-browsers`, `CD_DATA_DIR=/var/lib/chomik-dl`, `CD_DOWNLOAD_DIR=/data`, `CHOMIKDL_ENV=/etc/chomik-dl/chomik-dl.env`, `CD_VERSION_FILE`, `CD_CREDS_FILE`, `CD_SERVICE=chomik-dl`, `CD_BACKUP_DIR=/var/backups/chomik-dl`, `CD_HEALTH_URL`.
- Settings: `cd_settings_get KEY`, `cd_settings_set KEY VALUE` (reject newline/unknown key), `cd_validate KEY VALUE` (rules in Global Constraints; message names the key), `cd_collect_settings` (prompts; unattended/no TTY: requires `CHOMIKUJ_LOGIN`/`CHOMIKUJ_PASSWORD` from env `CHOMIKDL_LOGIN`/`CHOMIKDL_PASSWORD`, else writes the rest and leaves the service disabled with a message to run `chomik-dl-settings`), `cd_write_fixed_settings`.
- Install/update: `cd_latest_ref CHANNEL`, `cd_install_ref REF TARGET` (git checkout into `TARGET.new`, venv, `pip install .`, `playwright install --with-deps chromium` with `PLAYWRIGHT_BROWSERS_PATH=$CD_BROWSERS_DIR`, swap dirs), `cd_backup`, `cd_restore`, `cd_prune_backups` (keep 3), `cd_update`, `cd_health SECONDS`, `cd_service ACTION`, `cd_run_as_app CMD…` (settings env only, caller env dropped), `cd_shielded`, `cd_with_lock`, `cd_write_update_entrypoint`.
- New: `cd_write_creds` — runs `python -m app.admin` as the app user (DATA_DIR + PUBLIC_URL from settings), writes `CD_CREDS_FILE` (umask 077, `Admin link: <url>`), never echoes the token unless stdout is a TTY. `cd_regenerate_admin` — same with `--regenerate`.
- Dropped from wish-list: SECRET_KEY, SMTP/SMS, FETCH_DENY_CIDRS, language, translations, bootstrap/migrations, gunicorn checks, pictures backup.
- `chomik-dl-settings`: whiptail menu (all user settings with current values, password masked; "Regenerate admin link"; changing `PUBLIC_URL` calls `cd_write_creds`), plus `--get KEY`, `--set KEY VALUE…`, `--set KEY -` (stdin), `--help`, exit 2 on usage errors; restarts the service after saving and shows the service log on failure.
- Unit file per Global Constraints plus `Environment=PLAYWRIGHT_BROWSERS_PATH=/opt/chomik-dl-browsers`, `StartLimitIntervalSec`/`StartLimitBurst` copied from wish-list.
- [ ] **Step 1: Failing `proxmox/tests/lib-tests.sh`** (plain bash, runs locally without docker, `check NAME CMD…` helper like wish-list's): quote/unquote round trip for `p'a"$b#c\ d=e` and a value with leading/trailing spaces; values never executed (`$(touch /tmp/pwned)` stays literal); newline rejected; unknown key rejected; validation: empty login rejected, `PUBLIC_URL=ftp://x` rejected, `PUBLIC_URL=http://h:8080/` rejected (trailing slash), `HUMAN_PAUSE_MIN=5` with MAX 4 rejected, `MIN_JOB_GAP_SECONDS=-1` rejected, `CHOMIKDL_CHANNEL=beta` rejected, `ALLOWED_HOSTS=a.lan,b.lan` accepted; `--help` mentions `--set KEY -`; `--set` with missing value exits 2.
- [ ] **Step 2:** `bash proxmox/tests/lib-tests.sh` → FAIL (files missing).
- [ ] **Step 3:** Implement by copying wish-list's files and adapting per the Interfaces above.
- [ ] **Step 4:** `bash proxmox/tests/lib-tests.sh` → all checks pass; `shellcheck -x -S warning proxmox/misc/chomik-dl-lib.sh proxmox/misc/chomik-dl-settings proxmox/tests/lib-tests.sh` clean (install shellcheck via apt if missing).
- [ ] **Step 5:** Commit `feat(proxmox): container lib, settings command and unit`.

### Task 3: Install and ct scripts

**Files:** Create `proxmox/install/chomik-dl-install.sh`, `proxmox/ct/chomik-dl.sh`.

**Interfaces:** Consumes Task 2's functions. `CHOMIKDL_SOURCE_DIR` (local checkout, used by the harness) replaces wish-list's `WISHLIST_SOURCE_DIR`; `CHOMIKDL_REF` overrides the ref.
- Install steps: deps (`python3 python3-venv git sqlite3 curl ca-certificates whiptail`); helpers fetched from `COMMUNITY_SCRIPTS_URL/misc` (or source dir); user/group `chomik-dl` UID/GID 1000 (fail clearly if 1000 is taken by another name); `install -d` for `CD_DATA_DIR` (750) and `/etc/chomik-dl` (750 root:chomik-dl); `/data` created (app user, 755) only if missing — never chown an existing `/data`; `cd_collect_settings`; `cd_write_fixed_settings`; `cd_install_ref`; enable+start unit (skip if credentials missing); `cd_health 90`; `cd_write_creds`; `motd_ssh`, `customize`, `cd_write_update_entrypoint`, `cleanup_lxc`; final lines: URL, creds hint (link only on a live TTY), `chomik-dl-settings` hint, and a note "Attach your NAS folder at /data (see README) — downloads are refused until it is mounted."
- ct script: copy of wish-list's with Global Constraints values; `update_script` sources the container lib and runs `cd_update`; final messages show `http://${IP}:8080`, `pct exec ${CTID} -- cat /root/chomik-dl.creds`, `pct set ${CTID} -mp0 <host-path>,mp=/data` hint.
- [ ] **Step 1:** Write both scripts.
- [ ] **Step 2:** `shellcheck -x -S warning proxmox/ct/chomik-dl.sh proxmox/install/chomik-dl-install.sh` → clean. (Behaviour is tested by Task 4's harness.)
- [ ] **Step 3:** Commit `feat(proxmox): install and ct scripts`.

### Task 4: Container test harness and CI

**Files:** Create `proxmox/tests/run-container-tests.sh`, `container-tests.sh`, `test-update.sh`, `systemd-tests.sh`, `stub-functions.sh`, `stubs/systemctl`, `stubs/journalctl`; Create `.github/workflows/ci.yml`.

- Harness adapted from wish-list (debian:13, repo mounted at `/repo`, `CHOMIKDL_SOURCE_DIR=/repo`, `--security-opt apparmor=unconfined` default via `CD_DOCKER_RUN_OPTS`).
- Unattended install answers via env (`CHOMIKDL_LOGIN=tester`, `CHOMIKDL_PASSWORD=$'p\'a"$b#c\\ d'`).
- **container-tests.sh checks:** lib/settings/unit installed; venv + Chromium present under `/opt/chomik-dl-browsers`; user UID 1000; `/data` created; service healthy (`/healthz` = ok); creds file has `Admin link: http://`; admin token not in install output (non-TTY), service log, engine log; password not in any of those logs; `cd_run_as_app` passes settings and drops caller env; `chomik-dl-settings --set PUBLIC_URL http://10.0.0.9:8080` restarts the service and rewrites creds and `/var/lib/chomik-dl/admin-link.txt` with the same token; "regenerate" changes the token and the old one no longer opens `/admin` (HTTP 404); `storage_unavailable`: with `/data` a plain dir, `POST /admin/requests` is not testable offline, so check the worker path by running `cd_run_as_app .venv/bin/python -c` that calls `app.worker.check_download_dir(Path('/data'), True)` and expects ChomikError code `storage_unavailable`; re-running the install script keeps the DB, token and settings.
- **test-update.sh checks:** update from local ref A to B (B = A + a trivial commit made inside the test) succeeds, version file updated, backup created, keep-3 pruning; B' whose app fails to start (e.g. a commit that breaks `app/main.py` import) → rollback to A, service healthy, DB/token intact; `releases` channel with no tags → "No release yet" message, exit 0, nothing changed; interrupted update leaves the old version running.
- **systemd-tests.sh checks:** systemd reads `CHOMIKUJ_PASSWORD` with quotes/`$`/`#`/`\`/spaces/`=` byte-for-byte (`systemd-run`/`systemctl show-environment` approach copied from wish-list); unit passes `systemd-analyze verify`; quick successive settings changes survive the start limit.
- **CI** (`.github/workflows/ci.yml`, on push to main and PRs): `test` job (Python 3.12, `pip install -e .[dev]`, `playwright install --with-deps chromium`, `pytest -q`); `shellcheck` job over `git ls-files 'proxmox/*'` minus `.service`; `container` job running `proxmox/tests/run-container-tests.sh` (ubuntu-latest has docker; default run opts are fine) and `bash proxmox/tests/lib-tests.sh`.
- [ ] **Step 1:** Write harness + workflow.
- [ ] **Step 2:** `shellcheck` clean locally; `bash proxmox/tests/lib-tests.sh` passes locally.
- [ ] **Step 3:** The container harness cannot run in the dev sandbox (AppArmor). Verification is a CI run: the controller pushes the branch (with the user's approval) and reads the Actions result; fix until green.
- [ ] **Step 4:** Commit `test(proxmox): container harness and CI`.

### Task 5: README

**Files:** Modify `README.md`.
- [ ] **Step 1:** Add "Proxmox (community-script style)" section: the one-liner (`bash -c "$(curl -fsSL https://raw.githubusercontent.com/butthe4d/chomik-dl/main/proxmox/ct/chomik-dl.sh)"`), what it asks, defaults (1 vCPU / 1.5 GB / 6 GB), where things live, admin link (`pct exec <CTID> -- cat /root/chomik-dl.creds`), `chomik-dl-settings`, `update` + channels; **Attaching the NAS folder**: mount the share on the host (Proxmox storage or fstab), `pct set <CTID> -mp0 /mnt/…/chomik,mp=/data`, the app writes as UID/GID 1000 in the container = **101000** on the host; NFS example (`all_squash,anonuid=101000,anongid=101000` on the server or matching ownership) and SMB example (host mount with `uid=101000,gid=101000`); downloads are refused with "Download folder is not available — is the NAS mounted?" until it works; **captcha** in the LXC: log in once with `playwright open --user-data-dir` on a desktop, stop the service, copy the profile to `/var/lib/chomik-dl/browser`, `chown -R chomik-dl:chomik-dl`, start.
- [ ] **Step 2:** Commit `docs: Proxmox install and NAS mount`.
