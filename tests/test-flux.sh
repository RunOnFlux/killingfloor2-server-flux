#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxkf2.py's file handling. No Docker, no
# Steam, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export TZ=UTC

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

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
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Inputs ------------------------------------------------------------------------------------
check "7777 is a port" "7777" "$(flux_port 7777 1)"
check "empty takes the default" "27015" "$(flux_port '' 27015)"
check "a leading zero is not octal" "9700" "$(flux_port 09700 1)"
check "port 80 is refused" "1" "$(status flux_port 80 1)"
check "a word is not a port" "1" "$(status flux_port abc 1)"
check "distinct ports" "0" "$(status flux_ports_distinct 7777 27015)"
check "a port used twice" "1" "$(status flux_ports_distinct 7777 7777)"
check "restart time 5:00" "05:00" "$(flux_restart_time 5:00)"
check "restart time off" "" "$(flux_restart_time off)"
check "restart time 24:00 refused" "1" "$(status flux_restart_time 24:00)"
# 2026-10-11 12:00 UTC = 1791720000
check "next 05:00 after noon is tomorrow" "$((1791720000 - 43200 + 86400 + 18000))" "$(flux_next_daily 1791720000 05:00)"
check "next 13:30 after noon is today" "$((1791720000 + 5400))" "$(flux_next_daily 1791720000 13:30)"
check "the game is found by its binary name" "KFGameSteamServer.bin.x86_64" "$(printf 'x\n./Binaries/Win64/KFGameSteamServer.bin.x86_64 kf-bioticslab?Game=x -Port=7777\n' | grep -o -E "${FLUX_GAME_PATTERN}")"
check "and pgrep's own command line is not" "1" "$(status bash -c "echo 'pgrep -f ${FLUX_GAME_PATTERN}' | grep -q -E '${FLUX_GAME_PATTERN}'")"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts drop out of the window" "950 990" "$(flux_restarts_in_window 1000 100 800 950 990)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "a game update does not count" "1" "$(status flux_restart_counts 'planned: game update 1 -> 2')"
check "a panel restart does not count" "1" "$(status flux_restart_counts 'requested: from the panel')"
check "prune keeps the newest" "c d" "$(flux_files_to_prune 2 a b c d | tr '\n' ' ' | sed 's/ $//')"
check "marker notbefore" "123" "$(printf 'x\nnotbefore=123\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"
check "marker without notbefore" "0" "$(printf 'x\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"

# --- Log noise and passwords -------------------------------------------------------------------
check "advertising echoes are noise" "0" "$(status flux_noise <<<"[0005.67] DevOnline: Advertising: MatchQuality=0.000000")"
check "the published settings refresh is noise" "0" "$(status flux_noise <<<"[0006.07] DevOnline: Server data: Ver: 9189, Ded: 0, Region: 255, Slots: 6")"
check "zed preloading is noise" "0" "$(status flux_noise <<<"[0003.88] Log: AKFPawn_Monster::PreloadContent - Checking Modes...")"
check "movie stream warnings are noise" "0" "$(status flux_noise <<<"[0001.64] Warning: Invalid movie stream data for TextureMovie UI_Managers.IIS")"
check "blank lines are noise" "0" "$(status flux_noise <<<"   ")"
check "the listening line is not noise" "1" "$(status flux_noise <<<"[0003.75] DevNet: TcpNetDriver_0 TcpNetDriver listening on port 7777")"
check "a player joining is not noise" "1" "$(status flux_noise <<<"[0100.00] DevNet: Join succeeded: Alice")"
check "a crash is not noise" "1" "$(status flux_noise <<<"Unhandled exception: SIGSEGV: invalid attempt to access memory")"
check "passwords in the url are redacted" 'Init: Command line: SERVER  KF-X?Game=y?AdminPassword=*** -Port=7777' "$(echo 'Init: Command line: SERVER  KF-X?Game=y?AdminPassword=hunter2 -Port=7777' | flux_redact)"
check "and a dash option's" 'x -AdminPassword=*** y' "$(echo 'x -AdminPassword=hunter2 y' | flux_redact)"

