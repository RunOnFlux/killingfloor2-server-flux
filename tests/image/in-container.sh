#!/bin/bash
# shellcheck disable=SC2016  # wait_for conditions are single-quoted and eval-ed later, on purpose
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t
# and scripts/ at /s.
set -uo pipefail
export LC_ALL=C

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 pgrep pkill tail tar curl; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "there is no Wine to maintain" "1" "$(status command -v wine)"
check "libcurl (the server's one extra library) is installed" "0" "$(status bash -c 'ldconfig -p | grep -q "libcurl.so.4"')"
check "flux-kf2 is on the PATH" "0" "$(status command -v flux-kf2)"
check "flux-kf2 starts (usage)" "64" "$(status flux-kf2)"
for script in flux-entrypoint.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "the image's scripts are the repository's" "0" "$(status diff -r --exclude=__pycache__ /s /opt/flux)"
check "the unit tests pass with the image's Python" "0" "$(status bash -c 'cd /tmp && rm -rf repo && mkdir repo && cp -r /s repo/scripts && cp -r /t repo/tests && cd repo && ./tests/test-flux.sh')"

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd "installs" the server (the first call fails with "Missing configuration" like a fresh SteamCMD
# does) and "downloads" a workshop item; the stand-in server is a Python script named like the real
# binary: it reads the ini of the config folder it is pointed at, answers the Steam query on its query port
# the way the real one does (a challenge first), serves a minimal WebAdmin, and ends AT ONCE on SIGTERM.
srv=/mnt/kf2/server
data=/mnt/kf2/data
mkdir -p /usr/local/bin
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
for a in "$@"; do [ "${prev:-}" = "+force_install_dir" ] && dir="$a"; prev="$a"; done
echo "$*" >>/tmp/steamcmd-calls
[ -n "${dir}" ] || exit 0
case "$*" in
  *workshop_download_item*)
    for id in $(echo "$*" | grep -o 'workshop_download_item 232090 [0-9]*' | awk '{print $3}'); do
      mkdir -p "${dir}/steamapps/workshop/content/232090/${id}/BrewedPC"
      : >"${dir}/steamapps/workshop/content/232090/${id}/BrewedPC/KF-Workshop${id}.kfm"
      echo "Success. Downloaded item ${id} to \"${dir}/steamapps/workshop/content/232090/${id}\" (1 bytes)"
    done
    exit 0 ;;
esac
if [ ! -f /tmp/.first-failed ]; then touch /tmp/.first-failed; echo "ERROR! Failed to install app '232130' (Missing configuration)"; exit 8; fi
mkdir -p "${dir}/steamapps" "${dir}/Binaries/Win64/lib64" "${dir}/KFGame/BrewedPC/Maps" "${dir}/KFGame/Logs"
cp /opt/standin/server.py "${dir}/Binaries/Win64/KFGameSteamServer.bin.x86_64"
chmod +x "${dir}/Binaries/Win64/KFGameSteamServer.bin.x86_64"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_232130.acf"
if [ -f /tmp/.installed ]; then echo "Success! App '232130' already up to date."; else touch /tmp/.installed; echo "Success! App '232130' fully installed."; fi
STUB
chmod +x /usr/local/bin/steamcmd
mkdir -p /opt/standin
cat >/opt/standin/server.py <<'GAME'
#!/usr/bin/env python3
import http.server, os, re, signal, socket, sys, threading, time
args = sys.argv[1:]
def opt(name, default=""):
    for a in args:
        if a.lower().startswith("-%s=" % name.lower()):
            return a.split("=", 1)[1]
    return default
port, qport, sub = int(opt("port", "7777")), int(opt("QueryPort", "27015")), opt("ConfigSubDir")
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[0]))))
cfgdir = os.path.join(os.getcwd(), "KFGame", "Config", sub)
def ini(name):
    d = {}
    try:
        for line in open(os.path.join(cfgdir, name), encoding="utf-8-sig"):
            if "=" in line and not line.startswith("["):
                k, v = line.strip().split("=", 1)
                d[k] = v
    except OSError:
        pass
    return d
