#!/bin/bash
# PID 1, and the supervisor of the Killing Floor 2 server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and a server that ends on its own
# is followed by the next one in place. It is the game's NATIVE LINUX binary (no Wine, no display):
#
#   - every start: SteamCMD update (anonymous; the Windows platform is requested because the Linux one
#     answers "Missing configuration", and that depot carries the Linux server binary), the restore the
#     panel asked for, a backup of the settings, the workshop items (SteamCMD, anonymous) put where the
#     game loads them, then the ini files from the environment and the panel (fluxkf2.py apply / args)
#   - SIGTERM/SIGINT from Docker: nothing has to be saved (a match is not kept), so the server is
#     ended at once, well inside the 10 seconds Flux gives a container
#   - a new build on Steam: an outdated server refuses players on the new client, so it is restarted
#     onto it, as soon as nobody is playing or after FLUX_UPDATE_WAIT_MINUTES
#   - KF2_RESTART_TIME: a daily restart at that time (in TZ, UTC when unset), on an empty server
#     if one comes within FLUX_RESTART_WAIT_MINUTES
#   - the server ending on its own: a new generation in the same container; FLUX_RESTART_MAX_ATTEMPTS
#     unplanned ones inside FLUX_RESTART_WINDOW seconds end the container with 42
#   - a backup of the settings on start (unless one is under an hour old or nothing changed) and every
#     FLUX_BACKUP_HOURS, kept on the data volume (flux/backups), and a backup restored when the panel
#     asked for one
#   - the panel's restart (flux-kf2 restart) is a marker: the supervisor stops the server for it
#
# Same shape as runonflux/icarus-server-flux and runonflux/scum-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. Docker's own deadline on Flux is
# ten seconds, so a stop from Docker (SIGTERM to us) gets FLUX_STOP_GRACE (8 s: it kills the game
# before Docker kills us).
# A restart the panel or the daily timer asked for has nobody waiting on a deadline and gets
# FLUX_RESTART_GRACE.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-8}"
FLUX_RESTART_GRACE="${FLUX_RESTART_GRACE:-60}"
# After SIGTERM the game is given this long to end by itself (nothing is saved on exit), then SIGKILL.
FLUX_STOP_AFTER_SIGNAL="${FLUX_STOP_AFTER_SIGNAL:-6}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
export FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-10}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_WAIT_MINUTES="${FLUX_UPDATE_WAIT_MINUTES:-60}"
FLUX_RESTART_WAIT_MINUTES="${FLUX_RESTART_WAIT_MINUTES:-60}"
# Ready = the Steam query port answers (fluxkf2.py serving), polled every two seconds. FLUX_READY_TIMEOUT:
# how long a start may take before it is logged as slow.
FLUX_READY_TIMEOUT="${FLUX_READY_TIMEOUT:-300}"

s="${FLUX_SERVER_DIR}"
ic() { python3 /opt/flux/fluxkf2.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${FLUX_STATE_DIR}" "${FLUX_GAME_LOG_DIR}"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_STATE_DIR}/flux.log"
flux_banner "Killing Floor 2"

if ! restart_at="$(flux_restart_time "${KF2_RESTART_TIME:-}")"; then
  flux_log "WARN KF2_RESTART_TIME='${KF2_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev})"

game_pid=""
tail_pid=""
watch_pid=""
backup_pid=""
cap_pid=""
terminating=0
generation=0
restart_history=()

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: shutting down, no restart will follow"
  stop_game
}
trap term_handler TERM INT

# Ends the game. Nothing is saved on exit (a match is not kept), so SIGTERM, then SIGKILL after
# FLUX_STOP_AFTER_SIGNAL if the game is still there.
stop_game() {
  local pid
  pid="$(flux_game_pid)"
  pid="${pid:-${game_pid}}"
  [ -n "${pid}" ] || return 0
  kill -TERM "${pid}" 2>/dev/null
}