# --- Steam builds ------------------------------------------------------------------------------
printf '"AppState"\n{\n\t"appid"\t\t"232130"\n\t"buildid"\t\t"14007421"\n}\n' >"${tmp}/manifest.acf"
check "installed build" "14007421" "$(flux_installed_build "${tmp}/manifest.acf")"
check "public build from app_info" "14100000" "$(printf '%s\n' '"232130"' '{' '"depots"' '{' '"branches"' '{' '"public"' '{' '"buildid"		"14100000"' '}' | flux_public_build)"

# --- fluxkf2.py ------------------------------------------------------------------------------
data="${tmp}/data"
server="${tmp}/server"
mkdir -p "${server}/steamapps" "${server}/KFGame/Config" "${server}/KFGame/BrewedPC/Maps"
cp "${tmp}/manifest.acf" "${server}/steamapps/appmanifest_232130.acf"
ic() { # VAR=value... command args: fluxkf2.py with exactly these variables
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" HOME="${tmp}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${server}" \
    FLUX_RESTART_MARKER="${tmp}/restart-marker" FLUX_NO_NETWORK=1 "${vars[@]}" python3 scripts/fluxkf2.py "$@"
}
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(d if not isinstance(d,(dict,list)) else json.dumps(d))' "$1"; }
cfg="${data}/Config/flux"
gameini="${cfg}/LinuxServer-KFGame.ini"
engineini="${cfg}/LinuxServer-KFEngine.ini"
inival() { tr -d '\r' <"$2" | sed -n "s/^$1=//p" | head -1; }

# A game ini the way the game writes it after its first start (the real file has 1000 lines; these are the sections we edit).
mkdir -p "${cfg}"
cat >"${cfg}/.game-template" <<'INI'
[Engine.GameInfo]
MaxPlayers=12
bAdminCanPause=false
MaxSpectators=2

[Engine.AccessControl]
bAuthenticateClients=True
AdminPassword=
GamePassword=
BannedIDs=(Uid=(A=39734273,B=17825793))

[KFGame.KFGameInfo]
GameLength=0
bUseMapList=True
ActiveMapCycle=0
GameMapCycles=(Maps=("KF-Airship","KF-BioticsLab","KF-Catacombs"))
FriendlyFireScale=0.000000
ServerMOTD=Welcome to our server. \n \n Have fun and good luck!

[KF-Airship KFMapSummary]
MapName=KF-Airship

[KF-BioticsLab KFMapSummary]
MapName=KF-BioticsLab

[KF-Default KFMapSummary]
MapName=KF-Default

[Engine.GameReplicationInfo]
ServerName=Killing Floor 2 Server
ShortName=KFServer
INI
cat >"${cfg}/.engine-template" <<'INI'
[IpDrv.TcpNetDriver]
MaxClientRate=15000
DownloadManagers=IpDrv.HTTPDownload
DownloadManagers=Engine.ChannelDownload
NetServerMaxTickRate=30.0

[Other.Section]
x=1
INI

# First start: no ini yet. apply seeds it; the game completes it.
ic apply >"${tmp}/apply.out"
check "apply links the game's config folder to the data volume" "${data}/Config/flux" "$(readlink "${server}/KFGame/Config/flux")"
check "a first start seeds the ini with the server name" "Killing Floor 2 Server" "$(inival ServerName "${gameini}")"
check "the web admin is off without an admin password" "false" "$(inival bEnabled "${cfg}/KFWeb.ini")"
check "and says why" "1" "$(grep -c 'no admin password' "${tmp}/apply.out")"
check "the state records the ports" "7777 27015 8080" "$(jget gamePort <"${data}/flux/state.json") $(jget queryPort <"${data}/flux/state.json") $(jget webPort <"${data}/flux/state.json")"
check "the default launch line" "KF-BioticsLab?Game=KFGameContent.KFGameInfo_Survival?MaxPlayers=6?Difficulty=0?GameLength=0 -Port=7777 -QueryPort=27015 -ConfigSubDir=flux -NoHomeDir" "$(ic args | tr '\n' ' ' | sed 's/ $//')"

