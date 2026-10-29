#!/usr/bin/env python3
"""Every decision about the Killing Floor 2 server's files and launch line, and the hub's commands.

    fluxkf2.py apply              link the game's config folder to the data volume, settle the ini files
                                  (environment + panel), the map cycle, the workshop list; "# " notes on stdout
                                  (the entrypoint logs them); exit 2 when the environment holds something the
                                  server cannot use (needs-fix)
    fluxkf2.py args               the server's arguments, one per line (the entrypoint reads them)
    fluxkf2.py needs-bootstrap    exit 0 when the game has not written its engine ini yet (see the command)
    fluxkf2.py state <state> [msg]   record what the supervisor is doing (flux/state.json)
    fluxkf2.py mods-ids           the workshop item ids to download, one per line (the supervisor, before a start)
    fluxkf2.py mods-install       put the downloaded workshop items where the game loads them

    flux-kf2 status               state, players, build, map (one JSON document)
    flux-kf2 settings             every setting with its type, default and value
    flux-kf2 set-settings '<json>'   {"values": {"ServerName": "My server", "Difficulty": "hard"}}
    flux-kf2 maps                 the official and the workshop maps, the map cycle, the map the server starts on
    flux-kf2 set-maps '<json>'    {"cycle": ["KF-Airship", ...], "start": "KF-Airship"}
    flux-kf2 mods                 the workshop items (id, title, size, downloaded, maps)
    flux-kf2 set-mods '<json>'    {"ids": ["857015700", ...]}
    flux-kf2 players              who is on the server now (the game's WebAdmin) and the ban list
    flux-kf2 kick <playerkey> | ban <playerkey> | map-now <map> [mode]   live actions through WebAdmin
    flux-kf2 bans | ban-id <steamid64> | unban-id <steamid64>   the ban list (WebAdmin when up, the ini when not)
    flux-kf2 restart              stop and start the server again (applies the above)
    flux-kf2 backups | backup <why> | restore <backup>
    flux-kf2 a2s                  the Steam query port's answer (name, map, players), exit 1 when none

    fluxkf2.py backup <why> [force]   a backup (the supervisor)
    fluxkf2.py do-restore         apply a pending restore (the supervisor, before a start)
    fluxkf2.py note <key> [value]     a field of flux/state.json (nextRestart, updateWaiting)
    fluxkf2.py update-target <b> / update-check / update-skip <b>   game-update bookkeeping
    fluxkf2.py players-online     the number of players in the session, or nothing when not known

KILLING FLOOR 2 KEEPS NOTHING BUT SETTINGS. A match is not saved: a map is played to its last wave and the server
moves to the next one. What has to survive is the config folder (KFGame/Config/flux: LinuxServer-KFGame.ini with the
name, passwords, rules, ban list and map cycle; LinuxServer-KFEngine.ini with the workshop list and the tick rate;
KFWeb.ini with the web admin) and what the panel chose (flux/launch.json: mode, difficulty, length, start map; and
flux/mods.json). The server is started with -ConfigSubDir=flux, and the game merges a PARTIAL ini with its defaults
(measured: a 5 line seed became the full file with the seeded values kept), so the first start needs no bootstrap.

The ini files are the game's own and the single source of truth: the environment and the panel edit their lines in
place (nothing else in the file moves). BUT A RUNNING GAME REWRITES ITS INI FILES FROM MEMORY (at a ban, a map change,
a WebAdmin save; measured: a ServerName and a FriendlyFireScale edited while it ran were back to the old values after the
next restart). So the panel's edits are kept in flux/pending.json and written into the ini files by `apply`, which runs
before every start, when the game is not running. `settings`, `maps` and `status` show them as if applied. The launch options (mode, difficulty, length, max players, map) are not in
an ini the game honours on start; they are the first argument of the server and live in flux/launch.json.

ENVIRONMENT APPLIES WHEN IT CHANGES, as in our other images: a deploy's KF2_* value is written on the first start and
again whenever it is DIFFERENT from the value last applied (flux/env-applied.json), so a redeploy with a new name
renames the server while a name changed in the panel is not undone by the same old env on every start. The ports are
the exception: read on every start.
"""

import html
import json
import os
import re
import shutil
import socket
import struct
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/kf2/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/kf2/data")
GAME_DIR = os.environ.get("FLUX_GAME_DIR", os.path.join(SERVER_DIR, "KFGame"))
CONFIG_SUBDIR = "flux"
# The game's config folder for -ConfigSubDir=flux is a symlink to this folder on the data volume (synced).
CONFIG_DATA = os.path.join(DATA_DIR, "Config", CONFIG_SUBDIR)
CONFIG_LINK = os.path.join(GAME_DIR, "Config", CONFIG_SUBDIR)
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
ENV_APPLIED_FILE = os.path.join(STATE_DIR, "env-applied.json")
LAUNCH_FILE = os.path.join(STATE_DIR, "launch.json")
MODS_FILE = os.path.join(STATE_DIR, "mods.json")
PENDING_FILE = os.path.join(STATE_DIR, "pending.json")
MODS_CACHE_FILE = os.path.join(SERVER_DIR, "flux-logs", "mods-cache.json")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
BACKUP_INDEX = os.path.join(BACKUP_DIR, "index.json")
RESTORE_FILE = os.path.join(STATE_DIR, "restore-pending.json")
LAST_RESTORE_FILE = os.path.join(STATE_DIR, "last-restore.json")
UPDATE_TARGET_FILE = os.path.join(STATE_DIR, "update-target.json")
UPDATE_FAILED_FILE = os.path.join(STATE_DIR, "update-failed.json")
UPDATE_FAILED_SKIP = 6 * 3600
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
STEAM_APP = os.environ.get("FLUX_STEAM_APP", "232130")
WORKSHOP_APP = "232090"   # the game's own app: workshop items belong to it, not to the server tool
WORKSHOP_DIR = os.path.join(SERVER_DIR, "steamapps", "workshop", "content", WORKSHOP_APP)
MAPS_DIR = os.path.join(GAME_DIR, "BrewedPC", "Maps")
BREWED_DIR = os.path.join(GAME_DIR, "BrewedPC")
BACKUP_NAME_RE = re.compile(r"^\d{8}-\d{6}-kf2\.tar\.gz$")
SETTLE_SECONDS = 5

DEFAULT_GAME_PORT = 7777
DEFAULT_QUERY_PORT = 27015
DEFAULT_WEB_PORT = 8080
MAX_PLAYERS_CAP = 12       # the game clamps ?MaxPlayers to its MaxPlayersAllowed: 6 in Survival, Weekly, Endless and Objective, 12 in Versus (measured: a value of 12 gave "0/6" in all but Versus)
MAX_MODS = 20
MODS_NOTE_LIMIT = 400      # characters of KF2_WORKSHOP_IDS

GAME_INI = "LinuxServer-KFGame.ini"
ENGINE_INI = "LinuxServer-KFEngine.ini"
WEB_INI = "KFWeb.ini"

MODES = {
    "survival": ("KFGameContent.KFGameInfo_Survival", "Survival"),
    "weekly": ("KFGameContent.KFGameInfo_WeeklySurvival", "Weekly Outbreak"),
    "endless": ("KFGameContent.KFGameInfo_Endless", "Endless"),
    "versus": ("KFGameContent.KFGameInfo_VersusSurvival", "Versus Survival"),
    "objective": ("KFGameContent.KFGameInfo_Objective", "Objective"),
}
DIFFICULTIES = {"normal": 0, "hard": 1, "suicidal": 2, "hell": 3}
LENGTHS = {"short": 0, "medium": 1, "long": 2}
DEFAULT_MAP = "KF-BioticsLab"
MAP_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_\-]{0,63}$")
STEAM_ID_RE = re.compile(r"^7656119\d{10}$")
WORKSHOP_ID_RE = re.compile(r"^\d{5,12}$")

# env variable -> setting key
ENV_KEYS = {
    "KF2_SERVER_NAME": "ServerName",
    "KF2_ADMIN_PASSWORD": "AdminPassword",
    "KF2_JOIN_PASSWORD": "GamePassword",
    "KF2_MAX_PLAYERS": "MaxPlayers",
    "KF2_GAME_MODE": "GameMode",
    "KF2_DIFFICULTY": "Difficulty",
    "KF2_GAME_LENGTH": "GameLength",
    "KF2_START_MAP": "StartMap",
}
ENV_MODS = "KF2_WORKSHOP_IDS"
SECRET_KEYS = {"AdminPassword", "GamePassword"}

