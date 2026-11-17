#!/usr/bin/env bash

# Copyright (c) 2026 butthe4d
# License: Apache-2.0 | https://github.com/butthe4d/chomik-dl/raw/main/LICENSE
# Source: https://github.com/butthe4d/chomik-dl

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

CHOMIKDL_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/butthe4d/chomik-dl/main/proxmox}"

# Helper files come from the same place as this script (CHOMIKDL_SOURCE_DIR:
# a local checkout, used by the test harness).
fetch_misc() { # name destination mode
  if [[ -n "${CHOMIKDL_SOURCE_DIR:-}" ]]; then
    install -m "$3" "$CHOMIKDL_SOURCE_DIR/proxmox/misc/$1" "$2"
  else
    curl -fsSL --retry 3 -o "$2" "$CHOMIKDL_SCRIPTS_URL/misc/$1"
    chmod "$3" "$2"
  fi
}

msg_info "Installing Dependencies"
# libatomic1: Playwright's bundled node needs it; hostname: `hostname -I`
# gives the default PUBLIC_URL.
$STD apt-get install -y python3 python3-venv git sqlite3 curl ca-certificates whiptail libatomic1 hostname
msg_ok "Installed Dependencies"

msg_info "Installing chomik-dl helpers"
mkdir -p /usr/local/lib/chomik-dl
fetch_misc chomik-dl-lib.sh /usr/local/lib/chomik-dl/chomik-dl-lib.sh 644
fetch_misc chomik-dl-settings /usr/local/bin/chomik-dl-settings 755
fetch_misc chomik-dl.service /etc/systemd/system/chomik-dl.service 644
# shellcheck source-path=SCRIPTDIR source=../misc/chomik-dl-lib.sh
source /usr/local/lib/chomik-dl/chomik-dl-lib.sh

# The app user owns files on the NAS share, so its UID/GID must be 1000.
if ! id -u "$CD_USER" &>/dev/null; then
  if getent group "$CD_UID" >/dev/null || getent passwd "$CD_UID" >/dev/null; then
    msg_error "UID/GID $CD_UID is already taken by another account; chomik-dl needs it for the user $CD_USER."
    exit 1
  fi
  groupadd --gid "$CD_UID" "$CD_USER"
  # SYS_UID_MAX: a system account above the usual system range, without a warning.
  useradd --system -K SYS_UID_MAX="$CD_UID" --uid "$CD_UID" --gid "$CD_UID" --home-dir "$CD_DATA_DIR" --no-create-home \
    --shell /usr/sbin/nologin "$CD_USER"
fi
install -d -o "$CD_USER" -g "$CD_USER" -m 750 "$CD_DATA_DIR"
install -d -o root -g "$CD_USER" -m 750 "$(dirname "$CHOMIKDL_ENV")"
# Never chown an existing download folder (it may be a mounted NAS share).
if [[ ! -e "$CD_DOWNLOAD_DIR" ]]; then
  install -d -o "$CD_USER" -g "$CD_USER" -m 755 "$CD_DOWNLOAD_DIR"
fi
msg_ok "Installed chomik-dl helpers"

# Prompts (or defaults when unattended / no terminal); writes the settings file.
cd_collect_settings
cd_write_fixed_settings
msg_ok "Saved settings to $CHOMIKDL_ENV"

msg_info "Installing chomik-dl (Python packages and Chromium, this takes a few minutes)"
if [[ -n "${CHOMIKDL_SOURCE_DIR:-}" ]]; then
  CHOMIKDL_REF=local
elif [[ -z "${CHOMIKDL_REF:-}" ]]; then
  channel="$(cd_settings_get CHOMIKDL_CHANNEL)" || channel=main
  rc=0
  CHOMIKDL_REF="$(cd_latest_ref "${channel:-main}")" || rc=$?
  if [[ $rc == 2 ]]; then
    echo "No release yet; installing the main branch instead."
    rc=0
    CHOMIKDL_REF="$(cd_latest_ref main)" || rc=$?
  fi
  if [[ $rc != 0 ]]; then
    msg_error "Could not find the version to install on GitHub."
    exit 1
  fi
fi
# Re-run on an existing install: the code dir is swapped, so stop the app first.
was_running=0
if systemctl is-active --quiet "$CD_SERVICE" 2>/dev/null; then
  was_running=1
  systemctl stop "$CD_SERVICE"
fi
# Long steps run shielded from SIGHUP: closing the console must not kill pip.
if ! cd_shielded cd_install_ref "$CHOMIKDL_REF" "$CD_APP_DIR"; then
  # cd_install_ref left the old code in place: bring the old app back up.
  if [[ $was_running == 1 ]]; then
    cd_service start || true
  fi
  msg_error "Installing chomik-dl $CHOMIKDL_REF failed; the previous installation was left in place."
  exit 1
fi
echo "$CHOMIKDL_REF" >"$CD_VERSION_FILE"
msg_ok "Installed chomik-dl $CHOMIKDL_REF"

have_credentials=0
cd_has_credentials && have_credentials=1

if [[ $have_credentials == 1 ]]; then
  msg_info "Starting chomik-dl"
  systemctl daemon-reload
  systemctl reset-failed "$CD_SERVICE" 2>/dev/null || true
  systemctl enable -q --now "$CD_SERVICE"
  cd_health 90
  msg_ok "Started chomik-dl"
  # The admin token is created on first use; the link goes to a 600 file.
  cd_write_creds
else
  systemctl daemon-reload
  systemctl disable -q "$CD_SERVICE" 2>/dev/null || true
  msg_warn "No chomikuj.pl login/password set; chomik-dl is installed but not started."
  # Best effort: the token and link can already be created without them.
  cd_write_creds 2>/dev/null || true
fi

motd_ssh
customize
# customize() wrote /usr/bin/update with another slug; ours keeps the
# community-scripts catalogue's status for other apps away from our updates.
cd_write_update_entrypoint || msg_warn "Could not write /usr/bin/update; run updates with: bash -c \"\$(curl -fsSL ${CHOMIKDL_SCRIPTS_URL}/ct/chomik-dl.sh)\""
cleanup_lxc

if [[ $have_credentials == 1 ]]; then
  echo -e "${INFO:-}${YW:-} chomik-dl is running on $(cd_settings_get PUBLIC_URL)${CL:-}"
  if [[ -t 1 && "${_CS_HANGUP:-0}" != 1 ]] && admin_link="$(sed -n 's/^Admin link: //p' "$CD_CREDS_FILE" 2>/dev/null | head -n 1)" && [[ -n "$admin_link" ]]; then
    # Only onto a live terminal: after a console hangup the engine sends this
    # output to its install log, and the link is a login.
    echo -e "${INFO:-}${YW:-} Open the admin link to manage downloads (also saved in $CD_CREDS_FILE):${CL:-}"
    echo -e "${TAB:-   }Admin link: ${admin_link}"
  else
    echo -e "${INFO:-}${YW:-} The admin link is in $CD_CREDS_FILE (cat $CD_CREDS_FILE)${CL:-}"
  fi
else
  echo -e "${INFO:-}${YW:-} chomik-dl is NOT running yet: enter your chomikuj.pl login and password with: chomik-dl-settings${CL:-}"
fi
echo -e "${INFO:-}${YW:-} Change settings any time with: chomik-dl-settings${CL:-}"
echo -e "${INFO:-}${YW:-} Attach your NAS folder at /data (see README) — downloads are refused until it is mounted.${CL:-}"