check "the engine ini is never seeded (a partial one makes the game abort)" "1" "$(status test -e "${cfg}/LinuxServer-KFEngine.ini")"
check "so the supervisor is told to let the game write it" "0" "$(status ic needs-bootstrap)"
check "a setting that lives in it waits, pending, until the game has written it" "True" "$(ic set-settings '{"values": {"NetServerMaxTickRate": 60}}' >/dev/null; ic apply >/dev/null; ic status | jget pending)"
rm -f "${data}/flux/pending.json"
check "the workshop list is kept in flux/mods.json meanwhile" "111111" "$(ic KF2_WORKSHOP_IDS=111111 apply >/dev/null; ic mods-ids)"
rm -f "${data}/flux/mods.json" "${data}/flux/env-applied.json"

# From now on, the game's own ini.
cp "${cfg}/.game-template" "${gameini}"
cp "${cfg}/.engine-template" "${engineini}"
rm -f "${data}/flux/env-applied.json"
ic KF2_SERVER_NAME="Lab One" KF2_MAX_PLAYERS=12 KF2_ADMIN_PASSWORD=adm1 KF2_JOIN_PASSWORD=pw1 KF2_GAME_MODE=endless KF2_DIFFICULTY=suicidal KF2_GAME_PORT=31000 KF2_QUERY_PORT=31001 KF2_WEB_PORT=31002 apply >/dev/null
check "no bootstrap once the engine ini is there" "1" "$(status ic needs-bootstrap)"
check "env sets the name" "Lab One" "$(inival ServerName "${gameini}")"
check "env sets the admin password" "adm1" "$(inival AdminPassword "${gameini}")"
check "env sets the join password" "pw1" "$(inival GamePassword "${gameini}")"
check "the name goes in its own section, the other rows stay" "KFServer" "$(inival ShortName "${gameini}")"
check "the web admin is on with an admin password, on its port" "true 31002" "$(inival bEnabled "${cfg}/KFWeb.ini") $(inival ListenPort "${cfg}/KFWeb.ini")"
check "env sets the launch line" "KF-BioticsLab?Game=KFGameContent.KFGameInfo_Endless?MaxPlayers=12?Difficulty=2 -Port=31000 -QueryPort=31001 -ConfigSubDir=flux -NoHomeDir" "$(ic KF2_GAME_PORT=31000 KF2_QUERY_PORT=31001 args | tr '\n' ' ' | sed 's/ $//')"
check "Endless has no game length option" "0" "$(ic args | grep -c GameLength)"
ic set-settings '{"values": {"GameMode": "survival", "GameLength": "long"}}' >/dev/null
check "survival takes a length (long is 2)" "1" "$(ic args | head -1 | grep -c 'GameLength=2')"
check "versus takes neither difficulty nor length" "0" "$(ic set-settings '{"values": {"GameMode": "versus"}}' >/dev/null; ic args | head -1 | grep -c -E 'Difficulty|GameLength')"
ic set-settings '{"values": {"GameMode": "survival"}}' >/dev/null
check "extra arguments are added" "1" "$(ic KF2_EXTRA_ARGS='-MULTIHOME=1.2.3.4' args | grep -c '^-MULTIHOME=1.2.3.4$')"
check "but not ones that would fight the image's own" "0" "$(ic KF2_EXTRA_ARGS='-Port=1 -ConfigSubDir=x -NoHomeDir' args | grep -c -E '^-Port=1$|ConfigSubDir=x')"
ic set-settings '{"values": {"ServerName": "Panel Name"}}' >/dev/null
ic KF2_SERVER_NAME="Lab One" apply >/dev/null
check "the same env value does not undo a panel change" "Panel Name" "$(inival ServerName "${gameini}")"
ic KF2_SERVER_NAME="Lab Two" apply >/dev/null
check "a changed env value applies" "Lab Two" "$(inival ServerName "${gameini}")"
check "an empty env value leaves the setting" "Lab Two" "$(ic KF2_SERVER_NAME= apply >/dev/null; inival ServerName "${gameini}")"
check "a port below 1024 is refused" "2" "$(status ic KF2_GAME_PORT=80 apply)"
check "the game and query port must differ" "2" "$(status ic KF2_GAME_PORT=7777 KF2_QUERY_PORT=7777 apply)"