# Like the real game: with no engine ini in the config folder it writes the whole file (a partial one makes it abort).
eng = os.path.join(cfgdir, "LinuxServer-KFEngine.ini")
if not os.path.exists(eng):
    open(eng, "w").write("[IpDrv.TcpNetDriver]\n" + "".join("Key%d=%d\n" % (i, i) for i in range(300)))
game, web = ini("LinuxServer-KFGame.ini"), ini("KFWeb.ini")
name = game.get("ServerName", "Killing Floor 2 Server")
print("Init: Command line: SERVER  " + " ".join(args), flush=True)
print("DevOnline: Advertising: NumWaves=4", flush=True)
print("Init: LD_LIBRARY_PATH=%s" % os.environ.get("LD_LIBRARY_PATH", ""), flush=True)
print("Init: DISPLAY=%s" % os.environ.get("DISPLAY", "unset"), flush=True)
print("Init: name=%s adminpw=%s port=%d qport=%d map=%s subdir=%s webenabled=%s" % (name, game.get("AdminPassword", ""), port, qport, args[0].split("?")[0], sub, web.get("bEnabled")), flush=True)
mp = re.search(r"MaxPlayers=(\d+)", args[0]); print("Init: maxplayers=%s url=%s" % (mp.group(1) if mp else "?", args[0]), flush=True)
os.makedirs(os.path.join(os.getcwd(), "KFGame", "Logs"), exist_ok=True)
signal.signal(signal.SIGINT, lambda *_: os._exit(0))
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
mapname = args[0].split("?")[0]
players = 1 if os.environ.get("STANDIN_PLAYER") else 0
def info():
    b = lambda s: s.encode() + b"\x00"
    return (b"\xff\xff\xff\xffI\x11" + b(name) + b(mapname) + b("kf2") + b("Survival") + b"\x5a\x38" + bytes([players, 6, 0]) + b"dw\x00\x01" + b("1150") + b"\x00")
def serve_q():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", qport))
    while True:
        data, addr = s.recvfrom(100)
        if data == b"\xff\xff\xff\xffTSource Engine Query\x00":
            s.sendto(b"\xff\xff\xff\xffA\x01\x02\x03\x04", addr)
        elif data.startswith(b"\xff\xff\xff\xffTSource Engine Query\x00") and data.endswith(b"\x01\x02\x03\x04"):
            s.sendto(info(), addr)
time.sleep(float(os.environ.get("STANDIN_BOOT", "1.0")))   # the real one answers about 10 s after the process starts
print("DevNet: TcpNetDriver listening on port %d" % port, flush=True)
threading.Thread(target=serve_q, daemon=True).start()
while True:
    time.sleep(1)
GAME
chmod +x /opt/standin/server.py
export PATH="/usr/local/bin:${PATH}"

