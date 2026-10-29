#!/bin/bash
# Shared helpers for the Killing Floor 2 image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Two volumes: the install (SteamCMD's and the game's, disposable, local to the node) and the
# data (the game's SaveGames folder and ours). The data is the only thing that has to survive.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/kf2/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/kf2/data}"
# The game's settings live in <install>/KFGame/Config/flux (the server is started with -ConfigSubDir=flux):
# that folder is a symlink to the data volume's Config/flux, made at every start by fluxkf2.py apply, so the
# ini files (settings, bans, the map cycle, the workshop list) are synced and survive a node move.
FLUX_STATE_DIR="${FLUX_STATE_DIR:-${FLUX_DATA_DIR}/flux}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced data volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
# The game's console output, on the INSTALL volume (local, never synced): Unreal logs a lot, and on
# the synced data volume that would be steady Syncthing traffic. The current one is capped at
# FLUX_GAME_LOG_MAX_BYTES.
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_GAME_LOG_MAX_BYTES="${FLUX_GAME_LOG_MAX_BYTES:-52428800}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-10}"
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_STATE_DIR}/backups}"
FLUX_GAME_EXE="${FLUX_GAME_EXE:-Binaries/Win64/KFGameSteamServer.bin.x86_64}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-232130}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
# How the running server is found: the native Linux binary, run directly (no Wine). `[K]` keeps pgrep
# from matching its own command line.
FLUX_GENERATION_MARK="${FLUX_GENERATION_MARK:-/tmp/flux-generation-start}"
FLUX_GAME_PATTERN="${FLUX_GAME_PATTERN:-[K]FGameSteamServer\.bin\.x86_64}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = a port as given, $2 = the default when it is empty. Prints the port; returns 1 for a value
# that is not a port from 1024 to 65535.
flux_port() {
  local value="${1:-$2}"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# $1 $2 = the game and query ports. Returns 1 when they are the same (the server binds each).
flux_ports_distinct() {
  [ "$1" != "$2" ]
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. A restart the supervisor planned (a game update, the
# daily restart, one the panel asked for) is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The daily restart. There is no console to warn players through, so it waits for an empty
# server, up to FLUX_RESTART_WAIT_MINUTES.
# ---------------------------------------------------------------------------------------------

# $1 = KF2_RESTART_TIME as given. Prints HH:MM (in TZ), or "" when off. Returns 1 for a value
# that is not a time.
flux_restart_time() {
  local value="${1-}" h m
  case "${value,,}" in
    "" | off | none | false | 0) printf ''; return 0 ;;
  esac
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%02d:%02d' "${h}" "${m}"
}

# $1 = now (epoch seconds), $2 = HH:MM in the container's time zone (TZ; UTC when unset). Prints
# the epoch of the next time it is $2: today when that is still ahead, tomorrow otherwise.
flux_next_daily() {
  local now="$1" at
  at="$(date -d "$(date -d "@${now}" +%F) $2" +%s 2>/dev/null)" || return 1
  if [ "${at}" -le "${now}" ]; then
    at="$(date -d "$(date -d "@$((now + 86400))" +%F) $2" +%s 2>/dev/null)" || return 1
  fi
  printf '%s' "${at}"
}

# ---------------------------------------------------------------------------------------------
# Rotation of the game logs.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# Steam builds: an outdated server refuses players on the new client, so a new build means a
# restart (onto it). The installed buildid (appmanifest) is compared with the public branch's.
# ---------------------------------------------------------------------------------------------

# $1 = an appmanifest_<app>.acf. Prints its buildid.
flux_installed_build() {
  [ -f "$1" ] || return 0
  awk -F'"' '$2 == "buildid" { print $4; exit }' "$1"
}

# stdin = steamcmd +app_info_print output. Prints the public branch's buildid.
flux_public_build() {
  awk '
    /"branches"/ { inb = 1 }
    inb && /"public"/ { inp = 1 }
    inp && /"buildid"/ { gsub(/"/, "", $2); print $2; exit }
  '
}

# The game's console output of the current generation.
flux_game_log() {
  printf '%s' "${FLUX_GAME_LOG:-${FLUX_GAME_LOG_DIR}/current.log}"
}

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PATTERN}" 2>/dev/null | head -1
}

# stdin = one line of the server's console. Returns 0 when it is noise worth dropping from the
# container log (Unreal's per-actor recording, per-level streaming, plugin and pak mounting, console
# variable and graphics settings echoes, the headless renderer's complaints). The full output stays in
# the game log on the install volume.
flux_noise() {
  local line
  IFS= read -r line || return 1
  [[ "${line}" =~ ^[[:space:]]*$ ]] && return 0
  case "${line}" in
    *"DevOnline: Advertising: "* | *"DevOnline: Refreshing published game settings"* | *"DevOnline: Server data: "* | \
      *"RefreshPublishedGameSettings"* | *"AKFPawn_Monster::PreloadContent"* | *"Invalid movie stream data"* | \
      *"DevConfig: "* | *"Log: Registered "* | *"Log: Loaded "* | *"Init: Waited "* | *"DevShaders"* | *"DevMemory"* | \
      *"Log: Cooked "* | *"ScriptLog: Gameplay events will not be recorded"* | *"DevLobby: "* | *"UKFOnlineLobbySteamworks"*) return 0 ;;
  esac
  return 1
}

# stdin -> stdout: the line with any password option replaced (the image passes none on the command
# line, but KF2_EXTRA_ARGS is the owner's): ?AdminPassword=x, ?GamePassword=x, -AdminPassword=x.
flux_redact() {
  sed -E 's/([?-][A-Za-z]*Password=)("[^"]*"|[^ ?]*)/\1***/g'
}

# $1 = the restart marker. Prints the earliest epoch the server may be stopped for it, 0 when it
# says nothing.
flux_marker_not_before() {
  local value
  value="$(sed -n 's/^notbefore=//p' "$1" 2>/dev/null | head -1)"
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}