# The workshop items the panel or KF2_WORKSHOP_IDS listed: SteamCMD downloads them (anonymous, app 232090;
# an item that is up to date is skipped), then they are linked where the game loads them. The game's own
# downloader does nothing on a dedicated server without a Steam client (measured).
sync_mods() {
  local line id
  local -a ids=() cmd=()
  mapfile -t ids < <(ic mods-ids 2>/dev/null)
  if [ "${#ids[@]}" -gt 0 ]; then
    flux_log "workshop: downloading ${#ids[@]} item(s) from Steam"
    cmd=(steamcmd +force_install_dir "${s}" +login anonymous)
    for id in "${ids[@]}"; do cmd+=(+workshop_download_item 232090 "${id}"); done
    cmd+=(+quit)
    "${cmd[@]}" >/tmp/steamcmd-workshop.log 2>&1 &
    wait $!
    grep -aE "ERROR|Success" /tmp/steamcmd-workshop.log | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do flux_log "workshop: ${line}"; done
  fi
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(ic mods-install 2>&1)
}

# Starts the server once, only so that it writes its ini files (this is the first start on this data
# volume), and ends it as soon as the engine ini is there and has stopped growing.
bootstrap_config() {
  local engine="${FLUX_DATA_DIR}/Config/flux/LinuxServer-KFEngine.ini" pid i size last=-1 stable=0
  local -a bargs=()
  flux_log "first start on this volume: letting the game write its default files"
  mapfile -t bargs < <(ic args)
  (
    cd "${s}" || exit 1
    exec env LD_LIBRARY_PATH="${s}/Binaries/Win64/lib64" "./${FLUX_GAME_EXE}" "${bargs[@]}" </dev/null >/dev/null 2>&1
  ) &
  pid=$!
  for i in $(seq 1 90); do
    [ "${terminating}" = "1" ] && break
    sleep 1 &
    wait $!
    size="$(stat -c %s "${engine}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt 1000 ] && [ "${size}" = "${last}" ]; then
      stable=$((stable + 1))
      [ "${stable}" -ge 3 ] && break
    else
      stable=0
    fi
    last="${size}"
    kill -0 "${pid}" 2>/dev/null || break
  done
  kill -TERM "${pid}" 2>/dev/null
  for i in 1 2 3 4 5 6; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5 &
    wait $!
  done
  kill -KILL "${pid}" 2>/dev/null
  wait "${pid}" 2>/dev/null
  pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
  return 0
}

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  ic state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, Windows build)"
  # No `validate` on the first attempt: it re-hashes the whole 32 GB install on every start. An
  # install that is actually broken fails the first attempt, and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # app_info_update first: a fresh SteamCMD answers "Missing configuration" to the very first
    # app_update of this app (measured 2026-10-24) and stops; the next attempt works. That error is
    # retried at once WITHOUT validate (validate re-hashes the whole 32 GB install).
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "${s}" +login anonymous \
      +app_info_update 1 +app_update "${FLUX_STEAM_APP}" ${validate} +quit \
      >/tmp/steamcmd.log 2>&1 &
    wait $!
    # "fully installed" after a download, "already up to date" otherwise.
    if [ -f "${s}/${FLUX_GAME_EXE}" ] && grep -qE "fully installed|already up to date" /tmp/steamcmd.log; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    if ! grep -aq "Missing configuration" /tmp/steamcmd.log; then
      validate="validate"
    fi
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -aE 'ERROR|Error|error' /tmp/steamcmd.log | tail -2 | tr '\n' ' ')retrying in 5s${validate:+ with validate}"
    sleep 5 &
    wait $!
  done
  if [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# A backup (fluxkf2.py backup: what goes in, what is skipped and what is kept). $2 = force.
backup_save() {
  local line
  while IFS= read -r line; do
    flux_log "${line#\# }"
  done < <(ic backup "$1" ${2:+"$2"} 2>&1)
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    backup_save "every ${FLUX_BACKUP_HOURS}h"
  done
}

request_restart() {
  [ -f "${FLUX_RESTART_MARKER}" ] && return 0
  printf '%s\nnotbefore=0\n' "$1" >"${FLUX_RESTART_MARKER}"
  flux_log "$1: restarting the server"
}

# shellcheck disable=SC2329  # run in the background below
# The current game log, capped at FLUX_GAME_LOG_MAX_BYTES: its last 5 MB go to a rotated file and
# the live one is emptied in place (the game keeps writing it).
log_capper() {
  local current size
  current="$(flux_game_log)"
  while true; do
    sleep 60
    size="$(stat -c %s "${current}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt "${FLUX_GAME_LOG_MAX_BYTES}" ] 2>/dev/null; then
      tail -c 5242880 "${current}" >"${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log" 2>/dev/null
      : >"${current}"
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
      flux_log "the game log reached $((size / 1048576)) MB: rotated"
    fi
  done
}

