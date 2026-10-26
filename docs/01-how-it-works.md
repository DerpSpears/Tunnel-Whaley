# How the instancer works

## The problem it solves

CTFd on its own serves every player the same static challenge. For challenges
where players need a live server (web, pwn, and similar), you usually want each
player to get their own isolated copy, with a flag that only works for them, that
stays up for a limited time and then cleans itself up. You also do not want to
open a new port for every running container, especially when the whole event is
served through a single Cloudflare tunnel.

This project does that with four small pieces:

1. A CTFd plugin that adds an "instancer" challenge type and the Start, Stop, and
   Status controls players use.
2. A tiny control plane (the instancer) that creates and destroys containers on
   demand.
3. A restricted Docker socket proxy so the control plane can manage containers
   without holding full root on the host.
4. Traefik as the single front door that routes both the scoreboard and every
   live instance over one HTTP port.

## The moving parts

- CTFd: the scoreboard and the plugin. It never talks to Docker directly.
- instancer: a Flask service. It is the only thing that creates containers. It
  listens on an internal network and requires a bearer token on every call.
- dockerproxy-rw: a Tecnativa docker-socket-proxy. It exposes only the small
  slice of the Docker API the instancer needs (containers, networks, images,
  start, stop) and blocks the dangerous parts such as exec and volumes.
- Traefik: the only public service. It serves CTFd at `/` and every instance at
  `/i/<token>/`.

## What happens when a player starts a challenge

1. The player clicks Start on a challenge page. The plugin calls its own API at
   `POST /plugins/instancer/instance` with the challenge id. This route requires
   the player to be logged in.
2. The plugin derives that player's unique flag from the server secret and the
   pair (challenge id, account id). See `04-dynamic-flags.md`.
3. The plugin asks the instancer whether this player already has an instance for
   this challenge. If so, it returns the existing one instead of creating a
   duplicate, so starting is idempotent.
4. Otherwise the plugin sends the instancer a create request with the image,
   the port, the player's flag, the challenge kind (web or tcp), the time to
   live, and the resource limits.
5. The instancer checks two caps: a global cap on the total number of live
   instances (`MAX_GLOBAL_INSTANCES`) and a per-user cap that counts the
   player's live instances across all challenges. If either is exceeded it returns a clear error
   (429 for the per-user cap, 503 for the global cap) and creates nothing.
6. The instancer creates a fresh private network for that instance, then creates
   the container from the challenge image with the flag injected as the FLAG
   environment variable. The container gets a random id and a random routing
   token.
7. The instancer connects the Traefik container to the new instance network,
   then writes one Traefik route file that maps `/i/<token>/` to the container.
   The file is written atomically so Traefik never reads a half-written config.
8. Traefik is watching that directory, so the new route goes live within a
   moment. The player opens `/i/<token>/` and reaches their own container.
   Everything else still falls through to CTFd.

## How an instance ends

An instance is always removed completely: its container is force-killed, and
its private network and its route file are deleted with it. That happens in
any of these cases:

- **The player solves it.** When the player submits the correct flag, the plugin
  accepts it and immediately asks the instancer to remove that player's
  instance for the challenge, so it does not sit idle until its time runs out.
- **The player presses Stop.** Same removal, on demand. If the instancer cannot
  be reached, the player is told it failed instead of being told it stopped.
- **Its time runs out.** A background reaper inside the instancer runs every 10
  seconds (`REAP_INTERVAL`) and removes any instance past its time to live, so an
  instance ends at most 10 seconds after its time is up.
- **Its container crashes or exits.** The reaper also removes instances whose
  container is no longer running, on the next pass. Starting the challenge again
  also clears out a dead leftover first.

On each pass the reaper also deletes instance networks and route files that no
longer belong to any container, for example after a container was removed by
hand. Stop and solve remove the player's instance whatever state its container
is in, not only when it is running.

## Why routing works over a single port

Traefik has one entry point. The CTFd route is a catch-all with the lowest
priority, so it handles anything that is not an instance path. Each instance
gets a more specific `/i/<token>` route with a higher priority, so instance
traffic wins over the catch-all. Because everything is plain HTTP under one
hostname, a single Cloudflare tunnel to Traefik is enough. There are no
per-instance ports and no raw TCP to expose. See `03-cloudflare-tunnel.md`.

## The security model in one paragraph

The only component with any Docker access is the socket proxy, and it only
allows the calls the instancer actually needs. The instancer itself runs as an
unprivileged user and reaches Docker over TCP through that proxy, never through
the host socket directly. Every challenge container is locked down: it runs on
its own internal network with no outbound internet access, drops all Linux
capabilities, cannot gain new privileges, runs on a read-only root filesystem
with small writable temp mounts, has memory, CPU, process count, and file
descriptor limits, and publishes no host ports. Its only reachable surface is
the single port Traefik forwards to it.