# The settings. `file` is "game" or "engine" (an ini of the config folder) or "launch" (the first argument of
# the server). `section` and `name` are the ini's, `type` is bool | int | float | text | select, `default` is
# what the game ships. Every ini row here was checked to exist in the generated LinuxServer-KFGame.ini /
# LinuxServer-KFEngine.ini of build 14007421 (game 1150).
S = "Engine.GameReplicationInfo"
A = "Engine.AccessControl"
G = "KFGame.KFGameInfo"
I = "Engine.GameInfo"
SETTINGS = [
    ("ServerName", "game", S, "ServerName", "text", "Killing Floor 2 Server"),
    ("GamePassword", "game", A, "GamePassword", "text", ""),
    ("AdminPassword", "game", A, "AdminPassword", "text", ""),
    ("ServerMOTD", "game", G, "ServerMOTD", "text", "Welcome to our server. \\n \\n Have fun and good luck!"),
    ("BannerLink", "game", G, "BannerLink", "text", "http://art.tripwirecdn.com/TestItemIcons/MOTDServer.png"),
    ("WebsiteLink", "game", G, "WebsiteLink", "text", "http://killingfloor2.com/"),
    ("ClanMotto", "game", G, "ClanMotto", "text", "This is the clan motto."),
    ("GameMode", "launch", None, "GameMode", "select", "survival"),
    ("Difficulty", "launch", None, "Difficulty", "select", "normal"),
    ("GameLength", "launch", None, "GameLength", "select", "short"),
    ("MaxPlayers", "launch", None, "MaxPlayers", "int", "6"),
    ("StartMap", "launch", None, "StartMap", "text", DEFAULT_MAP),
    ("FriendlyFireScale", "game", G, "FriendlyFireScale", "float", "0.000000"),
    ("bDisablePickups", "game", G, "bDisablePickups", "bool", "False"),
    ("bDisableTeamCollision", "game", G, "bDisableTeamCollision", "bool", "False"),
    ("bAdminCanPause", "game", I, "bAdminCanPause", "bool", "false"),
    ("ReadyUpDelay", "game", G, "ReadyUpDelay", "int", "90"),
    ("GameStartDelay", "game", G, "GameStartDelay", "int", "4"),
    ("EndOfGameDelay", "game", G, "EndOfGameDelay", "int", "15"),
    ("bWaitForNetPlayers", "game", G, "bWaitForNetPlayers", "bool", "true"),
    ("MinNetPlayers", "game", G, "MinNetPlayers", "int", "1"),
    ("MaxSpectators", "game", I, "MaxSpectators", "int", "2"),
    ("MaxIdleTime", "game", I, "MaxIdleTime", "float", "0.000000"),
    ("bDisableKickVote", "game", G, "bDisableKickVote", "bool", "False"),
    ("KickVotePercentage", "game", G, "KickVotePercentage", "float", "0.660000"),
    ("bDisableMapVote", "game", G, "bDisableMapVote", "bool", "False"),
    ("MapVotePercentage", "game", G, "MapVotePercentage", "float", "0.000000"),
    ("VoteTime", "game", G, "VoteTime", "float", "60.0"),
    ("MapVoteDuration", "game", G, "MapVoteDuration", "float", "60.000000"),
    ("bDisablePublicTextChat", "game", G, "bDisablePublicTextChat", "bool", "False"),
    ("bDisableVOIP", "game", G, "bDisableVOIP", "bool", "False"),
    ("bDisablePublicVOIPChannel", "game", G, "bDisablePublicVOIPChannel", "bool", "False"),
    ("bEnableDeadToVOIP", "game", G, "bEnableDeadToVOIP", "bool", "true"),
    ("NetServerMaxTickRate", "engine", "IpDrv.TcpNetDriver", "NetServerMaxTickRate", "float", "30.0"),
]
SCHEMA = {row[0]: row for row in SETTINGS}
SELECTS = {
    "GameMode": list(MODES),
    "Difficulty": list(DIFFICULTIES),
    "GameLength": list(LENGTHS),
}
# Keys the image owns: the Maps tab sets the start map.
MANAGED_KEYS = {"StartMap"}
TEXT_LIMITS = {"ServerName": 100, "ServerMOTD": 400, "BannerLink": 200, "WebsiteLink": 200, "ClanMotto": 100}