export FLUX_NO_NETWORK=1 FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 KF2_SERVER_NAME="Image Test" KF2_MAX_PLAYERS=10 \
  KF2_GAME_PORT=31000 KF2_QUERY_PORT=31001 KF2_WEB_PORT=31002 KF2_ADMIN_PASSWORD=hunter2 KF2_WORKSHOP_IDS=111111 KF2_GAME_MODE=endless STANDIN_PLAYER=1
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up (its query port answers)" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 40)"
check "a fresh SteamCMD's first failure is retried without validate" "0" "$(grep -c validate /tmp/steamcmd-calls)"
check "the install asks for the Windows platform (Linux answers Missing configuration)" "1" "$([ "$(grep -c 'ForcePlatformType windows' /tmp/steamcmd-calls)" -ge 2 ] && echo 1 || echo 0)"
check "the workshop item was downloaded with SteamCMD" "1" "$(grep -c 'workshop_download_item 232090 111111' /tmp/steamcmd-calls)"
check "the first start let the game write its files before the settings that live in them" "1" "$(grep -c 'letting the game write its default files' /tmp/entry.log)"
check "and the workshop list from the environment reached the engine ini after that" "1" "$(grep -c '^ServerSubscribedWorkshopItems=111111$' "${data}/Config/flux/LinuxServer-KFEngine.ini")"
check "and linked where the game loads maps" "0" "$(status test -L "${srv}/KFGame/BrewedPC/Maps/KF-Workshop111111.kfm")"
check "no display, no Wine" "1" "$(grep -c 'DISPLAY=unset' /tmp/entry.log)"
check "the game's libraries are on the library path" "1" "$(grep -c "LD_LIBRARY_PATH=${srv}/Binaries/Win64/lib64" /tmp/entry.log)"
check "the config folder is linked to the data volume" "${data}/Config/flux" "$(readlink "${srv}/KFGame/Config/flux")"
check "the game is told to use it" "1" "$(grep -c 'subdir=flux' /tmp/entry.log)"
check "the name, password, map and ports reached the server" "1" "$(grep -c 'name=Image Test adminpw=hunter2 port=31000 qport=31001 map=KF-BioticsLab' /tmp/entry.log)"
check "the web admin is on when there is an admin password" "1" "$(grep -c 'webenabled=true' /tmp/entry.log)"
check "mode and slots are in the first argument" "1" "$(grep -c 'maxplayers=10 url=KF-BioticsLab?Game=KFGameContent.KFGameInfo_Endless?MaxPlayers=10' /tmp/entry.log)"
check "and the status" "Image Test" "$(flux-kf2 status | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverName"])')"
check "the ports are the environment's" "31000 31001 31002" "$(flux-kf2 status | python3 -c 'import json,sys;d=json.load(sys.stdin)["ports"];print(d["game"],d["query"],d["web"])')"
check "the player count comes from the Steam query" "1" "$(flux-kf2 status | python3 -c 'import json,sys;print(json.load(sys.stdin)["playerCount"])')"
check "and the map" "KF-BioticsLab" "$(flux-kf2 status | python3 -c 'import json,sys;print(json.load(sys.stdin)["map"])')"
check "the container log has no Advertising noise" "0" "$(grep -c 'DevOnline: Advertising' /tmp/entry.log)"
check "but the game's lines reach it" "1" "$(grep -c 'listening on port 31000' /tmp/entry.log)"
check "the password is not on the command line" "0" "$(grep -c hunter2 /tmp/entry.log | awk '{print ($1 > 1) ? 1 : 0}')"
check "the password is in the settings file" "1" "$(grep -c '^AdminPassword=hunter2$' "${data}/Config/flux/LinuxServer-KFGame.ini")"
check "the game log is on the install volume" "0" "$(status test -s "${srv}/flux-logs/current.log")"
check "the ready check passes (the query port answers)" "0" "$(status flux-kf2 ready)"

# A restart through the panel: the new setting is in the ini, and nothing counts as a crash.
flux-kf2 set-settings '{"values": {"ServerName": "Second Name", "Difficulty": "hard"}}' >/dev/null
flux-kf2 restart >/dev/null
check "a panel restart starts again with the new setting" "0" "$(status wait_for '[ "$(flux-kf2 status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"],d[\"serverName\"])")" = "running 2 Second Name" ]' 40)"
check "the difficulty is in the launch line" "1" "$(grep -c 'Difficulty=1' /tmp/entry.log | awk '{print ($1 >= 1) ? 1 : 0}')"
check "the restart was not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "an up-to-date install is not retried" "0" "$(grep -c 'steamcmd failed' /tmp/entry.log | awk '{print ($1 > 1) ? 1 : 0}')"