# Waits for an empty server for up to $1 minutes, checking every minute.
wait_for_empty() {
  local until=$(($(date -u +%s) + $1 * 60)) n
  while [ "$(date -u +%s)" -lt "${until}" ]; do
    n="$(ic players-online 2>/dev/null)"
    [ "${n}" = "0" ] && return 0
    sleep 60
  done
  return 0
}

# shellcheck disable=SC2329  # run in the background below
# Marks the server running once the Steam query port answers (about 10 s after the process starts, measured),
# then follows Steam for a newer build and keeps the daily restart.
watcher() {
  local build public last_check now next_restart="" waited=0
  last_check="$(date -u +%s)"
  # Up = the query port answers. If that has not happened after FLUX_READY_TIMEOUT the wait goes on,
  # logged once: a slow node, not a reason to restart a server that may be about to answer.
  until ic serving >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if [ "${waited}" -eq "${FLUX_READY_TIMEOUT}" ]; then
      flux_log "WARN the server has not answered its query port after ${FLUX_READY_TIMEOUT}s; still waiting"
    fi
  done
  ic state running
  flux_log "the server is up (query port answered) after ${waited}s (generation ${generation})"
  if [ -n "${restart_at}" ]; then
    next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
    ic note nextRestart "${next_restart}"
  else
    ic note nextRestart
  fi
  ic note updateWaiting
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      public="$(steamcmd +login anonymous +app_info_update 1 +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_build)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ] && ! ic update-skip "${public}"; then
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it when the server is empty, at most ${FLUX_UPDATE_WAIT_MINUTES} min from now"
        ic note updateWaiting "${public}"
        wait_for_empty "${FLUX_UPDATE_WAIT_MINUTES}"
        ic update-target "${public}"
        request_restart "planned: game update ${build} -> ${public}"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      flux_log "daily restart (${restart_at} ${TZ:-UTC}): waiting up to ${FLUX_RESTART_WAIT_MINUTES} min for an empty server"
      wait_for_empty "${FLUX_RESTART_WAIT_MINUTES}"
      request_restart "planned: the daily restart (${restart_at} ${TZ:-UTC})"
      exit 0
    fi
  done
}

# shellcheck disable=SC2329  # run in the background below
# The game's console onto the container's output, without the lines Unreal prints for every actor
# and EOS attribute (the full output stays in the game log), and with the passwords of the
# "Command Line:" echo hidden.
log_follower() {
  local line
  while IFS= read -r line; do
    flux_noise <<<"${line}" || printf '%s\n' "${line}" | flux_redact
  done < <(tail -n 0 -F "$1" 2>/dev/null)
}