# ------------------------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data, indent=2):
    """Written beside and renamed, so a cut-off write never leaves half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def read_text(path):
    try:
        with open(path, encoding="utf-8-sig", newline="") as f:
            return f.read()
    except OSError:
        return None


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


def env_set(name):
    """A variable counts only with a value: the marketplace writes every declared parameter, the
    ones left blank as NAME=, and a blank one must not wipe what the panel set."""
    return str(os.environ.get(name, "")).strip() != ""


def truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def steam_id(value):
    """A SteamID64 from what was typed or pasted (a profile link too), or None."""
    value = str(value).strip()
    m = re.search(r"(?:^|/profiles/)(7656119\d{10})/?$", value)
    return m.group(1) if m else None


def workshop_id(value):
    """A workshop item id from what was typed or pasted (a workshop link too), or None."""
    value = str(value).strip()
    m = re.search(r"(?:[?&]id=)(\d{5,12})\b", value) or re.fullmatch(r"(\d{5,12})", value)
    return m.group(1) if m else None


# ------------------------------------------------------------------------------------------------
# The ini files: read and edited in place
# ------------------------------------------------------------------------------------------------

def ini_path(which):
    return os.path.join(CONFIG_DATA, {"game": GAME_INI, "engine": ENGINE_INI, "web": WEB_INI}[which])


def split_lines(text):
    return text.splitlines(keepends=True)


def newline_of(text):
    return "\r\n" if "\r\n" in text else "\n"


def section_bounds(lines, section):
    """(first line index after the header, index of the next header or len) of the FIRST [section], or None."""
    start = None
    for i, raw in enumerate(lines):
        s = raw.strip()
        if s.startswith("[") and s.endswith("]"):
            if start is not None:
                return start, i
            if s[1:-1] == section:
                start = i + 1
    return (start, len(lines)) if start is not None else None


def ini_get(text, section, key, default=None):
    """The value of the first `key=` in [section], or default."""
    lines = split_lines(text or "")
    b = section_bounds(lines, section)
    if b is None:
        return default
    for raw in lines[b[0]:b[1]]:
        k, sep, v = raw.strip().partition("=")
        if sep and k.strip() == key:
            return v.strip()
    return default


def ini_set(text, section, key, value):
    """The text with `key=value` set in [section] (the first such row replaced in place; added at the
    end of the section, or in a new section at the end, when there is none). Line endings kept."""
    text = text or ""
    nl = newline_of(text)
    lines = split_lines(text)
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] += nl
    b = section_bounds(lines, section)
    row = f"{key}={value}{nl}"
    if b is None:
        if lines and lines[-1].strip():
            lines.append(nl)
        lines += [f"[{section}]{nl}", row]
        return "".join(lines)
    for i in range(b[0], b[1]):
        k, sep, _v = lines[i].strip().partition("=")
        if sep and k.strip() == key:
            lines[i] = row
            return "".join(lines)
    end = b[1]
    while end > b[0] and not lines[end - 1].strip():
        end -= 1
    lines.insert(end, row)
    return "".join(lines)


def ini_set_all(text, section, key, values, first=False):
    """Every `key=` row of [section] replaced by one row per value (none removes them). `first` puts the
    rows at the top of the section instead of where the first old one was."""
    text = text or ""
    nl = newline_of(text)
    lines = split_lines(text)
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] += nl
    b = section_bounds(lines, section)
    rows = [f"{key}={v}{nl}" for v in values]
    if b is None:
        if not rows:
            return "".join(lines)
        if lines and lines[-1].strip():
            lines.append(nl)
        return "".join(lines + [f"[{section}]{nl}"] + rows)
    at = None
    keep = []
    for i in range(b[0], b[1]):
        k, sep, _v = lines[i].strip().partition("=")
        if sep and k.strip() == key:
            if at is None:
                at = len(keep)
            continue
        keep.append(lines[i])
    if first:
        at = 0
    elif at is None:
        at = _trim_end(keep)
    keep[at:at] = rows
    return "".join(lines[:b[0]] + keep + lines[b[1]:])


def _trim_end(rows):
    n = len(rows)
    while n > 0 and not rows[n - 1].strip():
        n -= 1
    return n


def ini_values(text, section, key):
    """Every `key=` value of [section], in order."""
    lines = split_lines(text or "")
    b = section_bounds(lines, section)
    found = []
    if b is None:
        return found
    for raw in lines[b[0]:b[1]]:
        k, sep, v = raw.strip().partition("=")
        if sep and k.strip() == key:
            found.append(v.strip())
    return found


def load_ini(which):
    text = read_text(ini_path(which))
    return text if text is not None else ""


def save_ini(which, text):
    os.makedirs(CONFIG_DATA, exist_ok=True)
    write_text(ini_path(which), text)


def coerce(kind, key, value):
    """(text as the file holds it, None) or (None, why)."""
    if isinstance(value, bool):
        value = "True" if value else "False"
    value = str(value).strip()
    if kind == "bool":
        v = value.lower()
        if v in ("true", "1", "yes", "on"):
            return "True", None
        if v in ("false", "0", "no", "off"):
            return "False", None
        return None, "must be true or false"
    if kind == "int":
        if not re.fullmatch(r"-?\d+", value):
            return None, "must be a whole number"
        return str(int(value)), None
    if kind == "float":
        try:
            n = float(value)
        except ValueError:
            return None, "must be a number"
        return f"{n:.6f}", None
    if re.search(r"[\x00-\x1f\x7f]", value):
        return None, "cannot contain control characters"
    if len(value) > TEXT_LIMITS.get(key, 100):
        return None, f"is longer than {TEXT_LIMITS.get(key, 100)} characters"
    return value, None


def check_key(key, kind, value):
    """Extra limits beyond the type; None when fine."""
    if key == "MaxPlayers" and not 1 <= int(value) <= MAX_PLAYERS_CAP:
        return f"must be from 1 to {MAX_PLAYERS_CAP}"
    if key == "ServerName":
        if not value.strip():
            return "needs a name"
        if re.search(r"[\"?&]", value):
            return "cannot contain a double quote, ? or &"
    if key in SECRET_KEYS and value and re.search(r"[\s\"?&=#]", value):
        return "cannot contain spaces, quotes, ?, &, = or #"
    if key == "FriendlyFireScale" and not 0 <= float(value) <= 1:
        return "must be from 0 to 1"
    if key in ("KickVotePercentage", "MapVotePercentage") and not 0 <= float(value) <= 1:
        return "must be from 0 to 1"
    if key in ("ReadyUpDelay", "GameStartDelay", "EndOfGameDelay", "MaxSpectators") and not 0 <= int(value) <= 3600:
        return "must be from 0 to 3600"
    if key == "MinNetPlayers" and not 1 <= int(value) <= MAX_PLAYERS_CAP:
        return f"must be from 1 to {MAX_PLAYERS_CAP}"
    if key in ("VoteTime", "MapVoteDuration", "MaxIdleTime") and not 0 <= float(value) <= 3600:
        return "must be from 0 to 3600 seconds"
    if key == "NetServerMaxTickRate" and not 20 <= float(value) <= 120:
        return "must be from 20 to 120"
    if key in ("BannerLink", "WebsiteLink") and value and not re.match(r"^https?://", value):
        return "must start with http:// or https://"
    if key == "StartMap" and not MAP_RE.match(value):
        return "is not a map name"
    return None


def load_launch():
    data = read_json(LAUNCH_FILE, {})
    return data if isinstance(data, dict) else {}


def launch_value(key):
    v = load_launch().get(key)
    return str(v) if v not in (None, "") else SCHEMA[key][5]


def load_pending():
    data = read_json(PENDING_FILE, {})
    return data if isinstance(data, dict) else {}


def save_pending(data):
    data = {k: v for k, v in data.items() if v not in (None, {}, [])}
    if data:
        write_json(PENDING_FILE, data)
    else:
        try:
            os.remove(PENDING_FILE)
        except OSError:
            pass


def current_value(key):
    """The value of a setting as it will be (the panel's pending edit over the files), or its default."""
    _k, which, section, name, _t, default = SCHEMA[key]
    if which == "launch":
        return launch_value(key)
    pending = load_pending().get("settings", {})
    if key in pending:
        return pending[key]
    v = ini_get(load_ini(which), section, name)
    return default if v is None else v


def flush_pending(notes):
    """Writes the panel's pending edits into the ini files. Only apply calls this, with the game not running.
    What belongs to a file the game has not written yet stays pending."""
    pending = load_pending()
    if not pending:
        return
    left = {}
    settings = pending.get("settings") or {}
    keep = {}
    texts = {}
    for key, text in settings.items():
        _k, which, section, name, _t, _d = SCHEMA[key]
        if which == "engine" and not os.path.exists(ini_path("engine")):
            keep[key] = text
            continue
        texts.setdefault(which, load_ini(which))
        texts[which] = ini_set(texts[which], section, name, text)
    cycle = pending.get("cycle")
    if cycle:
        texts.setdefault("game", load_ini("game"))
        texts["game"] = ini_set(texts["game"], G, "GameMapCycles", cycle_row(cycle))
    for which, text in texts.items():
        save_ini(which, text)
    if keep:
        left["settings"] = keep
    n = len(settings) - len(keep) + (1 if cycle else 0)
    if n:
        notes.append(f"{n} edit(s) from the panel written into the game's ini files")
    save_pending(left)


def cycle_row(cycle):
    return "(Maps=(" + ",".join(f'"{m}"' for m in cycle) + "))"


def set_values(changes, allow_managed=False, direct=False):
    """changes: {key: value as given}. Returns (applied {key: text}, errors {key: why}). Unknown keys
    are refused (a typo must not become a line the game ignores). The launch options are written at once;
    an ini setting is kept pending for the next start unless `direct` (apply, with the game not running)."""
    applied, errors = {}, {}
    for key, value in changes.items():
        if key not in SCHEMA:
            errors[key] = "is not a setting of this server"
            continue
        if key in MANAGED_KEYS and not allow_managed:
            errors[key] = "is managed by the server (use the Maps tab)"
            continue
        kind = SCHEMA[key][4]
        if kind == "select":
            v = str(value).strip().lower()
            if v not in SELECTS[key]:
                errors[key] = f"must be one of {', '.join(SELECTS[key])}"
                continue
            text, why = v, None
        else:
            text, why = coerce(kind, key, value)
            why = (check_key(key, kind, text) if text is not None else why)
        if why:
            errors[key] = why
            continue
        applied[key] = text
    if errors:
        return {}, errors
    texts = {}
    launch = load_launch()
    launch_changed = False
    pend = load_pending()
    for key, text in applied.items():
        _k, which, section, name, _t, _d = SCHEMA[key]
        if which == "launch":
            launch[key] = text
            launch_changed = True
        elif not direct:
            pend.setdefault("settings", {})[key] = text
        else:
            if which not in texts:
                texts[which] = load_ini(which)
            if which == "engine" and not texts[which]:
                errors[key] = "cannot be set before the server has started once"
                continue
            texts[which] = ini_set(texts[which], section, name, text)
    if errors:
        return {}, errors
    for which, text in texts.items():
        save_ini(which, text)
    if launch_changed:
        write_json(LAUNCH_FILE, launch)
    if not direct:
        save_pending(pend)
    return applied, errors


# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

def load_state():
    data = read_json(STATE_FILE, {})
    return data if isinstance(data, dict) else {}


def cmd_state(args):
    state = load_state()
    new = args[0] if args else "unknown"
    if new == "starting" and state.get("state") != "starting":
        state["generation"] = int(state.get("generation") or 0) + 1
    state["state"] = new
    state["message"] = args[1] if len(args) > 1 else ""
    state["since"] = int(time.time())
    if new == "running":
        state["runningSince"] = int(time.time())
    write_json(STATE_FILE, state)


def cmd_note(args):
    if not args:
        fail("usage: note <key> [value]", 64)
    state = load_state()
    if len(args) > 1 and args[1] != "":
        state[args[0]] = int(args[1]) if args[1].isdigit() else args[1]
    else:
        state.pop(args[0], None)
    write_json(STATE_FILE, state)


# ------------------------------------------------------------------------------------------------
# Maps and the map cycle
# ------------------------------------------------------------------------------------------------

def official_maps():
    """The official maps: the [KF-Name KFMapSummary] sections of the game's ini (the game lists every map it ships)."""
    names = []
    for m in re.finditer(r"^\[(KF-[A-Za-z0-9_\-]+) KFMapSummary\]", load_ini("game"), re.M):
        n = m.group(1)
        if n != "KF-Default" and n not in names:
            names.append(n)
    return names


def workshop_maps():
    """{map name: workshop id} from the downloaded items (the .kfm files in their BrewedPC folders)."""
    found = {}
    try:
        ids = sorted(os.listdir(WORKSHOP_DIR))
    except OSError:
        return found
    for wid in ids:
        base = os.path.join(WORKSHOP_DIR, wid)
        for root, _dirs, files in os.walk(base):
            for f in files:
                if f.lower().endswith(".kfm"):
                    found.setdefault(f[:-4], wid)
    return found


def map_cycle():
    """The maps of the first map cycle in the ini."""
    pending = load_pending().get("cycle")
    if pending:
        return list(pending)
    row = ini_values(load_ini("game"), G, "GameMapCycles")
    return re.findall(r'"([^"]+)"', row[0]) if row else []


def cmd_maps(_args):
    cycle = map_cycle()
    official = official_maps()
    custom = workshop_maps()
    out({"official": official, "workshop": [{"name": n, "item": w} for n, w in sorted(custom.items())],
         "cycle": cycle, "start": launch_value("StartMap"), "useMapList": ini_get(load_ini("game"), G, "bUseMapList", "True")})


def cmd_set_maps(args):
    try:
        data = json.loads(args[0])
        assert isinstance(data, dict)
    except (IndexError, ValueError, AssertionError):
        fail('Expected {"cycle": ["KF-Airship"], "start": "KF-Airship"}.')
    changed = {}
    if "cycle" in data:
        cycle = data["cycle"]
        if not isinstance(cycle, list) or not cycle or len(cycle) > 200 or not all(isinstance(m, str) and MAP_RE.match(m) for m in cycle):
            fail("The map cycle needs 1 to 200 map names (letters, digits, - and _).")
        pend = load_pending()
        pend["cycle"] = cycle
        save_pending(pend)
        changed["cycle"] = len(cycle)
    if "start" in data:
        _a, errors = set_values({"StartMap": data["start"]}, allow_managed=True)
        if errors:
            fail("; ".join(f"{k} {v}" for k, v in errors.items()))
        changed["start"] = data["start"]
    out({"ok": True, "applied": changed, "restartNeeded": True})


# ------------------------------------------------------------------------------------------------
# Workshop items
# ------------------------------------------------------------------------------------------------

def read_mod_ids():
    data = read_json(MODS_FILE, {})
    ids = data.get("ids") if isinstance(data, dict) else None
    return [str(i) for i in ids] if isinstance(ids, list) else []


def parse_mod_ids(values):
    ids, bad = [], []
    for v in values:
        wid = workshop_id(v)
        if wid:
            if wid not in ids:
                ids.append(wid)
        elif str(v).strip():
            bad.append(str(v).strip())
    return ids, bad


def write_mod_ids(ids, ini=False):
    """The list the panel chose (flux/mods.json). The ini rows the clients read are written by `apply`
    (ini=True), when the game is not running and has made its engine ini."""
    write_json(MODS_FILE, {"ids": ids})
    if not ini or not os.path.exists(ini_path("engine")):
        return
    text = load_ini("engine")
    text = ini_set_all(text, "OnlineSubsystemSteamworks.KFWorkshopSteamworks", "ServerSubscribedWorkshopItems", ids)
    # Clients download the items from the Steam Workshop when the server lists them; the download manager
    # must come first in the list the game keeps.
    managers = [m for m in ini_values(text, "IpDrv.TcpNetDriver", "DownloadManagers") if m != "OnlineSubsystemSteamworks.SteamWorkshopDownload"]
    wanted = (["OnlineSubsystemSteamworks.SteamWorkshopDownload"] if ids else []) + managers
    if not managers and ids:
        wanted += ["IpDrv.HTTPDownload", "Engine.ChannelDownload"]
    text = ini_set_all(text, "IpDrv.TcpNetDriver", "DownloadManagers", wanted, first=True)
    save_ini("engine", text)


def workshop_details(ids):
    """{id: {title, size, updated}} from Steam's public API (no key); {} when it cannot be reached. Cached
    on the install volume for a day so a status call never waits on the network."""
    cache = read_json(MODS_CACHE_FILE, {})
    cache = cache if isinstance(cache, dict) else {}
    now = time.time()
    need = [i for i in ids if i not in cache or now - float(cache[i].get("at", 0)) > 86400]
    if need and not truthy(os.environ.get("FLUX_NO_NETWORK", "")):
        body = {"itemcount": str(len(need))}
        for n, i in enumerate(need):
            body[f"publishedfileids[{n}]"] = i
        try:
            req = urllib.request.Request("https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/",
                                         data=urllib.parse.urlencode(body).encode())
            with urllib.request.urlopen(req, timeout=8) as r:
                rows = json.load(r)["response"]["publishedfiledetails"]
            for row in rows:
                if str(row.get("publishedfileid")) in need:
                    ok = int(row.get("result") or 0) == 1
                    cache[str(row["publishedfileid"])] = {"title": row.get("title") or "", "size": int(row.get("file_size") or 0),
                                                           "updated": int(row.get("time_updated") or 0), "found": ok, "at": now}
            write_json(MODS_CACHE_FILE, cache)
        except (OSError, ValueError, KeyError, urllib.error.URLError):
            pass
    return {i: cache[i] for i in ids if i in cache}


def item_maps(wid):
    base = os.path.join(WORKSHOP_DIR, wid)
    names = []
    for root, _d, files in os.walk(base):
        names += [f[:-4] for f in files if f.lower().endswith(".kfm")]
    return sorted(names)


def cmd_mods(_args):
    ids = read_mod_ids()
    details = workshop_details(ids)
    items = []
    for wid in ids:
        d = details.get(wid, {})
        items.append({"id": wid, "title": d.get("title") or "", "size": d.get("size") or 0, "found": d.get("found", None),
                      "downloaded": os.path.isdir(os.path.join(WORKSHOP_DIR, wid)) and bool(os.listdir(os.path.join(WORKSHOP_DIR, wid))),
                      "maps": item_maps(wid)})
    out({"items": items, "ids": ids, "max": MAX_MODS})


def cmd_set_mods(args):
    try:
        data = json.loads(args[0])
        values = data["ids"]
        assert isinstance(values, list)
    except (IndexError, ValueError, KeyError, AssertionError):
        fail('Expected {"ids": ["857015700"]}.')
    ids, bad = parse_mod_ids(values)
    if bad:
        fail(f"Not a workshop item id or link: {', '.join(bad[:5])}.")
    if len(ids) > MAX_MODS:
        fail(f"At most {MAX_MODS} workshop items.")
    details = workshop_details(ids)
    missing = [i for i in ids if details.get(i, {}).get("found") is False]
    if missing:
        fail(f"The workshop has no item {', '.join(missing)}.")
    write_mod_ids(ids)
    out({"ok": True, "count": len(ids), "restartNeeded": True})


def cmd_mods_ids(_args):
    for wid in read_mod_ids():
        print(wid)


def cmd_mods_install(_args):
    """Links the downloaded items into the game's BrewedPC folder (maps into Maps/), and removes the links
    of an item that is no longer listed. The files stay in the workshop folder, where SteamCMD keeps them."""
    wanted = read_mod_ids()
    linked = removed = 0
    # stale links first
    for folder in (MAPS_DIR, BREWED_DIR):
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for n in names:
            p = os.path.join(folder, n)
            if os.path.islink(p):
                target = os.readlink(p)
                m = re.search(r"/content/%s/(\d+)/" % WORKSHOP_APP, target)
                if m and (m.group(1) not in wanted or not os.path.exists(target)):
                    os.remove(p)
                    removed += 1
    for wid in wanted:
        base = os.path.join(WORKSHOP_DIR, wid)
        for root, _d, files in os.walk(base):
            for f in files:
                low = f.lower()
                src = os.path.join(root, f)
                if low.endswith(".kfm"):
                    dest = os.path.join(MAPS_DIR, f)
                elif os.path.basename(root).lower() == "brewedpc" and low.endswith((".upk", ".u", ".bin", ".int", ".kfm")):
                    dest = os.path.join(BREWED_DIR, f)
                else:
                    continue
                if os.path.islink(dest) and os.readlink(dest) == src:
                    continue
                if os.path.lexists(dest):
                    if not os.path.islink(dest):
                        print(f"# WARN workshop item {wid}: {f} is already a game file; not replaced")
                        continue
                    os.remove(dest)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                os.symlink(src, dest)
                linked += 1
    print(f"# workshop: {len(wanted)} item(s), {linked} file(s) linked, {removed} stale link(s) removed")


# ------------------------------------------------------------------------------------------------
# Environment, ports and the launch line
# ------------------------------------------------------------------------------------------------

def env_ports(notes):
    """(game, query, web) from the environment, or None (with a note). The game and query ports are UDP,
    the web admin's is TCP, and the three are independent."""
    ports = []
    for name, default in (("KF2_GAME_PORT", DEFAULT_GAME_PORT), ("KF2_QUERY_PORT", DEFAULT_QUERY_PORT), ("KF2_WEB_PORT", DEFAULT_WEB_PORT)):
        raw = os.environ.get(name, "").strip() or str(default)
        try:
            n = int(raw)
        except ValueError:
            notes.append(f"ERROR {name}={raw!r} is not a port")
            return None
        if not 1024 <= n <= 65535:
            notes.append(f"ERROR {name}={n} is not a port from 1024 to 65535")
            return None
        ports.append(n)
    if ports[0] == ports[1]:
        notes.append(f"ERROR KF2_GAME_PORT and KF2_QUERY_PORT are both {ports[0]}; they must differ")
        return None
    return tuple(ports)


def apply_env(notes, first_run):
    """Each KF2_* value that is set, written when the file is new or the value differs from the one last applied."""
    applied = read_json(ENV_APPLIED_FILE, {})
    applied = applied if isinstance(applied, dict) else {}
    changed = False
    for name, key in ENV_KEYS.items():
        if not env_set(name):
            continue
        raw = os.environ[name]
        if not first_run and applied.get(name) == raw:
            continue
        done, errors = set_values({key: raw}, allow_managed=True, direct=True)
        if errors:
            notes.append(f"WARN {name}: {errors[key]}; kept the current value")
        else:
            shown = "(set)" if key in SECRET_KEYS else done[key]
            notes.append(f"{key} = {shown} ({name}{', first start' if first_run else ', changed'})")
        applied[name] = raw
        changed = True
    if env_set(ENV_MODS) and (first_run or applied.get(ENV_MODS) != os.environ[ENV_MODS]):
        ids, bad = parse_mod_ids(re.split(r"[\s,;]+", os.environ[ENV_MODS].strip()))
        for b in bad:
            notes.append(f"WARN {ENV_MODS}: {b!r} is not a workshop item id; skipped")
        if len(ids) > MAX_MODS:
            notes.append(f"WARN {ENV_MODS}: only the first {MAX_MODS} items are used")
            ids = ids[:MAX_MODS]
        write_mod_ids(ids, ini=True)
        notes.append(f"workshop items = {','.join(ids) or 'none'} ({ENV_MODS})")
        applied[ENV_MODS] = os.environ[ENV_MODS]
        changed = True
    if changed:
        write_json(ENV_APPLIED_FILE, applied)


def link_config(notes):
    """KFGame/Config/flux -> the data volume, made at every start. A real folder the game made there
    (a first run on an older layout) is moved onto the volume first."""
    os.makedirs(CONFIG_DATA, exist_ok=True)
    os.makedirs(os.path.dirname(CONFIG_LINK), exist_ok=True)
    if os.path.islink(CONFIG_LINK):
        if os.readlink(CONFIG_LINK) == CONFIG_DATA:
            return
        os.remove(CONFIG_LINK)
    elif os.path.isdir(CONFIG_LINK):
        moved = 0
        for f in os.listdir(CONFIG_LINK):
            if not os.path.exists(os.path.join(CONFIG_DATA, f)):
                shutil.move(os.path.join(CONFIG_LINK, f), os.path.join(CONFIG_DATA, f))
                moved += 1
        shutil.rmtree(CONFIG_LINK, ignore_errors=True)
        notes.append(f"{moved} file(s) the game had made in its own config folder moved to the data volume")
    os.symlink(CONFIG_DATA, CONFIG_LINK)


def seed_web(notes, web_port):
    """KFWeb.ini: the web admin on, on its port, when there is an admin password (it cannot be used without one)."""
    on = bool(current_value("AdminPassword"))
    text = load_ini("web")
    text = ini_set(text, "IpDrv.WebServer", "bEnabled", "true" if on else "false")
    text = ini_set(text, "IpDrv.WebServer", "ListenPort", str(web_port))
    save_ini("web", text)
    if not on:
        notes.append("WARN no admin password: the web admin is off and the panel cannot list players. Set KF2_ADMIN_PASSWORD.")


def prune_game_logs(notes):
    """The game keeps KFGame/Logs/Launch.log and renames the old ones (Launch_backup_*.log); it deletes none."""
    keep = int(os.environ.get("FLUX_GAME_LOG_FILES", "5"))
    folder = os.path.join(GAME_DIR, "Logs")
    try:
        old = sorted((f for f in os.listdir(folder) if f != "Launch.log" and f.endswith(".log")),
                     key=lambda f: os.path.getmtime(os.path.join(folder, f)), reverse=True)
    except OSError:
        return
    removed = 0
    for f in old[keep:]:
        try:
            os.remove(os.path.join(folder, f))
            removed += 1
        except OSError:
            pass
    if removed:
        notes.append(f"{removed} old game log(s) removed")


def launch_url():
    """The server's first argument: map, game class and the options of the match."""
    mode = launch_value("GameMode")
    cls = MODES.get(mode, MODES["survival"])[0]
    start = launch_value("StartMap")
    url = f"{start}?Game={cls}?MaxPlayers={launch_value('MaxPlayers')}"
    if mode in ("survival", "endless", "objective"):
        url += f"?Difficulty={DIFFICULTIES.get(launch_value('Difficulty'), 0)}"
    if mode == "survival":
        url += f"?GameLength={LENGTHS.get(launch_value('GameLength'), 0)}"
    return url


def build_args(ports):
    game, query, _web = ports
    args = [launch_url(), f"-Port={game}", f"-QueryPort={query}", f"-ConfigSubDir={CONFIG_SUBDIR}", "-NoHomeDir"]
    extra = os.environ.get("KF2_EXTRA_ARGS", "").strip()
    if extra:
        args += [a for a in re.split(r"\s+", extra)
                 if a and not a.lower().startswith(("-port=", "-queryport=", "-configsubdir=", "-nohomedir", "-steamport"))]
    return args


def cmd_args(_args):
    ports = env_ports([])
    if ports is None:
        sys.exit(2)
    print("\n".join(build_args(ports)))


def cmd_needs_bootstrap(_args):
    """Exit 0 when the game has not made its engine ini yet. THE ENGINE INI IS NEVER SEEDED: a partial
    LinuxServer-KFEngine.ini in the config folder makes the game abort at start (measured, exit 134 right
    after the breakpad line), while a folder with no engine ini gets the full file. So the supervisor runs the
    server once, only to let it write its files (flux-kf2 args, then stop), before the settings that live in
    that file (the workshop list, the tick rate) are written."""
    sys.exit(0 if not os.path.exists(ini_path("engine")) else 1)


def cmd_apply(_args):
    notes = []
    os.makedirs(STATE_DIR, exist_ok=True)
    link_config(notes)
    ports = env_ports(notes)
    if ports is None:
        for line in notes:
            print(f"# {line}")
        sys.exit(2)
    prune_game_logs(notes)
    first_run = not os.path.exists(ini_path("game"))
    if first_run:
        # Seed: the game merges a partial ini with its defaults and writes the whole file.
        save_ini("game", "[Engine.GameReplicationInfo]\nServerName=Killing Floor 2 Server\n")
    flush_pending(notes)
    apply_env(notes, first_run)
    seed_web(notes, ports[2])
    # The ban list, the map cycle and the workshop list survive in the ini; the workshop section must match the list.
    mods = read_mod_ids()
    if os.path.exists(ini_path("engine")) and ini_values(load_ini("engine"), "OnlineSubsystemSteamworks.KFWorkshopSteamworks", "ServerSubscribedWorkshopItems") != mods:
        write_mod_ids(mods, ini=True)
    notes.append(f"{current_value('MaxPlayers')} slots, {launch_value('GameMode')}, {launch_value('Difficulty')}, map {launch_value('StartMap')}")
    notes.append(f"game port {ports[0]} (UDP), query port {ports[1]} (UDP), web admin {ports[2]} (TCP)")
    for line in notes:
        print(f"# {line}")
    state = load_state()
    state["gamePort"], state["queryPort"], state["webPort"] = ports
    write_json(STATE_FILE, state)


# ------------------------------------------------------------------------------------------------
# Settings (the panel's form)
# ------------------------------------------------------------------------------------------------

def cmd_settings(_args):
    items = []
    for key, which, section, name, kind, default in SETTINGS:
        if key in MANAGED_KEYS:
            continue
        value = current_value(key)
        item = {"key": key, "section": section or "launch", "type": kind, "default": default,
                "value": "" if key in SECRET_KEYS else value, "known": True}
        if kind == "select":
            item["options"] = SELECTS[key]
        items.append(item)
    out({"settings": items, "maxPlayersCap": MAX_PLAYERS_CAP, "secrets": sorted(SECRET_KEYS),
         "passworded": bool(current_value("GamePassword")), "adminSet": bool(current_value("AdminPassword")),
         "managed": sorted(MANAGED_KEYS)})


def cmd_set_settings(args):
    try:
        values = json.loads(args[0])["values"]
        assert isinstance(values, dict)
    except (IndexError, ValueError, KeyError, AssertionError):
        fail('Expected {"values": {"ServerName": "..."}}.')
    if len(values) > 60:
        fail("Too many settings at once.")
    applied, errors = set_values(values)
    if errors:
        fail("; ".join(f"{k} {v}" for k, v in list(errors.items())[:5]))
    out({"ok": True, "applied": sorted(applied), "restartNeeded": True})


def cmd_join_password(_args):
    out({"joinPassword": current_value("GamePassword")})


# ------------------------------------------------------------------------------------------------
# The web admin: players, kick, ban, change map (live)
# ------------------------------------------------------------------------------------------------

class WebAdmin:
    """The game's WebAdmin (HTML), on the loopback. Login is a form with a one-time token; the session is a cookie."""

    def __init__(self, port, password, host="127.0.0.1"):
        self.base = f"http://{host}:{port}"
        self.password = password
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.logged_in = False

    def get(self, path, data=None):
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        with self.opener.open(self.base + path, body, timeout=8) as r:
            return r.read().decode("utf-8", errors="replace")

    def login(self):
        page = self.get("/ServerAdmin/")
        m = re.search(r'name="token" value="(\w+)"', page)
        if not m:
            return True   # no login form: already in
        page = self.get("/ServerAdmin/", {"token": m.group(1), "password_hash": "", "username": "Admin",
                                         "password": self.password, "remember": "-1"})
        self.logged_in = 'id="loginform"' not in page
        return self.logged_in


def webadmin():
    """A logged-in WebAdmin client, or None (with no raise) when the server is not up or the login fails."""
    password = current_value("AdminPassword")
    port = load_state().get("webPort") or DEFAULT_WEB_PORT
    if not password:
        return None
    try:
        w = WebAdmin(port, password)
        return w if w.login() else None
    except (OSError, urllib.error.URLError, ValueError):
        return None


def strip_tags(s):
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def parse_players(page):
    """[{name, ping, ip, uniqueId, steamId, playerId, key, admin, spectator, actions: {value: text}}] from the
    WebAdmin players page. The columns are those of KFGame/Web/ServerAdmin/current_players_row.inc."""
    players = []
    body = re.search(r'<table id="players".*?<tbody>(.*?)</tbody>', page, re.S)
    if not body:
        return players
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", body.group(1), re.S):
        cells = re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)
        key = re.search(r'name="playerkey" value="([^"]*)"', row)
        if len(cells) < 9 or not key:
            continue
        pid = re.search(r'name="playerid" value="([^"]*)"', row)
        actions = {html.unescape(v): strip_tags(t) for v, t in re.findall(r'<option value="([^"]*)"[^>]*>(.*?)</option>', row, re.S) if v}
        sid = strip_tags(cells[5])
        players.append({"name": strip_tags(cells[1]), "ping": int(re.sub(r"\D", "", strip_tags(cells[2])) or 0),
                        "uniqueId": strip_tags(cells[4]), "steamId": sid if STEAM_ID_RE.match(sid) else "",
                        "playerId": pid.group(1) if pid else "", "key": html.unescape(key.group(1)),
                        "admin": strip_tags(cells[7]).lower() in ("yes", "true", "1", "admin"),
                        "spectator": strip_tags(cells[8]).lower() in ("yes", "true", "1"),
                        "actions": actions})
    return players


