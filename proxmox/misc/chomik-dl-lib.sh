#!/usr/bin/env bash
# chomik-dl helper library for the Proxmox LXC install (community-scripts style).
# Installed at /usr/local/lib/chomik-dl/chomik-dl-lib.sh and sourced by the
# install script, `chomik-dl-settings` and the update routine. It only defines
# functions and variables; it never changes shell options.
#
# Settings file format (/etc/chomik-dl/chomik-dl.env, read by systemd's
# EnvironmentFile= and by cd_settings_get, never sourced or eval'd here):
#   one KEY=value per line, value quoted as
#   - 'value'  when it contains no single quote: everything literal;
#   - "value"  otherwise, with \ " $ ` escaped by a backslash.
# The usual shell idiom 'it'\''s' is NOT used: systemd (checked on 257) stops
# treating quotes as quotes after the first closing one, so it reads that as
# it''\''s'. Both forms above read identically in systemd and in a POSIX
# shell. Newlines and carriage returns cannot be represented and are rejected.

CHOMIKDL_ENV="${CHOMIKDL_ENV:-/etc/chomik-dl/chomik-dl.env}"
CD_USER="${CD_USER:-chomik-dl}"
# shellcheck disable=SC2034 # used by the install script
CD_UID=1000
CD_APP_DIR="${CD_APP_DIR:-/opt/chomik-dl}"
CD_BROWSERS_DIR="${CD_BROWSERS_DIR:-/opt/chomik-dl-browsers}"
CD_DATA_DIR="${CD_DATA_DIR:-/var/lib/chomik-dl}"
CD_DOWNLOAD_DIR="${CD_DOWNLOAD_DIR:-/data}"
CD_BACKUP_DIR="${CD_BACKUP_DIR:-/var/backups/chomik-dl}"
CD_VERSION_FILE="${CD_VERSION_FILE:-/opt/chomik-dl_version.txt}"
CD_CREDS_FILE="${CD_CREDS_FILE:-/root/chomik-dl.creds}"
CD_SERVICE="${CD_SERVICE:-chomik-dl}"
CD_PORT=8080
CD_HEALTH_URL="http://127.0.0.1:$CD_PORT/healthz"
CD_DEFAULT_REPO="butthe4d/chomik-dl"
CD_KEEP_BACKUPS=3
CD_LIB_FILE="${CD_LIB_FILE:-/usr/local/lib/chomik-dl/chomik-dl-lib.sh}"
CD_SETTINGS_CMD="${CD_SETTINGS_CMD:-/usr/local/bin/chomik-dl-settings}"
CD_UPDATE_ENTRYPOINT="${CD_UPDATE_ENTRYPOINT:-/usr/bin/update}"
CD_UNIT_FILE="${CD_UNIT_FILE:-/etc/systemd/system/chomik-dl.service}"
# Defaults for /usr/bin/update when the engine did not pass its bases in. The
# engine pin must match ct/chomik-dl.sh.
CD_SCRIPTS_URL_DEFAULT="https://raw.githubusercontent.com/butthe4d/chomik-dl/main/proxmox"
CD_CORE_URL_DEFAULT="https://raw.githubusercontent.com/community-scripts/core/665635b6aff5cf1486400d47e6c5aa38f9ba333d"
# Our own slug for the community-scripts website/database lookups, so that
# advisories or a disabled state for some other app never apply to us.
# Unknown slugs update normally.
CD_SCRIPT_SLUG="butthe4d-chomik-dl"

# Settings the user chooses (prompted at install, offered by
# chomik-dl-settings), in file order.
CD_USER_KEYS=(
  CHOMIKUJ_LOGIN CHOMIKUJ_PASSWORD PUBLIC_URL ALLOWED_HOSTS
  MIN_JOB_GAP_SECONDS HUMAN_PAUSE_MIN HUMAN_PAUSE_MAX CHOMIKDL_CHANNEL
)
# Settings fixed by the container layout (cd_write_fixed_settings).
CD_FIXED_KEYS=(DATA_DIR DOWNLOAD_DIR DOWNLOAD_REQUIRE_MOUNT PLAYWRIGHT_BROWSERS_PATH HEADLESS)
# Every key the settings file may hold, in file order.
CD_KEYS=("${CD_USER_KEYS[@]}" "${CD_FIXED_KEYS[@]}")

cd_err() { printf '%s\n' "$*" >&2; }

