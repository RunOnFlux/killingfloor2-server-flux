# Killing Floor 2 dedicated server image for Flux.
#
# Written from scratch. Tripwire ships the dedicated server (Steam app 232130, anonymous) with a NATIVE
# LINUX binary (Binaries/Win64/KFGameSteamServer.bin.x86_64, 51 MB, measured) next to the Windows one, so
# there is no Wine and no display here. The game is installed and updated with SteamCMD on every start (it
# is 32 GB: it lives on the install volume, never in the image), under a supervisor that edits the ini
# files from the environment and the hub's panel, downloads the workshop items, follows game updates,
# restarts daily if asked, and gives the hub a JSON status. See README.md.
#
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# libcurl4t64 is the one library the server needs that the base lacks (measured: it exits at once without
# it). SDL2, the Steam API and the EOS SDK ship with the game in Binaries/Win64/lib64.
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 libcurl4t64 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/fluxkf2.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/fluxkf2.py && \
    ln -s /opt/flux/fluxkf2.py /usr/local/bin/flux-kf2

# SteamCMD's self-update, done once here instead of on every container start; the weekly
# rebuild keeps it current.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/kf2/server", "/mnt/kf2/data"]
# The game port and the Steam query port (UDP), and the game's web admin (TCP).
EXPOSE 7777/udp 27015/udp 8080/tcp

# The first start downloads about 32 GB. FluxOS does not act on health; this is for anyone running the
# image by hand: the supervisor says the server is up and the query port answers.
HEALTHCHECK --interval=60s --timeout=10s --start-period=60m --retries=3 \
    CMD python3 /opt/flux/fluxkf2.py ready || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