def pick_action(actions, want):
    """The WebAdmin action (value) for 'kick', 'ban' (a permanent ban of the account) or 'sessionban' out of
    what the player's row offers, matched on value and label; None when it does not offer it."""
    items = [(v, (v + " " + t).lower()) for v, t in actions.items()]
    if want == "kick":
        for v, s in items:
            if "kick" in s:
                return v
    elif want == "sessionban":
        for v, s in items:
            if "ban" in s and "session" in s:
                return v
    elif want == "ban":
        for v, s in items:
            if "ban" in s and "session" not in s and "ip" not in re.findall(r"[a-z]+", s):
                return v
        for v, s in items:
            if "ban" in s and "session" not in s:
                return v
    return None


def uid_parts(steam64):
    """The two 32-bit halves the ini keeps a ban as: BannedIDs=(Uid=(A=<low>,B=<high>))."""
    n = int(steam64)
    return n & 0xFFFFFFFF, n >> 32


def banned_from_ini():
    ids = []
    for v in ini_values(load_ini("game"), A, "BannedIDs"):
        m = re.search(r"A=(\d+),\s*B=(\d+)", v)
        if m:
            n = (int(m.group(2)) << 32) | int(m.group(1))
            if STEAM_ID_RE.match(str(n)) and str(n) not in ids:
                ids.append(str(n))
    return ids