# --- Settings ----------------------------------------------------------------------------------
check "settings lists the form's keys" "True" "$(ic settings | python3 -c 'import json,sys;k={s["key"] for s in json.load(sys.stdin)["settings"]};print({"ServerName","MaxPlayers","Difficulty","FriendlyFireScale","NetServerMaxTickRate"} <= k)')"
check "the passwords are never returned" "" "$(ic settings | python3 -c 'import json,sys;print("".join(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"] in ("AdminPassword","GamePassword")))')"
check "but whether a join password is set is" "True" "$(ic settings | jget passworded)"
check "selects carry their options" "normal hard suicidal hell" "$(ic settings | python3 -c 'import json,sys;print(" ".join([s for s in json.load(sys.stdin)["settings"] if s["key"]=="Difficulty"][0]["options"]))')"
ic set-settings '{"values": {"FriendlyFireScale": 0.5, "bDisablePickups": true, "ReadyUpDelay": 30, "NetServerMaxTickRate": 60}}' >/dev/null
# THE RUNNING GAME REWRITES ITS INI: a panel edit waits in flux/pending.json until apply (before a start).
check "a panel edit is not written into the ini while the game may be running" "0.000000" "$(inival FriendlyFireScale "${gameini}")"
check "but the form shows it" "0.500000" "$(ic settings | python3 -c 'import json,sys;print([s for s in json.load(sys.stdin)["settings"] if s["key"]=="FriendlyFireScale"][0]["value"])')"
check "and the status says a restart applies something" "True" "$(ic status | jget pending)"
ic apply >/dev/null
check "apply writes it" "0.500000" "$(inival FriendlyFireScale "${gameini}")"
check "and nothing is pending any more" "False" "$(ic status | jget pending)"
check "a float is written the way the game writes it" "0.500000" "$(inival FriendlyFireScale "${gameini}")"
check "a toggle" "True" "$(inival bDisablePickups "${gameini}")"
check "a whole number" "30" "$(inival ReadyUpDelay "${gameini}")"
check "the tick rate goes in the engine ini" "60.000000" "$(inival NetServerMaxTickRate "${engineini}")"
check "and nothing else in that file moved" "15000" "$(inival MaxClientRate "${engineini}")"
check "an unknown key is refused" "1" "$(status ic set-settings '{"values": {"Bogus": 1}}')"
check "a bad number is refused" "1" "$(status ic set-settings '{"values": {"ReadyUpDelay": "soon"}}')"
check "a ratio above 1 is refused" "1" "$(status ic set-settings '{"values": {"FriendlyFireScale": 2}}')"
check "a select outside its options is refused" "1" "$(status ic set-settings '{"values": {"Difficulty": "easy"}}')"
check "a password with a space is refused" "1" "$(status ic set-settings '{"values": {"AdminPassword": "a b"}}')"
check "a name with a question mark is refused (it would break the launch line)" "1" "$(status ic set-settings '{"values": {"ServerName": "a?b"}}')"
check "more slots than the game has are refused" "1" "$(status ic set-settings '{"values": {"MaxPlayers": 13}}')"
check "the start map is the Maps tab's, not the form's" "1" "$(status ic set-settings '{"values": {"StartMap": "KF-Airship"}}')"
check "a refused batch changes nothing" "0.500000" "$(ic set-settings '{"values": {"FriendlyFireScale": 0.1, "Bogus": 1}}' >/dev/null; inival FriendlyFireScale "${gameini}")"