start_generation() {
  local line current
  local -a args=()
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"
  # A state left by the container that was here before (a kill, a node reboot) is stale from now on.
  ic state updating "Preparing the server"

  update_server || return 1
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(ic update-check 2>&1)
  [ "${terminating}" = "1" ] && return 2
  # A restore the panel asked for, before anything reads the server's files.
  while IFS= read -r line; do flux_log "restore: ${line#\# }"; done < <(ic do-restore 2>&1)
  backup_save "start"

  local applied
  if applied="$(ic apply 2>/tmp/flux-apply.err)"; then
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
  else
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
    printf '%s\n' "${applied}" >/tmp/flux-apply.out
    flux_log "ERROR the settings could not be applied: $(grep -h ERROR <<<"${applied}" | tr '\n' ' ')$(tail -3 /tmp/flux-apply.err | tr '\n' ' ')"
    return 3
  fi

  # The game writes its engine ini on its first start and must not be handed a partial one (see
  # fluxkf2.py needs-bootstrap): run it once to let it, then apply again for what lives in that file.
  if ic needs-bootstrap; then
    bootstrap_config
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done < <(ic apply 2>&1)
  fi

  sync_mods

  current="$(flux_game_log)"
  if [ -s "${current}" ]; then
    mv "${current}" "${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log"
  fi
  : >"${current}"
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  # The launch line, one argument per line (fluxkf2.py args).
  mapfile -t args < <(ic args)
  ic state starting "Starting the server"
  flux_banner "Killing Floor 2"
  flux_log "starting the server (generation ${generation}): $(printf '%s' "${args[*]}" | flux_redact)"

  touch "${FLUX_GENERATION_MARK}"
  log_follower "${current}" &
  tail_pid=$!

  (
    cd "${s}" || exit 1
    # stdin closed: the server takes no console input. Its own libraries (SDL, Steam, EOS) are in lib64.
    exec env LD_LIBRARY_PATH="${s}/Binaries/Win64/lib64" "./${FLUX_GAME_EXE}" "${args[@]}" </dev/null >>"${current}" 2>&1
  ) &
  game_pid=$!

  watcher &
  watch_pid=$!
  backupper &
  backup_pid=$!
  log_capper &
  cap_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${tail_pid}" "${watch_pid}" "${backup_pid}" "${cap_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  tail_pid="" watch_pid="" backup_pid="" cap_pid=""
  pkill -f "tail -n [0+1]* -F $(flux_game_log)" 2>/dev/null
  pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
  game_pid=""
}

# Waits for the game to end. A stop or restart asked for goes through stop_game; the game gets
# FLUX_STOP_AFTER_SIGNAL seconds after the signal, and FLUX_STOP_GRACE (a stop) or FLUX_RESTART_GRACE
# (a restart) in all.
wait_for_generation() {
  local asked_at=0 now signalled=0 grace
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 0.5 &
    wait $!
    if [ "${signalled}" = "0" ] && [ "${terminating}" = "0" ] && [ -f "${FLUX_RESTART_MARKER}" ] \
      && [ "$(date -u +%s)" -ge "$(flux_marker_not_before "${FLUX_RESTART_MARKER}")" ]; then
      signalled=1
      stop_game
    fi
    if [ "${terminating}" = "1" ] || [ "${signalled}" = "1" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      grace="${FLUX_RESTART_GRACE}"
      [ "${terminating}" = "1" ] && grace="${FLUX_STOP_GRACE}"
      if [ $((now - asked_at)) -ge "${grace}" ] || [ $((now - asked_at)) -ge "${FLUX_STOP_AFTER_SIGNAL}" ]; then
        kill -KILL "${game_pid}" 2>/dev/null
        pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
        break
      fi
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

# The environment holds a port the server cannot use: restarting cannot fix it and exiting would
# only make the platform restart the same container, so the state says what to change and the
# container waits (no restart budget used) for a stop or the panel's restart.
wait_for_fix() {
  local why
  why="$(grep -ah 'ERROR' /tmp/flux-apply.out 2>/dev/null | head -1 | sed 's/^# ERROR //')"
  ic state needs-fix "${why:-The settings in the environment cannot be used}. Change it in the app's deployment settings; the server starts after a redeploy."
  flux_log "not restarting: ${why}. Waiting for a redeploy."
  while [ "${terminating}" = "0" ] && [ ! -f "${FLUX_RESTART_MARKER}" ]; do
    sleep 2 &
    wait $!
  done
  rm -f "${FLUX_RESTART_MARKER}"
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    ic state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "3" ]; then
    wait_for_fix
    continue
  fi
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    ic state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    ic state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(head -1 "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    ic state stopped
    exit 0
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      ic state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi

  ic state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