def write_bans_ini(ids):
    rows = [f"(Uid=(A={uid_parts(i)[0]},B={uid_parts(i)[1]}))" for i in ids]
    save_ini("game", ini_set_all(load_ini("game"), A, "BannedIDs", rows))


def cmd_players(_args):
    state = load_state()
    players, live = [], False
    if state.get("state") == "running":
        w = webadmin()
        if w:
            try:
                players = parse_players(w.get("/ServerAdmin/current/players"))
                live = True
            except (OSError, urllib.error.URLError, ValueError):
                pass
    banned = banned_from_ini()
    for p in players:
        p["banned"] = p["steamId"] in banned
        p["canKick"] = pick_action(p.pop("actions"), "kick") is not None
    out({"players": players, "live": live, "banned": banned,
         "webAdmin": bool(current_value("AdminPassword"))})


def player_action(key, want):
    w = webadmin()
    if not w:
        fail("The server's web admin is not reachable (is the server up, with an admin password set?).")
    page = w.get("/ServerAdmin/current/players")
    for p in parse_players(page):
        if p["key"] == key:
            action = pick_action(p["actions"], want)
            if not action:
                fail(f"The web admin does not offer '{want}' for this player.")
            w.get("/ServerAdmin/current/players", {"ajax": "1", "action": action, "playerkey": key, "playerid": p["playerId"]})
            out({"ok": True, "action": action, "name": p["name"]})
            return
    fail("That player is no longer on the server.")


