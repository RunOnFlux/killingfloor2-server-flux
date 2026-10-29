# kf2-server-flux

Killing Floor 2 dedicated server for Flux: `runonflux/killingfloor2-server-flux`.

Tripwire ships the dedicated server (Steam app 232130, anonymous download) with a **native Linux binary**
(`Binaries/Win64/KFGameSteamServer.bin.x86_64`) next to the Windows one, so the image runs it directly: **no Wine, no
virtual display**. Base `steamcmd/steamcmd:ubuntu-24` plus `libcurl4t64`. PID 1 is a bash supervisor
(`flux-entrypoint.sh`); `flux-kf2` (`fluxkf2.py`) holds every decision about the game's files and is the hub's CLI.
Written from scratch; third-party Killing Floor 2 images were only read for reference.

- SteamCMD update on every start (anonymous; the Windows platform has to be requested, the Linux one answers "Missing
  configuration", and that depot carries the Linux binary), retried when a fresh SteamCMD says so.
- The game's ini files (`LinuxServer-KFGame.ini`, `LinuxServer-KFEngine.ini`, `KFWeb.ini`, in `KFGame/Config/flux` via
  `-ConfigSubDir=flux`, a symlink to the synced volume) edited from the environment and the hub's panel: name, passwords,
  mode, difficulty, length, rules, voting, chat, tick rate, 33 settings in all.
- **Map cycle and start map**, official and workshop maps.
- **Steam Workshop** maps and mutators: SteamCMD downloads them (the game's own downloader does nothing on a dedicated
  server), the image links them where the game loads them and lists them in the engine ini so players' clients download them.
- **WebAdmin** (TCP 8080 by default) switched on when there is an admin password; the image uses it for live players,
  kick, ban, unban, and "change map now". Owners can use it in a browser too (user `Admin`).
- Ban list in the game ini (read when the server is down, changed through WebAdmin when it is up).
- Crash restart in place (5 in an hour, then exit 42), game-update following, optional daily restart.
- Backups of the settings (start when something changed, every 6 h, before a restore), restore, a JSON status for the hub.
- **Settings the environment cannot fix are not a crash**: state `needs-fix`, nothing restarts.

## Volumes

| Path | What | Flux mount |
|---|---|---|
| `/mnt/kf2/server` | game install (32 GB), workshop downloads, the game's logs, `flux-logs/` (our supervisor log, 5 MB then one `.1`, and the console copy) | `ml:` (local, never synced) |
| `/mnt/kf2/data` | `Config/flux/` (the ini files: settings, bans, map cycle, workshop list), `flux/` (state, backups) | `g:` primary |

A match is not saved: Killing Floor 2 keeps nothing but settings, so there is no world to protect and a stop just ends the server.

## Ports

| Variable | Default | What |
|---|---|---|
| `KF2_GAME_PORT` | 7777 | game, UDP |
| `KF2_QUERY_PORT` | 27015 | Steam query (A2S), UDP |
| `KF2_WEB_PORT` | 8080 | WebAdmin, TCP |

In the Flux marketplace spec only the first two are published; the web admin stays inside the container, where the panel reaches it (publishing 8080 would add about $1 a month to every plan and expose an admin login on plain HTTP). Run by hand, publish it if you want the browser admin.

The server binds exactly the ports it is given, so the published and the bound numbers must be the same. (Measured: no other
port is bound; the "Steam port 20560" in the log is not a listener.)

## Environment

An empty value counts as unset. A value is applied on the first start and again whenever it **differs from the one applied
last** (`flux/env-applied.json`), so a name changed in the panel is not undone by the same old variable on every start.