# The workshop list changed from the panel: the next start downloads and links the new item and unlinks the old.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
flux-kf2 set-mods '{"ids": ["222222"]}' >/dev/null
flux-kf2 restart >/dev/null
check "a new workshop item is linked after a restart" "0" "$(status wait_for 'test -L "${srv}/KFGame/BrewedPC/Maps/KF-Workshop222222.kfm"' 40)"
check "and the dropped item's link is gone" "1" "$(status test -L "${srv}/KFGame/BrewedPC/Maps/KF-Workshop111111.kfm")"
check "the engine ini lists the item for the clients" "1" "$(grep -c '^ServerSubscribedWorkshopItems=222222$' "${data}/Config/flux/LinuxServer-KFEngine.ini")"

# A restore through the panel's command.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
flux-kf2 backup "test" force >/dev/null
backup="$(flux-kf2 backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
check "restore restarts the running server" "True" "$(flux-kf2 restore "${backup}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["restarting"])')"
check "and the next start restored it" "0" "$(status wait_for '[ "$(flux-kf2 status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"], d[\"lastRestore\"][\"ok\"])")" = "running True" ]' 40)"

# A crash: restarted in place.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
gen="$(flux-kf2 status | python3 -c 'import json,sys;print(json.load(sys.stdin)["generation"])')"
pkill -KILL -f '[K]FGameSteamServer\.bin\.x86_64'
check "a crashed server is started again" "0" "$(status wait_for '[ "$(flux-kf2 status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"])")" = "running '$((gen + 1))'" ]' 40)"

# A stop from Docker.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
start="$(date +%s)"
kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "inside Docker's 10 seconds" "0" "$(status test $(($(date +%s) - start)) -le 6)"
check "and says stopped" "stopped" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/flux/state.json"))["state"])')"
check "nothing of the server is left" "1" "$(status pgrep -f '[K]FGameSteamServer\.bin\.x86_64')"

# No admin password: the web admin is off (it cannot be used without one) and the state says nothing is wrong.
rm -rf "${data}/Config" "${data}/flux"
(unset KF2_ADMIN_PASSWORD KF2_WORKSHOP_IDS KF2_GAME_MODE; STANDIN_PLAYER='' /opt/flux/flux-entrypoint.sh >/tmp/entry3.log 2>&1) &
check "with no admin password the server still comes up" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 40)"
check "with the web admin off" "1" "$(grep -c 'webenabled=false' /tmp/entry3.log)"
check "and a note says why" "1" "$(grep -c 'no admin password' /tmp/entry3.log | awk '{print ($1 >= 1) ? 1 : 0}')"
check "the first-run ini is the seed the game completes" "1" "$(grep -c '^ServerName=Image Test$' "${data}/Config/flux/LinuxServer-KFGame.ini")"
pkill -TERM -f 'flux-entrypoint.sh'
wait_for '! pgrep -f flux-entrypoint.sh >/dev/null' 15

# A port the server cannot use is not a crash: the state says what to change and nothing restarts.
rm -rf "${data}/flux/state.json"
KF2_GAME_PORT=80 /opt/flux/flux-entrypoint.sh >/tmp/entry2.log 2>&1 &
entry2=$!
check "a bad port gives the needs-fix state" "0" "$(status wait_for 'grep -q "needs-fix" ${data}/flux/state.json 2>/dev/null' 20)"
check "that names the variable" "1" "$(grep -c 'KF2_GAME_PORT=80' ${data}/flux/state.json)"
check "and keeps the supervisor alive" "0" "$(status kill -0 ${entry2})"
kill -TERM "${entry2}"
check "a stop ends it" "0" "$(status wait_for '! kill -0 ${entry2} 2>/dev/null' 10)"

# --- flux.log is local; the banner ----------------------------------------------------------------
check "flux.log is on the install volume" "0" "$(status test -s "${srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "${data}/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q 'Killing Floor 2 server image by FluxCloud - https://runonflux.com' /tmp/entry.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/entry.log)" -ge 2 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