def cmd_kick(args):
    if not args:
        fail("usage: kick <playerkey>", 64)
    player_action(args[0], "kick")


def cmd_ban(args):
    if not args:
        fail("usage: ban <playerkey>", 64)
    player_action(args[0], "ban")


def cmd_map_now(args):
    if not args or not MAP_RE.match(args[0]):
        fail("usage: map-now <map> [mode]", 64)
    mode = args[1] if len(args) > 1 else launch_value("GameMode")
    if mode not in MODES:
        fail(f"mode must be one of {', '.join(MODES)}")
    w = webadmin()
    if not w:
        fail("The server's web admin is not reachable (is the server up, with an admin password set?).")
    extra = f"?Difficulty={DIFFICULTIES.get(launch_value('Difficulty'), 0)}?GameLength={LENGTHS.get(launch_value('GameLength'), 0)}?MaxPlayers={launch_value('MaxPlayers')}"
    w.get("/ServerAdmin/current/change", {"gametype": MODES[mode][0], "map": args[0], "mutatorGroupCount": "0",
                                          "urlextra": extra, "action": "change"})
    out({"ok": True, "map": args[0], "mode": mode})


def guard_ban_state():
    """The ini is edited only when the game is not running. While it starts or restarts its process is alive and would
    overwrite the file, and its web admin is not up yet: say so instead of losing the ban."""
    if load_state().get("state") in ("starting", "restarting"):
        fail("The server is starting. Try again when it says running: a ban written now would be overwritten.")