cd_is_key() {
  local k
  for k in "${CD_KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Settings file
# ---------------------------------------------------------------------------

# Quote a value for the settings file (see the format note at the top).
cd_quote() {
  local v="$1" out="" c i
  if [[ "$v" != *"'"* ]]; then
    printf "'%s'" "$v"
    return 0
  fi
  for ((i = 0; i < ${#v}; i++)); do
    c="${v:i:1}"
    case "$c" in
    '\' | '"' | '$' | '`') out+="\\$c" ;;
    *) out+="$c" ;;
    esac
  done
  printf '"%s"' "$out"
}

# Decode the right-hand side of one settings line. Mirrors systemd's parser
# for the forms cd_quote writes, plus bare words (hand edits).
cd_unquote() {
  local raw="$1" out="" c i n
  n=${#raw}
  case "$raw" in
  "'"*)
    raw="${raw#\'}"
    printf '%s' "${raw%%\'*}"
    ;;
  '"'*)
    for ((i = 1; i < n; i++)); do
      c="${raw:i:1}"
      if [[ "$c" == '\' ]]; then
        i=$((i + 1))
        c="${raw:i:1}"
        case "$c" in
        '\' | '"' | '$' | '`') out+="$c" ;;
        *) out+="\\$c" ;;
        esac
      elif [[ "$c" == '"' ]]; then
        break
      else
        out+="$c"
      fi
    done
    printf '%s' "$out"
    ;;
  *)
    # Unquoted: systemd strips surrounding whitespace.
    raw="${raw#"${raw%%[![:space:]]*}"}"
    printf '%s' "${raw%"${raw##*[![:space:]]}"}"
    ;;
  esac
}

# cd_settings_get KEY: print the value; status 1 if the key is not in the file.
cd_settings_get() {
  local key="$1" line
  [[ -r "$CHOMIKDL_ENV" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      cd_unquote "${line#"$key"=}"
      return 0
    fi
  done <"$CHOMIKDL_ENV"
  return 1
}

# cd_settings_set KEY VALUE: validate, then replace (or append) the line
# atomically under the maintenance lock, keeping the file root:chomik-dl 640.
cd_settings_set() {
  cd_validate "$1" "$2" || return 1
  cd_with_lock _cd_settings_write "$1" "$2"
}

_cd_settings_write() {
  local key="$1" value="$2" dir tmp line done=0
  dir="$(dirname "$CHOMIKDL_ENV")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.chomik-dl.env.XXXXXX")" || return 1
  {
    if [[ -f "$CHOMIKDL_ENV" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
          [[ $done == 0 ]] && printf '%s=%s\n' "$key" "$(cd_quote "$value")"
          done=1
        else
          printf '%s\n' "$line"
        fi
      done <"$CHOMIKDL_ENV"
    fi
    [[ $done == 1 ]] || printf '%s=%s\n' "$key" "$(cd_quote "$value")"
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  cd_secure_env_file "$tmp" && mv -f "$tmp" "$CHOMIKDL_ENV"
}

# cd_write_fixed_settings: the settings the container layout fixes.
cd_write_fixed_settings() {
  cd_settings_set DATA_DIR "$CD_DATA_DIR" &&
    cd_settings_set DOWNLOAD_DIR "$CD_DOWNLOAD_DIR" &&
    cd_settings_set DOWNLOAD_REQUIRE_MOUNT true &&
    cd_settings_set PLAYWRIGHT_BROWSERS_PATH "$CD_BROWSERS_DIR" &&
    cd_settings_set HEADLESS true
}

# cd_has_credentials: status 0 when the settings file has a chomikuj.pl login
# and password (the app does not start without them).
cd_has_credentials() {
  local v
  v="$(cd_settings_get CHOMIKUJ_LOGIN 2>/dev/null)" && [[ -n "$v" ]] &&
    v="$(cd_settings_get CHOMIKUJ_PASSWORD 2>/dev/null)" && [[ -n "$v" ]]
}

# cd_with_lock CMD...: run CMD holding the chomik-dl maintenance lock
# (flock on /run/chomik-dl/maintenance.lock; CD_LOCK_FILE overrides). Settings
# writes, backup/restore and code swaps all take it; nested calls in the same
# process tree just run CMD. The lock lives in a root-only directory: any
# user who can open the file could flock it forever and block maintenance.
cd_with_lock() {
  if [[ "${CD_LOCK_HELD:-0}" == 1 ]]; then
    "$@"
    return
  fi
  local lock="${CD_LOCK_FILE:-/run/chomik-dl/maintenance.lock}" dir
  dir="$(dirname "$lock")"
  (umask 077 && mkdir -p "$dir") || return 1
  if [[ $EUID -eq 0 && ( -L "$dir" || "$(stat -c '%u %a' "$dir")" != "0 700" ) ]]; then
    cd_err "Refusing to use lock directory $dir: it must be a root-owned 0700 directory."
    return 1
  fi
  local caller_umask
  caller_umask="$(umask)"
  (
    # 077 only for creating the lock file: CMD runs with the caller's umask
    # (a venv built under 077 would be unreadable for the app user).
    umask 077
    exec 9>>"$lock" || exit 1
    umask "$caller_umask"
    if [[ -L "$lock" || ! -O "$lock" || "$(stat -c '%a' "$lock")" != 600 ]]; then
      cd_err "Refusing to use lock file $lock: it must be a regular file owned by $(id -un) with mode 600."
      exit 1
    fi
    if ! flock -w "${CD_LOCK_TIMEOUT:-600}" 9; then
      cd_err "Another chomik-dl maintenance task is running (lock $lock)."
      exit 1
    fi
    export CD_LOCK_HELD=1
    "$@"
  )
}

# cd_as_app_user CMD...: run CMD as the app user (keeps the environment).
# Use it for every write into the data dir, which that user owns: a root
# write there could be redirected by a symlink the app user planted.
cd_as_app_user() {
  (cd / && exec setpriv --reuid="$CD_USER" --regid="$CD_USER" --init-groups "$@")
}

cd_secure_env_file() {
  chmod 640 "$1" || return 1
  if [[ $EUID -eq 0 ]] && getent group "$CD_USER" >/dev/null; then
    chown "root:$CD_USER" "$1" || return 1
  fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

_cd_is_number() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
_cd_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'; }

# cd_validate KEY VALUE: 0 if VALUE is acceptable for KEY, else 1 with a
# message (naming KEY) on stderr. HUMAN_PAUSE_MIN/MAX are also checked
# against the other one's value in the settings file.
cd_validate() {
  local key="$1" value="$2" other host
  if ! cd_is_key "$key"; then
    cd_err "Unknown setting: $key"
    return 1
  fi
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    cd_err "$key: line breaks are not allowed."
    return 1
  fi
  case "$key" in
  CHOMIKUJ_LOGIN | CHOMIKUJ_PASSWORD)
    [[ -n "$value" ]] || { cd_err "$key must not be empty."; return 1; }
    ;;
  PUBLIC_URL)
    [[ "$value" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ && "$value" != */ ]] ||
      { cd_err "PUBLIC_URL must start with http:// or https:// and not end with /, e.g. http://192.168.1.10:8080"; return 1; }
    ;;
  ALLOWED_HOSTS)
    local -a hosts=()
    IFS=, read -r -a hosts <<<"$value"
    for host in "${hosts[@]}"; do
      host="${host//[[:space:]]/}"
      [[ -z "$host" || "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] ||
        { cd_err "ALLOWED_HOSTS must be host names separated by commas (e.g. chomik.lan,nas.lan), got: $host"; return 1; }
    done
    ;;
  MIN_JOB_GAP_SECONDS | HUMAN_PAUSE_MIN | HUMAN_PAUSE_MAX)
    _cd_is_number "$value" || { cd_err "$key must be a number of seconds, 0 or more (e.g. 20 or 1.5)."; return 1; }
    if [[ "$key" == HUMAN_PAUSE_MIN ]] && other="$(cd_settings_get HUMAN_PAUSE_MAX 2>/dev/null)" &&
      _cd_is_number "$other" && ! _cd_le "$value" "$other"; then
      cd_err "HUMAN_PAUSE_MIN must not be greater than HUMAN_PAUSE_MAX ($other)."
      return 1
    fi
    if [[ "$key" == HUMAN_PAUSE_MAX ]] && other="$(cd_settings_get HUMAN_PAUSE_MIN 2>/dev/null)" &&
      _cd_is_number "$other" && ! _cd_le "$other" "$value"; then
      cd_err "HUMAN_PAUSE_MAX must not be less than HUMAN_PAUSE_MIN ($other)."
      return 1
    fi
    ;;
  CHOMIKDL_CHANNEL)
    [[ "$value" == main || "$value" == releases ]] ||
      { cd_err "CHOMIKDL_CHANNEL must be main or releases."; return 1; }
    ;;
  DATA_DIR | DOWNLOAD_DIR | PLAYWRIGHT_BROWSERS_PATH)
    [[ "$value" == /* ]] || { cd_err "$key must be an absolute path."; return 1; }
    ;;
  DOWNLOAD_REQUIRE_MOUNT | HEADLESS)
    [[ "$value" == true || "$value" == false ]] || { cd_err "$key must be true or false."; return 1; }
    ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Prompts: whiptail on a terminal, plain `read` otherwise. CHOMIKDL_ANSWERS
# names a file of answers (one per line, empty line = default) that replaces
# the terminal, for scripted runs and tests. Prompts never fail the caller:
# Cancel, Esc, end of input and timeouts all keep the default.
# ---------------------------------------------------------------------------

CD_BACKTITLE="chomik-dl"
# Timeouts (seconds, read when asking): CHOMIKDL_PROMPT_TIMEOUT (default 60)
# for the first install question (the login), after which the install stops
# asking; CHOMIKDL_FIELD_TIMEOUT (default 300) for every other question, which
# then keeps its default.
cd_prompt_timeout() { printf '%s' "${CHOMIKDL_PROMPT_TIMEOUT:-60}"; }
cd_field_timeout() { printf '%s' "${CHOMIKDL_FIELD_TIMEOUT:-300}"; }

# Prints where answers come from; status 1 when nobody can answer.
cd_answer_source() {
  if [[ -n "${CHOMIKDL_ANSWERS:-}" ]]; then
    printf '%s' "$CHOMIKDL_ANSWERS"
  elif { : </dev/tty; } 2>/dev/null; then
    printf '%s' /dev/tty
  else
    return 1
  fi
}

cd_can_prompt() { cd_answer_source >/dev/null; }

cd_use_whiptail() {
  [[ -z "${CHOMIKDL_ANSWERS:-}" && "${TERM:-dumb}" != dumb ]] && command -v whiptail >/dev/null 2>&1 &&
    cd_can_prompt
}

# Keep one descriptor open on the answer source so successive reads advance.
# Call it in the main shell before prompting: the prompt helpers run inside
# $(...), and a descriptor opened there would start from the top every time.
cd_open_answers() {
  local src
  src="$(cd_answer_source)" || return 1
  if [[ -n "${CD_ANSWER_FD:-}" ]]; then
    [[ "$src" == "${CD_ANSWER_SRC:-}" ]] && return 0
    exec {CD_ANSWER_FD}<&-
  fi
  exec {CD_ANSWER_FD}<"$src"
  CD_ANSWER_SRC="$src"
}

# cd_read_line VAR [silent] [timeout]: status 1 on end of input or timeout.
cd_read_line() {
  cd_open_answers || return 1
  local _line
  local -a _opts=(-r -u "$CD_ANSWER_FD")
  [[ -n "${3:-}" ]] && _opts+=(-t "$3")
  [[ "${2:-}" == silent && -z "${CHOMIKDL_ANSWERS:-}" ]] && _opts+=(-s)
  if ! IFS= read "${_opts[@]}" _line; then
    echo >&2
    return 1
  fi
  [[ "${2:-}" == silent && -z "${CHOMIKDL_ANSWERS:-}" ]] && echo >&2
  printf -v "$1" '%s' "$_line"
}

# cd_whiptail TIMEOUT ARGS...: whiptail on the terminal; prints its answer.
# Status: whiptail's (0 ok, 1 cancel/no, 255 Esc) or 124 on timeout.
cd_whiptail() {
  local t="$1" rc=0
  shift
  timeout --foreground "$t" whiptail --backtitle "$CD_BACKTITLE" --title "chomik-dl" "$@" \
    2>&1 >/dev/tty </dev/tty || rc=$?
  if [[ $rc == 124 ]]; then
    # whiptail was killed mid-screen: give the terminal back in a sane state.
    stty sane </dev/tty 2>/dev/null || true
    printf '\033[0m\033[H\033[2J' >/dev/tty 2>/dev/null || true
  fi
  return "$rc"
}

# cd_show_message TEXT: a message box on a terminal, else stderr.
cd_show_message() {
  if cd_use_whiptail; then
    cd_whiptail "$(cd_field_timeout)" --scrolltext --msgbox "$1" 20 76 >/dev/null || true
  else
    cd_err "$1"
  fi
}

# cd_ask_yesno QUESTION [default y|n] [timeout]: status 0 for yes. Cancel,
# Esc, end of input and timeout give the default.
cd_ask_yesno() {
  local q="$1" def="${2:-n}" t="${3:-$(cd_field_timeout)}" ans rc=0
  if cd_use_whiptail; then
    local -a dflt=()
    [[ "$def" == n ]] && dflt=(--defaultno)
    cd_whiptail "$t" "${dflt[@]}" --yesno "$q" 14 74 >/dev/null || rc=$?
    case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) [[ "$def" == y ]]; return ;;
    esac
  fi
  while :; do
    printf '%s [%s] ' "$q" "$([[ "$def" == y ]] && echo Y/n || echo y/N)" >&2
    if ! cd_read_line ans "" "$t"; then
      [[ "$def" == y ]]
      return
    fi
    case "${ans,,}" in
    "") [[ "$def" == y ]]; return ;;
    y | yes) return 0 ;;
    n | no) return 1 ;;
    *) cd_err "Please answer y or n." ;;
    esac
  done
}

# cd_ask_input PROMPT DEFAULT [secret] [timeout]: prints the answer. "-"
# clears the value. Secret fields never show the current value (empty keeps
# it), not even on a command line. Status 1 (still printing DEFAULT) when the
# default was kept because of Cancel, Esc, end of input or timeout.
cd_ask_input() {
  local prompt="$1" def="$2" secret="${3:-}" t="${4:-$(cd_field_timeout)}" ans rc=0
  if cd_use_whiptail; then
    if [[ "$secret" == secret ]]; then
      ans="$(cd_whiptail "$t" --passwordbox \
        "$prompt"$'\n\n'"Leave empty to keep the current value; enter - to clear it." 14 74 "")" || rc=$?
      [[ $rc == 0 && -z "$ans" ]] && ans="$def"
    else
      ans="$(cd_whiptail "$t" --inputbox "$prompt"$'\n\n'"Enter - to clear the value." 14 74 "$def")" || rc=$?
    fi
    if [[ $rc != 0 ]]; then
      printf '%s' "$def"
      return 1
    fi
  else
    local hint="$def"
    [[ "$secret" == secret && -n "$def" ]] && hint="keep current"
    [[ -n "$def" ]] && hint+="; - clears"
    printf '%s [%s]: ' "$prompt" "$hint" >&2
    local mode=""
    [[ "$secret" == secret ]] && mode=silent
    if ! cd_read_line ans "$mode" "$t"; then
      printf '%s' "$def"
      return 1
    fi
    [[ -z "$ans" ]] && ans="$def"
  fi
  [[ "$ans" == - ]] && ans=""
  printf '%s' "$ans"
}

# cd_ask_setting KEY PROMPT DEFAULT [secret] [timeout]: asks until
# cd_validate accepts; prints the value. Cancel/timeout/end of input print
# DEFAULT with status 1.
cd_ask_setting() {
  local key="$1" prompt="$2" def="$3" secret="${4:-}" t="${5:-}" v msg
  while :; do
    if ! v="$(cd_ask_input "$prompt" "$def" "$secret" "$t")"; then
      printf '%s' "$def"
      return 1
    fi
    if msg="$(cd_validate "$key" "$v" 2>&1)"; then
      printf '%s' "$v"
      return 0
    fi
    if cd_use_whiptail; then
      cd_whiptail "$(cd_field_timeout)" --msgbox "$msg" 10 70 >/dev/null || true
    else
      cd_err "$msg"
    fi
  done
}

# cd_prompt_for KEY: the question shown for a user setting.
cd_prompt_for() {
  case "$1" in
  CHOMIKUJ_LOGIN) echo "Your chomikuj.pl login" ;;
  CHOMIKUJ_PASSWORD) echo "Your chomikuj.pl password" ;;
  PUBLIC_URL) echo "Address you open chomik-dl at (http:// or https://, no trailing /)" ;;
  ALLOWED_HOSTS) echo "Host names the page may also be opened by, comma-separated (IP addresses always work; empty for none)" ;;
  MIN_JOB_GAP_SECONDS) echo "Minimum seconds between two downloads" ;;
  HUMAN_PAUSE_MIN) echo "Shortest pause between browser actions (seconds)" ;;
  HUMAN_PAUSE_MAX) echo "Longest pause between browser actions (seconds)" ;;
  CHOMIKDL_CHANNEL) echo "Update channel: main (every commit) or releases (tagged releases)" ;;
  *) echo "$1" ;;
  esac
}

# Container address for the default PUBLIC_URL: first IPv4, else first IPv6
# (bracketed), else 127.0.0.1.
cd_container_ip() {
  local -a addrs=()
  local a
  read -r -a addrs <<<"$(hostname -I 2>/dev/null)" || true
  if [[ ${#addrs[@]} -eq 0 ]]; then
    read -r -a addrs <<<"$(ip -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); printf "%s ", a[1]}')" || true
  fi
  for a in "${addrs[@]}"; do
    [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$a"; return 0; }
  done
  for a in "${addrs[@]}"; do
    [[ "$a" == *:* ]] && { printf '[%s]' "$a"; return 0; }
  done
  printf '127.0.0.1'
}

cd_is_unattended() {
  [[ "${CHOMIKDL_UNATTENDED:-0}" == 1 || "${PHS_SILENT:-0}" == 1 ]] && return 0
  [[ "${var_unattended:-}" =~ ^(yes|true|1)$ || "${UNATTENDED:-}" =~ ^(yes|true|1)$ ]] && return 0
  # The engine's own "no questions" modes (MODE is exported into the
  # container). Its METHOD values carry suffixes ("mydefaults-global",
  # ui/defaults.func), so the names match as prefixes.
  [[ "${MODE:-}" =~ ^(mydefaults|userdefaults|appdefaults) || "${MODE:-}" =~ ^(3|4)$ ]] && return 0
  ! cd_can_prompt
}

# cd_collect_settings: write the user settings (fixed ones already in the
# file are kept), asking for them unless unattended. Defaults are the current
# settings when the file exists (re-run), else the documented ones; the
# chomikuj.pl login and password may come from CHOMIKDL_LOGIN and
# CHOMIKDL_PASSWORD (they win over the file). Without a login and password the
# rest is written and a message says how to add them later; the caller must
# then leave the service disabled (see cd_has_credentials). If nobody answers
# the login question within CHOMIKDL_PROMPT_TIMEOUT, no more questions follow.
cd_collect_settings() {
  local -A v=(
    [CHOMIKUJ_LOGIN]="" [CHOMIKUJ_PASSWORD]=""
    [PUBLIC_URL]="http://$(cd_container_ip):$CD_PORT" [ALLOWED_HOSTS]=""
    [MIN_JOB_GAP_SECONDS]=20 [HUMAN_PAUSE_MIN]=1.0 [HUMAN_PAUSE_MAX]=4.0
    [CHOMIKDL_CHANNEL]="${CHOMIKDL_CHANNEL:-main}"
  )
  local k cur
  for k in "${CD_USER_KEYS[@]}"; do
    if cur="$(cd_settings_get "$k" 2>/dev/null)"; then v[$k]="$cur"; fi
  done
  [[ -n "${CHOMIKDL_LOGIN:-}" ]] && v[CHOMIKUJ_LOGIN]="$CHOMIKDL_LOGIN"
  [[ -n "${CHOMIKDL_PASSWORD:-}" ]] && v[CHOMIKUJ_PASSWORD]="$CHOMIKDL_PASSWORD"

  if ! cd_is_unattended && cd_open_answers; then
    if v[CHOMIKUJ_LOGIN]="$(cd_ask_setting CHOMIKUJ_LOGIN "$(cd_prompt_for CHOMIKUJ_LOGIN)" \
      "${v[CHOMIKUJ_LOGIN]}" "" "$(cd_prompt_timeout)")"; then
      v[CHOMIKUJ_PASSWORD]="$(cd_ask_setting CHOMIKUJ_PASSWORD "$(cd_prompt_for CHOMIKUJ_PASSWORD)" \
        "${v[CHOMIKUJ_PASSWORD]}" secret)" || true
      for k in PUBLIC_URL ALLOWED_HOSTS; do
        v[$k]="$(cd_ask_setting "$k" "$(cd_prompt_for "$k")" "${v[$k]}")" || true
      done
      if cd_ask_yesno "Change the download pacing (advanced)?

Now: at least ${v[MIN_JOB_GAP_SECONDS]} s between downloads, ${v[HUMAN_PAUSE_MIN]}-${v[HUMAN_PAUSE_MAX]} s pauses between browser actions." n; then
        v[MIN_JOB_GAP_SECONDS]="$(cd_ask_setting MIN_JOB_GAP_SECONDS "$(cd_prompt_for MIN_JOB_GAP_SECONDS)" \
          "${v[MIN_JOB_GAP_SECONDS]}")" || true
        # Checked against each other below, not against the settings file.
        while :; do
          for k in HUMAN_PAUSE_MIN HUMAN_PAUSE_MAX; do
            v[$k]="$(CHOMIKDL_ENV=/dev/null cd_ask_setting "$k" "$(cd_prompt_for "$k")" "${v[$k]}")" || break 2
          done
          _cd_le "${v[HUMAN_PAUSE_MIN]}" "${v[HUMAN_PAUSE_MAX]}" && break
          cd_show_message "HUMAN_PAUSE_MIN must not be greater than HUMAN_PAUSE_MAX; enter both again."
        done
      fi
      v[CHOMIKDL_CHANNEL]="$(cd_ask_setting CHOMIKDL_CHANNEL "$(cd_prompt_for CHOMIKDL_CHANNEL)" \
        "${v[CHOMIKDL_CHANNEL]}")" || true
    else
      cd_err "No answer; skipping the remaining questions."
    fi
  fi

  local tmp missing=0
  tmp="$(mktemp "$(dirname "$CHOMIKDL_ENV")/.chomik-dl.env.new.XXXXXX")" || return 1
  for k in "${CD_USER_KEYS[@]}"; do
    if [[ -z "${v[$k]}" && ("$k" == CHOMIKUJ_LOGIN || "$k" == CHOMIKUJ_PASSWORD) ]]; then
      missing=1
      continue
    fi
    CHOMIKDL_ENV="$tmp" cd_settings_set "$k" "${v[$k]}" || { rm -f "$tmp"; return 1; }
  done
  for k in "${CD_FIXED_KEYS[@]}"; do
    if cur="$(cd_settings_get "$k" 2>/dev/null)"; then
      CHOMIKDL_ENV="$tmp" cd_settings_set "$k" "$cur" || { rm -f "$tmp"; return 1; }
    fi
  done
  cd_with_lock mv -f "$tmp" "$CHOMIKDL_ENV" || { rm -f "$tmp"; return 1; }
  if [[ $missing == 1 ]]; then
    cd_err "No chomikuj.pl login and password given: chomik-dl stays stopped until you set them with: chomik-dl-settings"
  fi
}

# ---------------------------------------------------------------------------
# Running the app
# ---------------------------------------------------------------------------

# cd_run_as_app CMD...: run CMD as the app user with exactly the settings-file
# environment (like the systemd unit), from the code dir. Values are exported
# by the shell, never passed on a command line (other users can read argv).
cd_run_as_app() {
  local -a keys=() vals=()
  local k v
  for k in "${CD_KEYS[@]}"; do
    if v="$(cd_settings_get "$k")"; then
      keys+=("$k")
      vals+=("$v")
    fi
  done
  (
    cd "$CD_APP_DIR" || exit 1
    while IFS= read -r k; do unset "$k" 2>/dev/null || true; done < <(compgen -e)
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin LANG=C.UTF-8 \
      HOME="$CD_DATA_DIR" USER="$CD_USER" LOGNAME="$CD_USER"
    for k in "${!keys[@]}"; do export "${keys[k]}=${vals[k]}"; done
    exec setpriv --reuid="$CD_USER" --regid="$CD_USER" --init-groups "$@"
  )
}

# cd_shielded CMD...: run CMD (command or function) through the engine's
# SIGHUP shield when it is loaded, so a closed console doesn't kill it.
cd_shielded() {
  if declare -F _cs_shield_hangup >/dev/null; then
    _cs_shield_hangup "$@"
  else
    "$@"
  fi
}

# cd_health [timeout_s]: wait until /healthz answers "ok".
cd_health() {
  local timeout="${1:-${CHOMIKDL_HEALTH_TIMEOUT:-30}}" end
  end=$((SECONDS + timeout))
  while :; do
    [[ "$(curl -fsS --max-time 3 "$CD_HEALTH_URL" 2>/dev/null)" == ok ]] && return 0
    ((SECONDS >= end)) && break
    sleep 1
  done
  cd_err "chomik-dl did not answer on $CD_HEALTH_URL within ${timeout}s."
  return 1
}

# cd_service start|restart|stop: run the action after clearing systemd's
# start rate limit (StartLimitBurst=5 per 120 s). Manual starts count towards
# it, so a few quick settings changes would otherwise make systemd refuse the
# next start (start-limit-hit), and the restore would be refused as well.
cd_service() {
  systemctl reset-failed "$CD_SERVICE" 2>/dev/null || true
  systemctl "$1" "$CD_SERVICE"
}

# cd_apply_settings NEW_FILE: install NEW_FILE as the settings file, enable,
# restart and health-check; on failure put the previous file back, restart
# (or stop, if the previous file had no credentials), print the service log
# and return 1. Holds the lock throughout.
cd_apply_settings() {
  cd_with_lock _cd_apply_settings "$@"
}

_cd_apply_settings() {
  local new="$1" old log
  if ! CHOMIKDL_ENV="$new" cd_has_credentials; then
    cd_err "Set both CHOMIKUJ_LOGIN and CHOMIKUJ_PASSWORD; nothing was saved."
    return 1
  fi
  old="$(mktemp "$(dirname "$CHOMIKDL_ENV")/.chomik-dl.env.prev.XXXXXX")" || return 1
  cp -p "$CHOMIKDL_ENV" "$old" || return 1
  cd_secure_env_file "$new" && mv -f "$new" "$CHOMIKDL_ENV" || { rm -f "$old"; return 1; }
  if cd_service restart && cd_health; then
    rm -f "$old"
    # The install leaves the service disabled until the credentials are set.
    systemctl enable -q "$CD_SERVICE" 2>/dev/null || true
    return 0
  fi
  log="$(journalctl -u "$CD_SERVICE" -n 20 --no-pager 2>&1)"
  mv -f "$old" "$CHOMIKDL_ENV"
  cd_err "chomik-dl failed to start with the new settings; the previous settings were restored."
  cd_err "Last log lines:"
  cd_err "$log"
  if cd_has_credentials; then
    cd_service restart || true
    cd_health >/dev/null 2>&1 || cd_err "Warning: chomik-dl is not healthy with the restored settings either."
  else
    systemctl stop "$CD_SERVICE" 2>/dev/null || true
  fi
  return 1
}

# _cd_admin_link [--regenerate]: run `python -m app.admin` as the app user
# and save the link it prints to CD_CREDS_FILE (600). Prints nothing: the
# link is a login, and output can end up in logs.
_cd_admin_link() {
  local out link
  if ! out="$(cd_run_as_app "$CD_APP_DIR/.venv/bin/python" -m app.admin "$@")"; then
    cd_err "Could not create the admin link (python -m app.admin failed)."
    return 1
  fi
  link="${out%%$'\n'*}" # app.admin prints the link first
  unset out
  if [[ ! "$link" =~ ^https?://[^[:space:]]+/admin/[^[:space:]/]+$ ]]; then
    cd_err "python -m app.admin printed no usable admin link; is PUBLIC_URL set?"
    return 1
  fi
  (
    umask 077
    printf '# chomik-dl: open this link to manage downloads. Keep it private.\nAdmin link: %s\n' \
      "$link" >"$CD_CREDS_FILE"
  ) && chmod 600 "$CD_CREDS_FILE"
}

# cd_write_creds: save the current admin link (creating the token on the
# first run) to CD_CREDS_FILE.
cd_write_creds() { _cd_admin_link; }

# cd_regenerate_admin: invalidate the admin link, save the new one.
cd_regenerate_admin() { _cd_admin_link --regenerate; }

# ---------------------------------------------------------------------------
# Code install
# ---------------------------------------------------------------------------

cd_repo() { printf '%s' "${CHOMIKDL_REPO:-$CD_DEFAULT_REPO}"; }

# cd_install_ref REF TARGET_DIR: cd_build_ref, then swap TARGET_DIR.new in;
# the previous TARGET_DIR is kept as TARGET_DIR.prev. Prints nothing on
# success; on failure prints the build log tail and leaves TARGET_DIR alone.
cd_install_ref() {
  cd_build_ref "$@" || return 1
  local target="${2%/}"
  cd_with_lock _cd_swap_dirs "$target.new" "$target"
}

# cd_build_ref REF TARGET_DIR: check out REF (commit sha or tag) from GitHub
# with git, or copy $CHOMIKDL_SOURCE_DIR (tests; REF is then only recorded),
# into TARGET_DIR.new; build a venv there with the app and install the
# matching Playwright Chromium (and its system packages) into
# CD_BROWSERS_DIR. The live TARGET_DIR is not touched, so this can run while
# the app is up. Run the venv only as `.venv/bin/python -m ...`: its console
# scripts keep the .new path in their #! line, while bin/python is a symlink
# to the system interpreter and works from the moved venv.
cd_build_ref() {
  local ref="$1" target="${2%/}" stage log url rc=0
  if [[ ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ || "$ref" == *..* ]]; then
    cd_err "Invalid ref: $ref"
    return 1
  fi
  [[ -n "$target" && "$target" == /* ]] || { cd_err "Target must be an absolute path."; return 1; }
  stage="$target.new"
  rm -rf "$stage" && mkdir -p "$stage" || return 1
  log="$(mktemp)" || return 1
  (
    set -o pipefail
    if [[ -n "${CHOMIKDL_SOURCE_DIR:-}" ]]; then
      tar -C "$CHOMIKDL_SOURCE_DIR" --exclude=./.git --exclude=./.venv --exclude='*.egg-info' \
        --exclude=__pycache__ --exclude=./.superpowers --exclude=./.pytest_cache --exclude='*.db' -cf - . |
        tar -C "$stage" -xf -
    else
      url="https://github.com/$(cd_repo).git"
      git -C "$stage" init -q &&
        git -C "$stage" fetch -q --depth 1 "$url" "$ref" &&
        git -C "$stage" -c advice.detachedHead=false checkout -q FETCH_HEAD
    fi
  ) >>"$log" 2>&1 || rc=1
  if [[ $rc == 0 && ! -f "$stage/pyproject.toml" ]]; then
    echo "No pyproject.toml in the checked out source." >>"$log"
    rc=1
  fi
  if [[ $rc == 0 ]]; then
    # Chained with &&: `set -e` would be ignored here (this runs on the left
    # of ||), so a failed step would not stop the build.
    (
      export PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PIP_NO_CACHE_DIR=1 \
        DEBIAN_FRONTEND=noninteractive PLAYWRIGHT_BROWSERS_PATH="$CD_BROWSERS_DIR"
      python3 -m venv "$stage/.venv" &&
        "$stage/.venv/bin/python" -m pip install -q "$stage" &&
        "$stage/.venv/bin/python" -m playwright install --with-deps chromium &&
        "$stage/.venv/bin/python" -c "import app.main"
    ) >>"$log" 2>&1 || rc=1
  fi
  if [[ $rc != 0 ]]; then
    cd_err "Installing chomik-dl $ref failed:"
    tail -n 30 "$log" >&2
    rm -rf "$stage" "$log"
    return 1
  fi
  rm -f "$log"
  if ! { chown -R root:root "$stage" && chmod 755 "$stage"; }; then
    rm -rf "$stage"
    return 1
  fi
}

# Move TARGET to TARGET.prev and STAGE to TARGET; on failure put TARGET back.
_cd_swap_dirs() {
  local stage="$1" target="$2" had=0
  if [[ -e "$target" ]]; then
    had=1
    if ! { rm -rf "$target.prev" && mv -T "$target" "$target.prev"; }; then
      cd_err "Could not move $target aside."
      rm -rf "$stage"
      return 1
    fi
  fi
  if ! mv -T "$stage" "$target"; then
    cd_err "Could not move the new code into $target."
    if [[ $had == 1 && ! -e "$target" ]]; then mv -T "$target.prev" "$target" || true; fi
    rm -rf "$stage"
    return 1
  fi
}

# _cd_gh_get URL: GET a GitHub API URL and print the body. Status: 0 for
# 200, 4 for 404, 3 when the API rate limit is hit (403/429 with
# x-ratelimit-remaining: 0 or retry-after), 1 for anything else.
_cd_gh_get() {
  local url="$1" body hdr code rc=1
  body="$(mktemp)" || return 1
  hdr="$(mktemp)" || {
    rm -f "$body"
    return 1
  }
  code="$(curl -sSL --max-time 20 -H 'Accept: application/vnd.github+json' \
    -D "$hdr" -o "$body" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
  case "$code" in
  200) cat "$body" && rc=0 ;;
  404) rc=4 ;;
  403 | 429)
    if grep -qiE '^(x-ratelimit-remaining:[[:space:]]*0[[:space:]]*$|retry-after:)' "$hdr"; then rc=3; fi
    ;;
  esac
  rm -f "$body" "$hdr"
  return "$rc"
}

# Message for a failed _cd_gh_get (status $1) about WHAT ($2).
_cd_gh_fail() {
  if [[ "$1" == 3 ]]; then
    cd_err "GitHub API rate limit reached, try again later."
  else
    cd_err "Could not read $2 from GitHub."
  fi
}

# cd_latest_ref CHANNEL: print the newest commit sha on main (main), or the
# newest release tag (releases); a repo without releases (404) falls back to
# the newest tag. Status 2, printing nothing, when the repo has neither
# releases nor tags. Any other error (rate limit, server error, no network)
# fails with status 1: falling back then could pick an older tag than the
# latest release. CHOMIKDL_GITHUB_API replaces the API base (tests).
cd_latest_ref() {
  local channel="$1" api="${CHOMIKDL_GITHUB_API:-https://api.github.com}" repo json ref rc=0
  repo="$(cd_repo)"
  case "$channel" in
  main)
    json="$(_cd_gh_get "$api/repos/$repo/commits/main")" || {
      _cd_gh_fail $? "the latest commit of $repo"
      return 1
    }
    ref="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin)["sha"])' <<<"$json" 2>/dev/null)"
    ;;
  releases)
    json="$(_cd_gh_get "$api/repos/$repo/releases/latest")" || rc=$?
    if [[ $rc == 0 ]]; then
      ref="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])' <<<"$json" 2>/dev/null)"
    elif [[ $rc == 4 ]]; then
      json="$(_cd_gh_get "$api/repos/$repo/tags")" || {
        _cd_gh_fail $? "the tags of $repo"
        return 1
      }
      # An empty list: no release yet. Prints "-" so it can't look like a tag.
      ref="$(python3 -I -c 'import json, sys; t = json.load(sys.stdin); print(t[0]["name"] if t else "-")' <<<"$json" 2>/dev/null)"
      [[ "$ref" == - ]] && return 2
    else
      _cd_gh_fail "$rc" "the latest release of $repo"
      return 1
    fi
    ;;
  *)
    cd_err "Unknown update channel: $channel (use main or releases)"
    return 1
    ;;
  esac
  [[ -n "${ref:-}" ]] || { cd_err "GitHub answered without a usable version for $repo ($channel)."; return 1; }
  printf '%s\n' "$ref"
}

# ---------------------------------------------------------------------------
# Backups: database (sqlite .backup), admin token and link, browser profile,
# settings, version, unit.
# ---------------------------------------------------------------------------

# The data-dir entries kept in a backup's state.tar besides the database.
CD_STATE_FILES=(admin-token admin-link.txt browser)

# cd_backup: print the new backup directory (root-only). It also keeps the
# systemd unit, which an update may replace. Everything in the data dir is
# read by the app user (sqlite creates WAL files, which must stay the app
# user's; and root must not read a path the app user controls).
cd_backup() { cd_with_lock _cd_backup; }

_cd_backup() {
  local dir db="$CD_DATA_DIR/jobs.db" tmp n
  local -a names=()
  mkdir -p "$CD_BACKUP_DIR" && chmod 700 "$CD_BACKUP_DIR" || return 1
  dir="$(mktemp -d "$CD_BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ).XXXX")" || return 1
  if [[ -f "$db" ]]; then
    tmp="$CD_DATA_DIR/.chomik-dl-backup.db"
    # shellcheck disable=SC2016
    if ! cd_as_app_user bash -c 'rm -f "$2" && sqlite3 "$1" ".backup \"$2\""' _ "$db" "$tmp" ||
      ! cd_as_app_user cat "$tmp" >"$dir/jobs.db"; then
      cd_err "Database backup failed."
      cd_as_app_user rm -f "$tmp"
      rm -rf "$dir"
      return 1
    fi
    cd_as_app_user rm -f "$tmp"
  fi
  for n in "${CD_STATE_FILES[@]}"; do
    if [[ -e "$CD_DATA_DIR/$n" || -L "$CD_DATA_DIR/$n" ]]; then names+=("$n"); fi
  done
  # Archived by the app user (it can only read what it may read, links stay
  # links); the archive is stored as is and unpacked by the app user again.
  if ((${#names[@]} > 0)) &&
    ! cd_as_app_user tar -C "$CD_DATA_DIR" -cf - -- "${names[@]}" >"$dir/state.tar"; then
    cd_err "Backing up the admin token and browser profile failed."
    rm -rf "$dir"
    return 1
  fi
  if ! { [[ ! -f "$CHOMIKDL_ENV" ]] || cp -p "$CHOMIKDL_ENV" "$dir/chomik-dl.env"; } ||
    ! { [[ ! -f "$CD_VERSION_FILE" ]] || cp -p "$CD_VERSION_FILE" "$dir/chomik-dl_version.txt"; } ||
    ! { [[ ! -f "$CD_UNIT_FILE" ]] || cp -p "$CD_UNIT_FILE" "$dir/chomik-dl.service"; }; then
    cd_err "Backing up the settings failed."
    rm -rf "$dir"
    return 1
  fi
  printf '%s\n' "$dir"
}

# cd_restore DIR: put a backup's database, admin token and link, browser
# profile, settings and version back. Stop the service first. Everything
# inside the data dir is written by the app user (root only reads the backup
# and pipes it over), so it ends up owned by the app user.
cd_restore() { cd_with_lock _cd_restore "$@"; }

_cd_restore() {
  local dir="${1%/}" db="$CD_DATA_DIR/jobs.db"
  [[ -d "$dir" ]] || { cd_err "No such backup: $dir"; return 1; }
  if [[ -f "$dir/chomik-dl.env" ]]; then
    cp -p "$dir/chomik-dl.env" "$CHOMIKDL_ENV" && cd_secure_env_file "$CHOMIKDL_ENV" || return 1
  fi
  if [[ -f "$dir/chomik-dl_version.txt" ]]; then cp -p "$dir/chomik-dl_version.txt" "$CD_VERSION_FILE" || return 1; fi
  if [[ -f "$dir/jobs.db" ]]; then
    # shellcheck disable=SC2016
    cd_as_app_user bash -c 'set -e; umask 027; rm -f "$1-wal" "$1-shm" "$1-journal" "$1.restore"
      cat >"$1.restore"; mv -f "$1.restore" "$1"' _ "$db" <"$dir/jobs.db" ||
      { cd_err "Restoring the database failed."; return 1; }
  fi
  if [[ -f "$dir/state.tar" ]]; then
    # Unpack fully first, then swap each entry in.
    # shellcheck disable=SC2016
    if ! cd_as_app_user bash -c 'set -e; umask 077; cd "$1"
        rm -rf .state.restore; mkdir .state.restore
        tar -C .state.restore -xf -
        for n in .state.restore/*; do
          [ -e "$n" ] || [ -L "$n" ] || continue
          b="${n##*/}"
          rm -rf ".old.$b"
          if [ -e "$b" ] || [ -L "$b" ]; then mv -T "$b" ".old.$b"; fi
          mv -T "$n" "$b"
          rm -rf ".old.$b"
        done
        rmdir .state.restore' _ "$CD_DATA_DIR" <"$dir/state.tar"; then
      cd_as_app_user rm -rf "$CD_DATA_DIR/.state.restore"
      cd_err "Restoring the admin token and browser profile failed."
      return 1
    fi
  fi
}

# cd_prune_backups: keep the newest three backups.
cd_prune_backups() {
  [[ -d "$CD_BACKUP_DIR" ]] || return 0
  local -a all
  mapfile -t all < <(find "$CD_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  local n=$((${#all[@]} - CD_KEEP_BACKUPS)) i
  for ((i = 0; i < n; i++)); do
    rm -rf "${CD_BACKUP_DIR:?}/${all[i]}"
  done
}

# ---------------------------------------------------------------------------
# Update (`update` in the container runs ct/chomik-dl.sh, whose update_script
# calls cd_update)
# ---------------------------------------------------------------------------

# cd_update: update to the newest version on the configured channel. Status 0
# when already up to date, when the releases channel has no release yet, or
# when updated. Non-zero when the check, the disk-space check or the build
# failed (nothing was changed), or when the new version failed or the update
# was interrupted and the previous one was put back (code, unit, database,
# admin token, browser profile, settings, version). Holds the maintenance lock
# throughout and is shielded from console hangups.
#
# Order: check free space -> drop the previous update's CD_APP_DIR.prev ->
# build the new version (and its Chromium) next to the live one while the app
# runs -> stop -> backup (a consistent copy of the stopped database) -> swap
# the code -> record the version -> install the new unit -> start -> health
# check within CHOMIKDL_HEALTH_TIMEOUT (30 s) -> on any failure, or
# SIGINT/SIGTERM after the stop, roll back.
cd_update() { cd_shielded cd_with_lock _cd_update; }

# Update state, global so the trap handler (_cd_interrupted) can read it.
_CD_U_PHASE="" _CD_U_BACKUP="" _CD_U_PREVIOUS=""

_cd_update() {
  local channel current latest backup rc=0
  if [[ ! -f "$CD_VERSION_FILE" || ! -d "$CD_APP_DIR" ]]; then
    cd_err "No chomik-dl installation found ($CD_VERSION_FILE, $CD_APP_DIR)."
    return 1
  fi
  current="$(head -n 1 "$CD_VERSION_FILE")"
  channel="$(cd_settings_get CHOMIKDL_CHANNEL 2>/dev/null)" || channel=""
  channel="${channel:-main}"
  latest="$(cd_latest_ref "$channel")" || rc=$?
  if [[ $rc == 2 ]]; then
    echo "No release yet; staying on $current."
    return 0
  elif [[ $rc != 0 ]]; then
    cd_err "Could not check for a new version on GitHub ($(cd_repo), channel $channel); nothing was changed."
    return 1
  fi
  if [[ "$latest" == "$current" ]]; then
    echo "chomik-dl is already up to date ($current)."
    return 0
  fi

  echo "Updating chomik-dl from $current to $latest (channel $channel)."
  _cd_check_space || return 1
  # The previous update's rollback target is not needed any more, and its
  # space is needed for the build.
  rm -rf "$CD_APP_DIR.prev"
  echo "Building the new version; the app keeps running meanwhile..."
  if ! cd_build_ref "$latest" "$CD_APP_DIR"; then
    cd_err "Update aborted; nothing was changed."
    return 1
  fi

  # From here on an interruption must not leave the app stopped or half
  # updated: the trap puts everything back (once) and exits non-zero.
  _CD_U_PHASE=stopped _CD_U_BACKUP="" _CD_U_PREVIOUS="$current"
  trap '_cd_interrupted 130' INT
  trap '_cd_interrupted 143' TERM
  echo "Stopping chomik-dl and backing up the database, admin token, browser profile and settings..."
  if ! systemctl stop "$CD_SERVICE" || ! backup="$(_cd_backup)"; then
    _cd_untrap
    rm -rf "$CD_APP_DIR.new"
    _cd_start_unchanged
    cd_err "Backup failed; update aborted, nothing was changed."
    return 1
  fi
  _CD_U_BACKUP="$backup"
  cd_prune_backups
  _CD_U_PHASE=swapping
  if ! _cd_swap_dirs "$CD_APP_DIR.new" "$CD_APP_DIR"; then
    _cd_untrap
    _cd_start_unchanged
    cd_err "Update aborted; nothing was changed."
    return 1
  fi
  _CD_U_PHASE=swapped
  if ! printf '%s\n' "$latest" >"$CD_VERSION_FILE"; then
    _cd_untrap
    cd_err "Could not write $CD_VERSION_FILE."
    _cd_rollback "$backup" "$current" 1
    return 1
  fi
  if ! _cd_install_unit; then
    _cd_untrap
    _cd_rollback "$backup" "$current" 1
    return 1
  fi

  echo "Starting the new version..."
  if cd_service start && cd_health; then
    _cd_untrap
    _cd_refresh_helpers
    # The engine pin only moves forward with main: a release's lib may carry
    # an older pin than the one /usr/bin/update already has.
    if [[ "$channel" == main ]]; then
      _cd_refresh_entrypoint
    fi
    echo "Updated chomik-dl to $latest. Backup of the previous version: $backup"
    return 0
  fi
  _cd_untrap
  cd_err "The new version did not start. Last log lines:"
  cd_err "$(journalctl -u "$CD_SERVICE" -n 20 --no-pager 2>&1)"
  _cd_rollback "$backup" "$current" 1
}

_cd_untrap() {
  trap - INT TERM
  _CD_U_PHASE=""
}

# Trap handler (SIGINT/SIGTERM after the stop): undo what was done so far,
# once, then exit with 128+signal.
_cd_interrupted() {
  local code="$1" phase="$_CD_U_PHASE"
  trap '' INT TERM
  _CD_U_PHASE=""
  [[ -n "$phase" ]] || exit "$code"
  cd_err "Update interrupted; putting the previous version back..."
  if [[ -n "$_CD_U_BACKUP" ]]; then
    # "swapping": the swap either happened (the new code is live, the old one
    # in .prev) or _cd_swap_dirs put the old dir back; .new tells them apart.
    if [[ "$phase" == swapped || ("$phase" == swapping && ! -e "$CD_APP_DIR.new") ]]; then
      _cd_rollback "$_CD_U_BACKUP" "$_CD_U_PREVIOUS" 1
    else
      _cd_rollback "$_CD_U_BACKUP" "$_CD_U_PREVIOUS" 0
    fi
  else
    rm -rf "$CD_APP_DIR.new"
    _cd_start_unchanged
    cd_err "Update interrupted before anything was changed."
  fi
  exit "$code"
}

# _cd_check_space: the update needs room for the new code (built next to the
# old), a backup of the data dir state and possibly a new Chromium: 2x the
# code + data + 700 MB, on the code's filesystem (the previous update's .prev,
# which is removed first, counts as free). A separate backup filesystem must
# hold the data + 100 MB.
_cd_check_space() {
  local code prev data need avail fs bk_fs bk_avail bk_dir
  code="$(_cd_kb "$CD_APP_DIR")"
  prev="$(_cd_kb "$CD_APP_DIR.prev")"
  data=$(($(_cd_kb "$CD_DATA_DIR/jobs.db") + $(_cd_kb "$CD_DATA_DIR/browser")))
  need=$((2 * code + data + 700 * 1024))
  read -r fs avail < <(df -Pk "$(dirname "$CD_APP_DIR")" 2>/dev/null | awk 'NR == 2 {print $1, $4}')
  if [[ ! "${avail:-}" =~ ^[0-9]+$ ]]; then
    cd_err "Could not determine the free disk space; update aborted, nothing was changed."
    return 1
  fi
  if ((avail + prev < need)); then
    cd_err "Not enough free disk space for the update: need $((need / 1024)) MB, $(((avail + prev) / 1024)) MB free. Update aborted, nothing was changed. Grow the container disk (e.g. pct resize <ctid> rootfs +2G) and try again."
    return 1
  fi
  bk_dir="$CD_BACKUP_DIR"
  [[ -d "$bk_dir" ]] || bk_dir="$(dirname "$CD_BACKUP_DIR")"
  read -r bk_fs bk_avail < <(df -Pk "$bk_dir" 2>/dev/null | awk 'NR == 2 {print $1, $4}')
  if [[ -n "${bk_fs:-}" && "$bk_fs" != "$fs" && "${bk_avail:-0}" =~ ^[0-9]+$ ]] &&
    ((bk_avail < data + 100 * 1024)); then
    cd_err "Not enough free disk space for the backup in $CD_BACKUP_DIR: need $(((data + 100 * 1024) / 1024)) MB, $((bk_avail / 1024)) MB free. Update aborted, nothing was changed."
    return 1
  fi
}

# Size of a file or directory in KiB (0 if missing).
_cd_kb() {
  local kb
  kb="$(du -sk "$1" 2>/dev/null | awk '{print $1}')"
  printf '%s' "${kb:-0}"
}

# Install the unit shipped with the (now live) new version, if it has one,
# and reload systemd. The old unit is in the backup (chomik-dl.service).
_cd_install_unit() {
  local src="$CD_APP_DIR/proxmox/misc/chomik-dl.service" tmp
  if [[ -f "$src" ]] && ! cmp -s "$src" "$CD_UNIT_FILE"; then
    tmp="$(mktemp "$(dirname "$CD_UNIT_FILE")/.chomik-dl.service.XXXXXX")" &&
      cat "$src" >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$CD_UNIT_FILE" || {
      rm -f "${tmp:-}"
      cd_err "Could not install the new $CD_UNIT_FILE."
      return 1
    }
  fi
  systemctl daemon-reload || { cd_err "systemctl daemon-reload failed."; return 1; }
}

# Start the untouched installation again after an aborted update.
_cd_start_unchanged() {
  if ! { cd_service start && cd_health >/dev/null 2>&1; }; then
    cd_err "Warning: chomik-dl did not come back up; check: journalctl -u $CD_SERVICE"
  fi
}

# _cd_rollback BACKUP_DIR PREVIOUS_VERSION SWAPPED: if SWAPPED is 1, put the
# previous code dir (CD_APP_DIR.prev) back, else just drop CD_APP_DIR.new;
# then restore the backup (database, admin token, browser profile, settings,
# version, unit), start, health-check. Always returns 1 (the update failed
# either way); says whether the rollback worked. SIGINT/SIGTERM are ignored
# while it runs (an interrupted rollback would leave a half-restored, stopped
# app); the previous dispositions are put back afterwards.
_cd_rollback() {
  local saved_traps
  saved_traps="$(trap -p INT TERM)"
  trap '' INT TERM
  _cd_do_rollback "$@"
  trap - INT TERM
  eval "$saved_traps"
  return 1
}

_cd_do_rollback() {
  local backup="$1" previous="$2" swapped="${3:-1}" ok=1
  cd_err "Rolling back to $previous..."
  systemctl stop "$CD_SERVICE" || true
  if [[ "$swapped" == 1 ]]; then
    if [[ -d "$CD_APP_DIR.prev" ]] && rm -rf "$CD_APP_DIR.failed" && mv -T "$CD_APP_DIR" "$CD_APP_DIR.failed"; then
      if mv -T "$CD_APP_DIR.prev" "$CD_APP_DIR"; then
        rm -rf "$CD_APP_DIR.failed"
      else
        mv -T "$CD_APP_DIR.failed" "$CD_APP_DIR" || true
        ok=0
      fi
    else
      ok=0
    fi
  else
    # Not swapped, or interrupted inside the swap: if the live dir was moved
    # aside but the new one not moved in, put the old one back.
    if [[ ! -e "$CD_APP_DIR" && -d "$CD_APP_DIR.prev" ]]; then
      mv -T "$CD_APP_DIR.prev" "$CD_APP_DIR" || ok=0
    fi
    rm -rf "$CD_APP_DIR.new"
  fi
  _cd_restore "$backup" || ok=0
  if [[ -f "$backup/chomik-dl.service" ]] && ! cmp -s "$backup/chomik-dl.service" "$CD_UNIT_FILE"; then
    cp "$backup/chomik-dl.service" "$CD_UNIT_FILE" && chmod 644 "$CD_UNIT_FILE" || ok=0
  fi
  systemctl daemon-reload || ok=0
  if ! { cd_service start && cd_health; }; then ok=0; fi
  if [[ $ok == 1 ]]; then
    cd_err "Update failed; rolled back to $previous (code, database, admin token, browser profile and settings). Backup kept in $backup."
  else
    cd_err "Update failed and the rollback did not complete. Backup of $previous: $backup. Check: journalctl -u $CD_SERVICE"
  fi
  return 1
}

# After a good update: rewrite /usr/bin/update with the NEW lib (just
# refreshed), so a moved engine pin (CD_CORE_URL_DEFAULT) reaches installed
# containers. The scripts and website bases already in the entrypoint stay.
_cd_refresh_entrypoint() {
  local base="" website=""
  [[ -f "$CD_LIB_FILE" ]] || return 0
  if [[ -f "$CD_UPDATE_ENTRYPOINT" ]]; then
    base="$(sed -n 's/^export COMMUNITY_SCRIPTS_URL="\(.*\)"$/\1/p' "$CD_UPDATE_ENTRYPOINT" | head -n 1)"
    website="$(sed -n 's/^export COMMUNITY_SCRIPTS_WEBSITE_URL="\(.*\)"$/\1/p' "$CD_UPDATE_ENTRYPOINT" | head -n 1)"
  fi
  # shellcheck disable=SC2016
  env -u COMMUNITY_SCRIPTS_CORE_URL \
    COMMUNITY_SCRIPTS_URL="${base:-$CD_SCRIPTS_URL_DEFAULT}" \
    COMMUNITY_SCRIPTS_WEBSITE_URL="${website:-https://community-scripts.org}" \
    bash -c '. "$1" && cd_write_update_entrypoint "$2"' _ "$CD_LIB_FILE" "$CD_UPDATE_ENTRYPOINT" ||
    cd_err "Warning: could not refresh $CD_UPDATE_ENTRYPOINT."
}

# After a good update: install the helper scripts shipped with the new
# version (if it has them), so fixes to the lib and chomik-dl-settings arrive
# with updates. (The unit file is installed separately, earlier in the update.)
_cd_refresh_helpers() {
  local src="$CD_APP_DIR/proxmox/misc" entry name dest mode tmp
  for entry in "chomik-dl-lib.sh:$CD_LIB_FILE:644" "chomik-dl-settings:$CD_SETTINGS_CMD:755"; do
    IFS=: read -r name dest mode <<<"$entry"
    [[ -f "$src/$name" && -d "$(dirname "$dest")" ]] || continue
    tmp="$(mktemp "$(dirname "$dest")/.$name.XXXXXX")" || continue
    if cat "$src/$name" >"$tmp" && chmod "$mode" "$tmp" &&
      { [[ $EUID -ne 0 ]] || chown root:root "$tmp"; } && mv -f "$tmp" "$dest"; then
      :
    else
      rm -f "$tmp"
      cd_err "Warning: could not refresh $dest."
    fi
  done
}

# cd_write_update_entrypoint [FILE]: write /usr/bin/update in the engine's
# format (core.func write_update_entrypoint at the pinned commit), so the
# engine's migrate_update_entrypoint leaves it alone, but with our slug. It
# runs the engine's misc/update.sh, which asks community-scripts.org about
# SCRIPT_SLUG (unknown -> update normally; unreachable -> update anyway) and
# then runs ${COMMUNITY_SCRIPTS_URL}/ct/chomik-dl.sh; if the helper cannot be
# fetched it runs our ct script directly. The bases come from the engine's
# environment (it exports both into the container), else our defaults.
cd_write_update_entrypoint() {
  local target="${1:-$CD_UPDATE_ENTRYPOINT}" base core website u tmp
  local re='^https?://[^[:space:]"$`\]+$'
  base="${COMMUNITY_SCRIPTS_URL:-$CD_SCRIPTS_URL_DEFAULT}"
  core="${COMMUNITY_SCRIPTS_CORE_URL:-$CD_CORE_URL_DEFAULT}"
  website="${COMMUNITY_SCRIPTS_WEBSITE_URL:-https://community-scripts.org}"
  base="${base%/}" core="${core%/}" website="${website%/}"
  for u in "$base" "$core" "$website"; do
    [[ "$u" =~ $re ]] || { cd_err "Not writing $target: unusable URL: $u"; return 1; }
  done
  tmp="$(mktemp "$(dirname "$target")/.update.XXXXXX")" || return 1
  {
    printf '%s\n' '#!/usr/bin/env bash' \
      '# chomik-dl update entrypoint, written by the chomik-dl install in the' \
      "# community-scripts engine's format, with chomik-dl's own script slug." \
      "export SCRIPT_SLUG=\"$CD_SCRIPT_SLUG\"" \
      'export UPDATE_SCRIPT_NAME="chomik-dl"' \
      "export COMMUNITY_SCRIPTS_URL=\"$base\"" \
      "export COMMUNITY_SCRIPTS_CORE_URL=\"$core\"" \
      "export COMMUNITY_SCRIPTS_WEBSITE_URL=\"$website\""
    # The rest is the engine's text verbatim (single-quoted: no expansion here).
    # shellcheck disable=SC2016
    printf '%s\n' \
      '# Pull the shared helper; it decides whether this app can still be updated. If it' \
      '# cannot be fetched, fall back to the legacy direct pull so `update` still works.' \
      '_cs_helper="$(curl -fsSL --connect-timeout 10 "${COMMUNITY_SCRIPTS_CORE_URL}/misc/update.sh" 2>/dev/null)"' \
      'if [[ -n "$_cs_helper" ]]; then' \
      '  bash -c "$_cs_helper"' \
      'else' \
      '  echo "Update helper unavailable - falling back to direct update."' \
      '  bash -c "$(curl -fsSL "${COMMUNITY_SCRIPTS_URL}/ct/${UPDATE_SCRIPT_NAME}.sh")"' \
      'fi'
  } >"$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$target" || {
    rm -f "$tmp"
    return 1
  }
}