# --- Maps --------------------------------------------------------------------------------------
check "the official maps are the game's own list (without the default entry)" "KF-Airship KF-BioticsLab" "$(ic maps | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["official"]))')"
check "the map cycle is read" "KF-Airship KF-BioticsLab KF-Catacombs" "$(ic maps | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["cycle"]))')"
ic set-maps '{"cycle": ["KF-Catacombs", "KF-Airship"], "start": "KF-Catacombs"}' >/dev/null
check "the map tab shows the new cycle at once" "KF-Catacombs KF-Airship" "$(ic maps | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["cycle"]))')"
ic apply >/dev/null
check "a new cycle is written as the game reads it" '(Maps=("KF-Catacombs","KF-Airship"))' "$(inival GameMapCycles "${gameini}")"
check "the start map is the first argument" "1" "$(ic args | head -1 | grep -c '^KF-Catacombs?Game=')"
check "an invalid map name is refused" "1" "$(status ic set-maps '{"cycle": ["KF-A b"]}')"
check "an empty cycle is refused" "1" "$(status ic set-maps '{"cycle": []}')"
mkdir -p "${server}/steamapps/workshop/content/232090/857015700/BrewedPC"
: >"${server}/steamapps/workshop/content/232090/857015700/BrewedPC/KF-MountainPass.kfm"
check "workshop maps are found in the downloaded items" "KF-MountainPass 857015700" "$(ic maps | python3 -c 'import json,sys;w=json.load(sys.stdin)["workshop"][0];print(w["name"],w["item"])')"

# --- Workshop items ----------------------------------------------------------------------------
check "a workshop link is accepted" "857015700" "$(ic set-mods '{"ids": ["https://steamcommunity.com/sharedfiles/filedetails/?id=857015700"]}' >/dev/null; ic mods-ids)"
check "the engine ini is not touched while the game may be running" "0" "$(grep -c 'ServerSubscribedWorkshopItems' "${engineini}")"
ic apply >/dev/null
check "the engine ini lists it for the clients" "857015700" "$(inival ServerSubscribedWorkshopItems "${engineini}")"
check "the workshop download manager comes first" "OnlineSubsystemSteamworks.SteamWorkshopDownload" "$(inival DownloadManagers "${engineini}")"
check "the game's own download managers stay" "3" "$(grep -c '^DownloadManagers=' "${engineini}")"
check "the other sections are untouched" "1" "$(inival x "${engineini}")"
check "a word is not an item" "1" "$(status ic set-mods '{"ids": ["abc"]}')"
check "too many items are refused" "1" "$(status ic set-mods "{\"ids\": [$(seq -s, 100001 100030)]}")"
check "the env list applies when it changes" "111111 222222" "$(ic KF2_WORKSHOP_IDS='111111, 222222' apply >/dev/null; ic mods-ids | tr '\n' ' ' | sed 's/ $//')"
check "and not again when the panel changed it" "333333" "$(ic set-mods '{"ids": ["333333"]}' >/dev/null; ic KF2_WORKSHOP_IDS='111111, 222222' apply >/dev/null; ic mods-ids)"
check "clearing the list removes the rows and the manager" "0" "$(ic set-mods '{"ids": []}' >/dev/null; ic apply >/dev/null; grep -c -E 'ServerSubscribedWorkshopItems=|SteamWorkshopDownload' "${engineini}")"
ic set-mods '{"ids": ["857015700"]}' >/dev/null
ic mods-install >/dev/null
check "mods-install links the map into the game's Maps folder" "0" "$(status test -L "${server}/KFGame/BrewedPC/Maps/KF-MountainPass.kfm")"
ic set-mods '{"ids": []}' >/dev/null
ic mods-install >/dev/null
check "and removes the link of an item no longer listed" "1" "$(status test -L "${server}/KFGame/BrewedPC/Maps/KF-MountainPass.kfm")"
printf 'real' >"${server}/KFGame/BrewedPC/Maps/KF-MountainPass.kfm"
ic set-mods '{"ids": ["857015700"]}' >/dev/null
check "a game file of the same name is never replaced" "real" "$(ic mods-install >/dev/null; cat "${server}/KFGame/BrewedPC/Maps/KF-MountainPass.kfm")"
rm -f "${server}/KFGame/BrewedPC/Maps/KF-MountainPass.kfm"