def cmd_bans(_args):
    out({"banned": banned_from_ini()})


def cmd_ban_id(args):
    sid = steam_id(args[0]) if args else None
    if not sid:
        fail("A SteamID64 is 17 digits starting 7656119.")
    guard_ban_state()
    w = webadmin() if load_state().get("state") == "running" else None
    if w:
        w.get("/ServerAdmin/policy/bans", {"action": "add", "steamint64": sid, "uniqueid": ""})
        out({"ok": True, "live": True, "id": sid})
        return
    ids = banned_from_ini()
    if sid not in ids:
        write_bans_ini(ids + [sid])
    out({"ok": True, "live": False, "id": sid})


def cmd_unban_id(args):
    sid = steam_id(args[0]) if args else None
    if not sid:
        fail("A SteamID64 is 17 digits starting 7656119.")
    guard_ban_state()
    w = webadmin() if load_state().get("state") == "running" else None
    if w:
        page = w.get("/ServerAdmin/policy/bans")
        rows = re.findall(r"<tr>(.*?)</tr>", page, re.S)
        for row in rows:
            if sid in row:
                m = re.search(r'name="banid" value="([^"]*)"', row)
                if m:
                    w.get("/ServerAdmin/policy/bans", {"banid": html.unescape(m.group(1)), "action": "delete"})
                    out({"ok": True, "live": True, "id": sid})
                    return
        fail("That account is not banned.")
    ids = banned_from_ini()
    if sid not in ids:
        fail("That account is not banned.")
    write_bans_ini([i for i in ids if i != sid])
    out({"ok": True, "live": False, "id": sid})


# ------------------------------------------------------------------------------------------------
# Backups: the settings and what the panel chose (there are no saves)
# ------------------------------------------------------------------------------------------------

def load_index():
    data = read_json(BACKUP_INDEX, {})
    return data if isinstance(data, dict) else {}


def list_backups():
    index = load_index()
    rows = []
    if os.path.isdir(BACKUP_DIR):
        for name in sorted(os.listdir(BACKUP_DIR), reverse=True):
            if not BACKUP_NAME_RE.match(name):
                continue
            path = os.path.join(BACKUP_DIR, name)
            st = os.stat(path)
            meta = index.get(name, {})
            rows.append({"name": name, "size": st.st_size, "time": int(meta.get("time") or st.st_mtime),
                         "why": meta.get("why") or "", "keep": bool(meta.get("keep"))})
    return rows


def prune_backups(keep):
    """The newest `keep` are kept, plus every one marked keep (made before a restore)."""
    rows = list_backups()
    index = load_index()
    kept = 0
    for row in rows:
        if index.get(row["name"], {}).get("keep"):
            continue
        kept += 1
        if kept > keep:
            try:
                os.remove(os.path.join(BACKUP_DIR, row["name"]))
            except OSError:
                pass
            index.pop(row["name"], None)
    write_json(BACKUP_INDEX, index)


def backup_sources():
    """[(path, arcname)]: the config folder's own ini files and what the panel chose."""
    rows = []
    for name in (GAME_INI, ENGINE_INI, WEB_INI):
        p = os.path.join(CONFIG_DATA, name)
        if os.path.isfile(p):
            rows.append((p, f"Config/{CONFIG_SUBDIR}/{name}"))
    for p, arc in ((LAUNCH_FILE, "flux/launch.json"), (MODS_FILE, "flux/mods.json")):
        if os.path.isfile(p):
            rows.append((p, arc))
    return rows


def newest_change_time():
    return max([os.path.getmtime(p) for p, _a in backup_sources()] or [0])


