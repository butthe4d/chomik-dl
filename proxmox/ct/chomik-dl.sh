#!/usr/bin/env bash
# Engine (community-scripts/core) pinned to a known-good commit; to move the
# pin, change the sha here and CD_CORE_URL_DEFAULT in misc/chomik-dl-lib.sh,
# then run the container tests. Both bases can be overridden from the
# environment, like upstream ct scripts.
COMMUNITY_SCRIPTS_CORE_URL="${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/665635b6aff5cf1486400d47e6c5aa38f9ba333d}"
COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/butthe4d/chomik-dl/main/proxmox}"
export COMMUNITY_SCRIPTS_CORE_URL COMMUNITY_SCRIPTS_URL
# A local engine only when asked for (COMMUNITY_SCRIPTS_CORE_DIR) or next to
# this script run as a file (a checkout); run as `bash -c "$(curl ...)"` there
# is no file, and a path relative to the current directory must never be
# sourced as root. Otherwise always the pinned remote engine.
_cs_self="${BASH_SOURCE[0]:-}"
if [[ -n "${COMMUNITY_SCRIPTS_CORE_DIR:-}" ]]; then
  _cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR%/}/core/build.func"
elif [[ -n "$_cs_self" && -f "$_cs_self" && -f "$(dirname "$_cs_self")/../../core/core/build.func" ]]; then
  _cs_boot="$(dirname "$_cs_self")/../../core/core/build.func"
else
  _cs_boot=""
fi
if [[ -n "$_cs_boot" ]]; then
  # shellcheck source=/dev/null
  source "$_cs_boot" || exit 1
else
  # shellcheck source=/dev/null
  source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL}/core/build.func")
fi
# Copyright (c) 2026 butthe4d
# License: Apache-2.0 | https://github.com/butthe4d/chomik-dl/raw/main/LICENSE
# Source: https://github.com/butthe4d/chomik-dl

APP="chomik-dl"
# Our own slug keeps the community-scripts catalogue's status and advisories
# for other apps away from this script (see the lib).
export SCRIPT_SLUG="butthe4d-chomik-dl"
# Repository for the GitHub link in the container's notes (backend.func description()).
export REPO_SLUG="butthe4d/chomik-dl"
var_tags="${var_tags:-chomik-dl}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1536}"
var_disk="${var_disk:-6}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local lib=/usr/local/lib/chomik-dl/chomik-dl-lib.sh
  if [[ ! -f /opt/chomik-dl_version.txt || ! -f "$lib" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi
  # The logic lives in the container's lib (tested without the engine).
  # shellcheck source=../misc/chomik-dl-lib.sh
  source "$lib"
  if ! cd_has_credentials; then
    msg_error "No chomikuj.pl login/password is configured, so chomik-dl cannot be updated or started. Run chomik-dl-settings first."
    exit 1
  fi
  local rc=0
  cd_update || rc=$?
  if [[ $rc -eq 0 ]]; then
    msg_ok "Done"
  else
    msg_error "Update did not complete (see the messages above)."
  fi
  exit "$rc"
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW} Admin link: run \`cat /root/chomik-dl.creds\` in the container${CL}"
echo -e "${TAB}${BGN}pct exec ${CTID} -- cat /root/chomik-dl.creds${CL}"
echo -e "${INFO}${YW} Attach your NAS folder (downloads are refused until /data is a mount):${CL}"
echo -e "${TAB}${BGN}pct set ${CTID} -mp0 <host-path>,mp=/data${CL}"
echo -e "${INFO}${YW} Change settings in the container with: chomik-dl-settings${CL}"
