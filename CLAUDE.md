# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

A **Docker image repo**, not an application: the Killing Floor 2 dedicated server for Flux,
`runonflux/killingfloor2-server-flux` (repo name `kf2-server-flux`). The server is Steam app 232130 (anonymous) and
**ships a native Linux binary** (`Binaries/Win64/KFGameSteamServer.bin.x86_64`, next to the Windows exe), so there is
**no Wine and no display**. Written from scratch in the shape of `~/work/icarus-server-flux` and `~/work/scum-server-flux`;
third-party KF2 images (melle2, EvilOlaf, rouhim) are reference only and are never shipped.

**PID 1 is `flux-entrypoint.sh`, never the game.** The game is a child, so a stop reaches us first.

## Commands

```bash
./tests/test-flux.sh                                   # unit tests (flux-lib.sh, fluxkf2.py)
docker build --build-arg FLUX_IMAGE_VERSION=1.0.0 -t kf2-server-flux:local .
./tests/test-image.sh kf2-server-flux:local            # the scripts INSIDE the image, stand-in steamcmd + server
docker run --rm -v "$PWD:/m" -w /m koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh .github/ci/*.sh
```

A change to what the image does bumps `VERSION` and adds a line under "Versions" in the README.
A real-game test needs the install volume (32 GB): see README "Measured".

## The files

- `scripts/flux-entrypoint.sh`: per generation SteamCMD (Windows platform), restore, backup, `flux-kf2 apply`, the
  first-start bootstrap, workshop download and link, the server; watcher (query port, Steam build follow, daily
  restart), backupper, log capper.
- `scripts/fluxkf2.py`: every rule about the server's files and the hub's commands.
- `scripts/flux-lib.sh`: helpers; sourcing it must stay side-effect free.
- `tests/image/in-container.sh`: stand-in steamcmd and server (a Python script named like the binary).

## Things that will bite you (all measured on build 14007421, game 1150)

- **Anonymous SteamCMD needs `+@sSteamCmdForcePlatformType windows`**; the Linux request answers "Missing configuration".
  That depot still carries the Linux binary. Needs `libcurl4t64` in the image (the base lacks it; the server exits at once).
- **Never hand the game a partial `LinuxServer-KFEngine.ini`.** A seed with a few sections makes it abort (exit 134, right
  after the breakpad line); a partial `LinuxServer-KFGame.ini` and `KFWeb.ini` are merged with the defaults fine. So the
  engine ini is written by the game: the supervisor runs it once on a new data volume (`needs-bootstrap`).
- **`-ConfigSubDir=flux`** puts every ini in `KFGame/Config/flux`, which is a symlink to the data volume.
- **`?MaxPlayers=` is clamped to the game's `MaxPlayersAllowed`**: 6 in Survival, Weekly, Endless and Objective, 12 in Versus
  (an ini value does not change it). More than 6 needs a mutator.
- **The game's own workshop downloader does nothing on a dedicated server** (no Steam client). SteamCMD
  `workshop_download_item 232090 <id>` works anonymously; the image links the files into `KFGame/BrewedPC` (maps into
  `Maps/`) and still lists the ids in the engine ini so clients download them from the Workshop.
- **WebAdmin** (HTML, TCP 8080 by default, `KFWeb.ini`) is the live channel: players, kick, ban, change map, bans. It needs
  an admin password; login user is `Admin`. The player-row actions and the kick/ban POST are parsed from the game's own
  template (`KFGame/Web/ServerAdmin/current_players_row.inc`) but NOT verified with a real player.
- **Bans** are `BannedIDs=(Uid=(A=<low32>,B=<high32>))` in the game ini; while the server runs, change them through WebAdmin.
- **A RUNNING GAME REWRITES ITS INI FILES FROM MEMORY** (at a ban, a map change, a WebAdmin save). An edit made while it ran is
  undone: measured, a ServerName and a FriendlyFireScale were back to the old values after the next restart. So `set-settings`,
  `set-maps` and `set-mods` only write `flux/pending.json` (and `flux/mods.json`); `apply`, which runs before every start with the
  game stopped, writes them into the ini files. `settings`, `maps` and `status` show the pending value. Never edit an ini from a
  command that can run while the server is up (bans go through WebAdmin then; the ini only when the state is not `running`).
- **Nothing is saved** (a match is not kept): a stop just ends the server. SIGTERM ends it in under a second.
- **A2S on the query port** answers a challenge first; the readiness signal. Map and player count come from it.
- **Empty env = unset.** Flux stops a container with Docker's default 10 seconds.
- **`flux.log` is local** (`$FLUX_SERVER_DIR/flux-logs/flux.log`, 5 MB then one `.1`), never on the synced data volume.
- **The scheduled CI run publishes only with something to apply** (`.github/ci/needs-rebuild.sh`).