def make_backup(why, force=False):
    """Returns the notes. Skipped when there is nothing to back up, when nothing changed since the newest
    backup, or the newest is younger than FLUX_BACKUP_MIN_AGE_MINUTES (unless forced)."""
    sources = backup_sources()
    if not sources:
        return ["# backup skipped: no settings yet"]
    min_age = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60")) * 60
    rows = list_backups()
    if not force and rows:
        if time.time() - rows[0]["time"] < min_age:
            return [f"# backup skipped: the newest is {int((time.time() - rows[0]['time']) / 60)} min old"]
        if newest_change_time() <= rows[0]["time"]:
            return ["# backup skipped: nothing changed since the newest one"]
    os.makedirs(BACKUP_DIR, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-kf2.tar.gz"
    while os.path.exists(os.path.join(BACKUP_DIR, name)):
        time.sleep(1)
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-kf2.tar.gz"
    path = os.path.join(BACKUP_DIR, name)
    try:
        with tarfile.open(path + ".part", "w:gz", compresslevel=6) as t:
            for src, arc in sources:
                t.add(src, arcname=arc)
    except OSError as e:
        try:
            os.remove(path + ".part")
        except OSError:
            pass
        return [f"# WARN backup failed: {e}"]
    os.replace(path + ".part", path)
    index = load_index()
    index[name] = {"time": int(time.time()), "why": why, "keep": why.startswith("before")}
    write_json(BACKUP_INDEX, index)
    prune_backups(int(os.environ.get("FLUX_BACKUP_KEEP", "10")))
    return [f"# backup {name} ({why}, {os.path.getsize(path) // 1024} KB)"]


def cmd_backup(args):
    why = args[0] if args else "by hand"
    for line in make_backup(why, force=len(args) > 1 and args[1] == "force"):
        print(line)


def cmd_backups(_args):
    out({"backups": list_backups()})


def safe_members(t):
    for member in t.getmembers():
        parts = member.name.split("/")
        if member.name.startswith("/") or ".." in parts:
            raise ValueError(f"unsafe path {member.name}")
        if not any(member.name == p or member.name.startswith(p + "/") for p in ("Config", "flux")):
            raise ValueError(f"unexpected entry {member.name}")
        if not (member.isfile() or member.isdir()):
            raise ValueError(f"not a file: {member.name}")


def restore_backup(row):
    """The whole backup over the live settings."""
    path = os.path.join(BACKUP_DIR, row["name"])
    tmp = tempfile.mkdtemp(dir=DATA_DIR, prefix=".flux-restore-")
    try:
        with tarfile.open(path) as t:
            safe_members(t)
            files = [m.name for m in t.getmembers() if m.isfile()]
            if not files:
                return False
            for m in files:
                t.extract(m, tmp)  # noqa: S202 - every member checked above
        for m in files:
            src = os.path.join(tmp, m)
            dest = os.path.join(DATA_DIR, m)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(src, dest + ".part")
            os.replace(dest + ".part", dest)
        return True
    except (OSError, ValueError, KeyError, tarfile.TarError):
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def request_restart(why):
    state = load_state()
    if state.get("state") not in ("running", "starting", "updating", "restarting"):
        return False
    if not os.path.exists(RESTART_MARKER):
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: {why}\nnotbefore=0\n")
    return True


def cmd_restore(args):
    name = os.path.basename(args[0]) if args else ""
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("No such backup.")
    write_json(RESTORE_FILE, {"name": name, "asked": int(time.time())})
    running = request_restart(f"restore {name}")
    out({"ok": True, "restarting": running, "name": name})


def cmd_do_restore(_args):
    pending = read_json(RESTORE_FILE)
    if not isinstance(pending, dict):
        return
    try:
        os.remove(RESTORE_FILE)
    except OSError:
        pass
    name = os.path.basename(str(pending.get("name", "")))
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        print(f"# WARN the backup to restore is gone: {name}")
        write_json(LAST_RESTORE_FILE, {"name": name, "ok": False, "error": "that backup is gone", "time": int(time.time())})
        return
    for line in make_backup(f"before restoring {name}", force=True):
        print(line)
    if restore_backup({"name": name}):
        # What the panel had saved and not yet applied is older than the backup being put back.
        save_pending({})
        print(f"# restored {name}")
        write_json(LAST_RESTORE_FILE, {"name": name, "ok": True, "error": None, "time": int(time.time())})
    else:
        print(f"# WARN the restore of {name} failed")
        write_json(LAST_RESTORE_FILE, {"name": name, "ok": False, "error": "the backup could not be read", "time": int(time.time())})


# ------------------------------------------------------------------------------------------------
# The Steam query
# ------------------------------------------------------------------------------------------------

def a2s_info(port, host="127.0.0.1", timeout=2.0):
    """The Steam query's A2S_INFO answer: {name, map, players, maxPlayers, keywords} or None (measured: the
    server answers with a challenge first)."""
    request = b"\xff\xff\xff\xffTSource Engine Query\x00"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(request, (host, port))
        data, _ = s.recvfrom(4096)
        if len(data) > 5 and data[4] == 0x41:   # a challenge
            s.sendto(request + data[5:9], (host, port))
            data, _ = s.recvfrom(4096)
    except OSError:
        return None
    finally:
        s.close()
    try:
        if data[:5] != b"\xff\xff\xff\xffI":
            return None
        pos = 6   # header byte + protocol
        fields = []
        for _ in range(4):   # name, map, folder, game
            end = data.index(b"\x00", pos)
            fields.append(data[pos:end].decode("utf-8", errors="replace"))
            pos = end + 1
        pos += 2   # app id
        players, maxp = data[pos], data[pos + 1]
        return {"name": fields[0], "map": fields[1], "players": players, "maxPlayers": maxp}
    except (ValueError, IndexError, struct.error):
        return None


def query_port():
    return int(load_state().get("queryPort") or DEFAULT_QUERY_PORT)


def cmd_a2s(_args):
    info = a2s_info(query_port())
    if info is None:
        sys.exit(1)
    out(info)


def cmd_serving(_args):
    """For the supervisor: 0 once the server answers its query port."""
    if a2s_info(query_port()) is None:
        sys.exit(1)


def cmd_players_online(_args):
    state = load_state()
    if state.get("state") != "running":
        return
    info = a2s_info(query_port())
    if info is not None:
        print(info["players"])


# ------------------------------------------------------------------------------------------------
# Status and restart
# ------------------------------------------------------------------------------------------------

def installed_build():
    path = os.path.join(SERVER_DIR, "steamapps", f"appmanifest_{STEAM_APP}.acf")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
            return m.group(1) if m else None
    except OSError:
        return None


def cmd_status(_args):
    state = load_state()
    running = state.get("state") == "running"
    query = a2s_info(query_port(), timeout=1.0) if running else None
    result = {
        "state": state.get("state") or "unknown",
        "message": state.get("message") or "",
        "since": state.get("since"),
        "runningSince": state.get("runningSince"),
        "generation": int(state.get("generation") or 0),
        "serverName": current_value("ServerName"),
        "maxPlayers": int(current_value("MaxPlayers") or 0),
        "passworded": bool(current_value("GamePassword")),
        "ports": {"game": state.get("gamePort"), "query": state.get("queryPort"), "web": state.get("webPort")},
        "build": installed_build(),
        "image": os.environ.get("FLUX_IMAGE_VERSION", "dev"),
        "playerCount": (query or {}).get("players", 0) if running else None,
        "map": (query or {}).get("map") if query else None,
        "mode": launch_value("GameMode"),
        "difficulty": launch_value("Difficulty"),
        "gameLength": launch_value("GameLength"),
        "startMap": launch_value("StartMap"),
        "mods": len(read_mod_ids()),
        "nextRestart": state.get("nextRestart"),
        "updateWaiting": state.get("updateWaiting"),
        "restartPending": os.path.exists(RESTART_MARKER),
        "restorePending": os.path.exists(RESTORE_FILE),
        "lastRestore": read_json(LAST_RESTORE_FILE),
        "lastBackup": (list_backups() or [{}])[0].get("time"),
        "webAdmin": bool(current_value("AdminPassword")),
        "pending": bool(load_pending()),
    }
    out(result)


def cmd_restart(_args):
    state = load_state()
    if state.get("state") not in ("running", "starting", "updating", "restarting"):
        fail("The server is not running.")
    if not os.path.exists(RESTART_MARKER):
        not_before = 0
        if state.get("state") == "running" and state.get("runningSince"):
            not_before = int(state["runningSince"]) + SETTLE_SECONDS
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: from the panel\nnotbefore={not_before}\n")
    out({"ok": True, "restarting": True})


def cmd_ready(_args):
    """For a HEALTHCHECK: the supervisor says the server is up and the query port answers."""
    if load_state().get("state") != "running" or a2s_info(query_port()) is None:
        sys.exit(1)


# ------------------------------------------------------------------------------------------------
# Game updates that did not install
# ------------------------------------------------------------------------------------------------

def cmd_update_target(args):
    if args:
        write_json(UPDATE_TARGET_FILE, {"build": args[0], "time": int(time.time())})


def cmd_update_check(_args):
    target = read_json(UPDATE_TARGET_FILE)
    if not isinstance(target, dict):
        return
    try:
        os.remove(UPDATE_TARGET_FILE)
    except OSError:
        pass
    build = installed_build()
    if build != str(target.get("build")):
        write_json(UPDATE_FAILED_FILE, {"build": str(target.get("build")), "time": int(time.time())})
        print(f"# WARN the update to build {target.get('build')} did not install (still {build}); not retried for 6 hours")


def cmd_update_skip(args):
    failed = read_json(UPDATE_FAILED_FILE)
    if isinstance(failed, dict) and args and str(failed.get("build")) == args[0] \
            and time.time() - float(failed.get("time") or 0) < UPDATE_FAILED_SKIP:
        sys.exit(0)
    sys.exit(1)


COMMANDS = {
    "apply": cmd_apply, "args": cmd_args, "needs-bootstrap": cmd_needs_bootstrap, "state": cmd_state, "note": cmd_note, "status": cmd_status,
    "settings": cmd_settings, "set-settings": cmd_set_settings, "join-password": cmd_join_password,
    "maps": cmd_maps, "set-maps": cmd_set_maps, "map-now": cmd_map_now,
    "mods": cmd_mods, "set-mods": cmd_set_mods, "mods-ids": cmd_mods_ids, "mods-install": cmd_mods_install,
    "players": cmd_players, "players-online": cmd_players_online, "kick": cmd_kick, "ban": cmd_ban,
    "bans": cmd_bans, "ban-id": cmd_ban_id, "unban-id": cmd_unban_id, "restart": cmd_restart,
    "backups": cmd_backups, "backup": cmd_backup, "restore": cmd_restore, "do-restore": cmd_do_restore,
    "a2s": cmd_a2s, "serving": cmd_serving, "update-target": cmd_update_target, "update-check": cmd_update_check,
    "update-skip": cmd_update_skip, "ready": cmd_ready,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 64
    COMMANDS[argv[1]](argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