# --- Bans (the ini when the server is down) ----------------------------------------------------
check "the ini's ban is read as a SteamID64" "76561198000000001" "$(ic bans | jget banned.0)"
check "a ban is written as the two halves the game keeps" "1" "$(ic ban-id 76561198000000002 >/dev/null; grep -c '^BannedIDs=(Uid=(A=39734274,B=17825793))$' "${gameini}")"
check "the earlier ban stays" "2" "$(ic bans | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["banned"]))')"
check "a profile link is accepted" "0" "$(status ic ban-id https://steamcommunity.com/profiles/76561198000000003)"
check "an unban removes it" "0" "$(ic unban-id 76561198000000002 >/dev/null; grep -c 'A=39734274' "${gameini}")"
check "not a SteamID64 is refused" "1" "$(status ic ban-id 12345)"
check "a ban is refused while the game starts (the running process would overwrite the ini)" "1" "$(ic state starting >/dev/null; status ic ban-id 76561198000000007)"
ic state stopped >/dev/null
check "unbanning someone not banned is refused" "1" "$(status ic unban-id 76561198000000009)"

# --- The web admin's players page --------------------------------------------------------------
# The row the game's template (KFGame/Web/ServerAdmin/current_players_row.inc) renders, with the actions its select offers.
page='<table id="players" class="grid"><thead><tr><th>x</th></tr></thead><tbody>
<tr class="even">
  <td style="background: red;">0&#160;</td><td>Al &amp; Bo</td><td class="right">42</td><td>10.0.0.5</td><td>0x0110000100000001</td><td>76561198000000001</td><td>Alice</td><td class="center">Yes</td><td class="center"></td>
  <td><form method="post" action="/ServerAdmin/current/players"><div><input type="hidden" name="playerid" value="3" /><input type="hidden" name="playerkey" value="abc123" />
  <select name="action"><option value=""></option><option value="kick">Kick</option><option value="banip">Ban IP</option><option value="banid">Ban ID</option><option value="sessionban">Session ban</option></select></div></form></td>
</tr></tbody></table>'
check "a player row is parsed" "Al & Bo 42 76561198000000001 abc123 True" "$(python3 -I -c '
import sys; sys.path.insert(0, "scripts")
import fluxkf2 as f
p = f.parse_players(sys.argv[1])[0]
print(p["name"], p["ping"], p["steamId"], p["key"], p["admin"])' "${page}")"
check "kick is the kick action" "kick" "$(python3 -I -c '
import sys; sys.path.insert(0, "scripts")
import fluxkf2 as f
print(f.pick_action(f.parse_players(sys.argv[1])[0]["actions"], "kick"))' "${page}")"
check "ban is the account ban, not the IP one" "banid" "$(python3 -I -c '
import sys; sys.path.insert(0, "scripts")
import fluxkf2 as f
print(f.pick_action(f.parse_players(sys.argv[1])[0]["actions"], "ban"))' "${page}")"
check "an empty table has no players" "0" "$(python3 -I -c '
import sys; sys.path.insert(0, "scripts")
import fluxkf2 as f
print(len(f.parse_players("<table id=\"players\" class=\"grid\"><tbody><tr><td colspan=\"10\"><em>There are no players</em></td></tr></tbody></table>")))')"
check "without the server the players command answers, not live" "False" "$(ic players | jget live)"
check "and a live action says the web admin is not reachable" "1" "$(ic kick abc 2>&1 | grep -c 'not reachable')"