| Variable | What |
|---|---|
| `KF2_SERVER_NAME` | server name (any characters except `"`, `?`, `&`) |
| `KF2_ADMIN_PASSWORD` | admin password: in-game admin login and the web admin; none = web admin off |
| `KF2_JOIN_PASSWORD` | join password |
| `KF2_MAX_PLAYERS` | 1-12; the game clamps it to 6 outside Versus |
| `KF2_GAME_MODE` | `survival` `weekly` `endless` `versus` `objective` |
| `KF2_DIFFICULTY` | `normal` `hard` `suicidal` `hell` (Survival, Endless, Objective) |
| `KF2_GAME_LENGTH` | `short` (4 waves) `medium` (7) `long` (10), Survival only |
| `KF2_START_MAP` | the map the server starts on (the panel's Maps tab sets it) |
| `KF2_WORKSHOP_IDS` | workshop item ids or links, comma separated |
| `KF2_RESTART_TIME` | daily restart `HH:MM` (TZ, UTC when unset), on an empty server if one comes in time |
| `KF2_EXTRA_ARGS` | extra server arguments (never `-Port`, `-QueryPort`, `-ConfigSubDir`) |
| `FLUX_RESTART_MAX_ATTEMPTS` `FLUX_RESTART_WINDOW` `FLUX_BACKUP_HOURS` `FLUX_UPDATE_CHECK_MINUTES` ... | supervisor knobs, see the top of `flux-entrypoint.sh` |

## `flux-kf2` (the hub's CLI)

Every command answers one JSON document: `status`, `settings`, `set-settings`, `maps`, `set-maps`, `mods`, `set-mods`,
`players`, `kick`, `ban`, `map-now`, `bans`, `ban-id`, `unban-id`, `backups`, `backup`, `restore`, `restart`, `a2s`. The
settings are validated again here, with the field named. `fluxkf2.py` docstring has the arguments.

## The first start

On a new data volume the supervisor runs the game once, only so that it writes its default files, and stops it. **The game
aborts (exit 134) when handed a partial `LinuxServer-KFEngine.ini`**; a partial `LinuxServer-KFGame.ini` and `KFWeb.ini`
are merged with the defaults and are seeded. The settings that live in the engine ini (the workshop list, the tick rate)
are written after that.

## Edits wait for a restart

A running Killing Floor 2 server rewrites its ini files from memory (at a ban, a map change or a WebAdmin save) and so undoes any
edit made to them while it runs (measured). `flux-kf2 set-settings`, `set-maps` and `set-mods` therefore keep the change in
`flux/pending.json` (the workshop list in `flux/mods.json`) and `apply`, which runs before every start while the game is stopped,
writes it into the ini files; `settings`, `maps` and `status` (`pending: true`) already show it. Launch options (mode, difficulty,
length, max players, start map) are not in an ini and apply at once to the next start. Bans are the exception: through WebAdmin
while the server is up (they take effect at once), in the ini when it is down.

## The stop

SIGTERM to the game ends it at once; nothing is saved (no world). The supervisor gives it 6 seconds, then SIGKILL, well
inside the 10 seconds Flux gives a container.

## Versions

- 1.0.0: first version.

## Measured

Game build 14007421 (version 1150), 2026-10-29, native Linux binary in `steamcmd/steamcmd:ubuntu-24` + `libcurl4t64`:

- Install 32 GB (30 GB of it `BrewedPC`). First download ~35 minutes on a 40 MB/s line.
- Cold start (container up, install present): query port answers about 4 s after the process starts (about 10 s with a
  clean data volume: the bootstrap start comes first). Idle on Bioticslab: **465 MB RSS**, 1-2 % of a core. After loading
  Outpost, Burning Paris, Farmhouse, Airship and a workshop map in turn: 548 MB.
- `docker stop` 1.0 s; `kill -9` of the game restarts in place.
- Ports bound: UDP 7777 and 27015, TCP 8080. Nothing else.
- `?MaxPlayers=12` gives 0/6 in Survival, Weekly, Endless and Objective and 0/12 in Versus (info page and A2S).
- A2S answers a challenge first; the reply has the server name, the map and the player count (the keywords are the game's tags).
- WebAdmin: login form with a one-time token (user `Admin`), `current/info`, `current/players`, `current/change`, `policy/bans`
  all work headless; a ban written through it lands in the game ini at once.
- Anonymous `workshop_download_item 232090 <id>` works (KF-MountainPass, 158 MB); the game does not download by itself.

**Not measured** (no game client here): memory and CPU with players on, the kick/ban action values of the players page (parsed
from the game's own template and matched on their labels), mutators from the Workshop, and more than 6 players with a mutator.
The plan sizes are estimates from community guides.

## Publisher terms

Tripwire publishes no dedicated-server licence in the install (the EULA files are the game's, embedded Word documents),
the store page and the wiki document the free anonymous server, and many hosts rent Killing Floor 2 servers. Nothing
forbidding rental was found; no explicit permission either. The owner may want to ask Tripwire before selling.