# --- The Steam query (a stand-in that answers like the real one: a challenge first) -------------
python3 - "${tmp}/q.port" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); open(sys.argv[1], "w").write(str(s.getsockname()[1]))
b = lambda t: t.encode() + b"\x00"
info = b"\xff\xff\xff\xffI\x11" + b("Lab") + b("KF-BIOTICSLAB") + b("kf2") + b("Survival") + b"\x5a\x38" + bytes([3, 6, 0]) + b"dw\x00\x01" + b("1150") + b"\x00"
for _ in range(2):
    data, addr = s.recvfrom(100)
    if data.endswith(b"\x00"):
        s.sendto(b"\xff\xff\xff\xffA\x01\x02\x03\x04", addr)
    else:
        s.sendto(info, addr)
PY
sleep 0.5
check "a2s: name, map and players" "Lab KF-BIOTICSLAB 3 6" "$(python3 -I -c '
import sys; sys.path.insert(0, "scripts")
import fluxkf2 as f
a = f.a2s_info(int(open(sys.argv[1]).read()))
print(a["name"], a["map"], a["players"], a["maxPlayers"])' "${tmp}/q.port")"
check "a2s: nothing listening is None" "None" "$(python3 -I -c '
import sys; sys.path.insert(0, "scripts")
import fluxkf2 as f
print(f.a2s_info(9, timeout=0.3))')"

# --- Backups -----------------------------------------------------------------------------------
check "a backup is made" "1" "$(ic backup first force >/dev/null; ic backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"]))')"
ic set-settings '{"values": {"ServerName": "After backup"}}' >/dev/null
backup="$(ic backups | jget backups.0.name)"
check "the backup holds the ini files and the panel's choices" "1" "$(tar -tzf "${data}/flux/backups/${backup}" | grep -c -E 'LinuxServer-KFGame.ini|flux/launch.json' | awk '{print ($1 >= 2) ? 1 : 0}')"
check "a restore is asked for" "True" "$(ic restore "${backup}" | jget ok)"
ic do-restore >/dev/null
check "and put back" "Lab Two" "$(inival ServerName "${gameini}")"
check "a restore drops the panel edits that were still waiting" "False" "$(ic set-settings '{"values": {"ServerName": "Waiting"}}' >/dev/null; ic restore "${backup}" >/dev/null; ic do-restore >/dev/null; ic status | jget pending)"
check "after a backup was made of the state before" "1" "$([ "$(ic backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"]))')" -ge 2 ] && echo 1 || echo 0)"
check "a path outside the backup folder is refused" "1" "$(status ic restore ../../etc/passwd)"
check "a backup too young is skipped" "1" "$(ic backup again | grep -c skipped)"

# --- Status and restart ------------------------------------------------------------------------
ic state running >/dev/null
check "status: state" "running" "$(ic status | jget state)"
check "status: build" "14007421" "$(ic status | jget build)"
check "status: mode" "survival" "$(ic status | jget mode)"
check "status: the query is not asked of a server that is not up" "None" "$(ic state starting >/dev/null; ic status | jget playerCount)"
check "a restart of a stopped server is refused" "1" "$(ic state stopped >/dev/null; status ic restart)"
ic state running >/dev/null
check "a restart writes the marker" "True" "$(ic restart | jget restarting)"
check "the marker is there" "0" "$(status test -f "${tmp}/restart-marker")"
rm -f "${tmp}/restart-marker"

# --- Game updates ------------------------------------------------------------------------------
ic update-target 14100000 >/dev/null
check "an update that did not install is recorded" "1" "$(ic update-check | grep -c 'did not install')"
check "and skipped for a while" "0" "$(status ic update-skip 14100000)"
check "another build is not skipped" "1" "$(status ic update-skip 14200000)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || exit 1
