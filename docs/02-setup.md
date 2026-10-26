# Setup

`setup.sh` in the repository root does every step below for you, interactively.
See "Setup with setup.sh" in the README. This page is the manual version, for
when you want to add the instancer to an existing CTFd yourself.

This guide sets up CTFd with the instancer on a fresh host. The commands assume
a Linux host with Docker Engine and the `docker compose` plugin installed.

## Prerequisites

- A Linux host with Docker Engine and the `docker compose` plugin.
- A CTFd checkout (the standard CTFd repository). This project is a plugin plus
  a few extra services that layer on top of a normal CTFd Compose setup.
- Optional but recommended: a Cloudflare account and the `cloudflared` daemon if
  you want to expose the event through a tunnel. See `03-cloudflare-tunnel.md`.

## 0. Raise Docker's network limit

Every instance gets its own private Docker network. With Docker's default
address pools the daemon can only create about 30 bridge networks, so once
roughly 30 instances are live, new ones fail with:

```
could not find an available, non-overlapping IPv4 address pool among the defaults to assign to the network
```

Fix this once per host by giving Docker smaller (/24) subnets. Copy
`docker/daemon.json.example` to `/etc/docker/daemon.json` (merge it by hand if
you already have that file), then restart Docker:

```
sudo cp docker/daemon.json.example /etc/docker/daemon.json
sudo systemctl restart docker
docker info | grep -A3 "Default Address Pools"
```

That gives room for about 4,350 networks. Restarting Docker briefly stops every
container on the host, so do this before the event. Networks that already exist
keep their old subnets; only new ones use the pools.

## 1. Drop the plugin into CTFd

Copy the plugin folder into your CTFd tree so it lands at
`CTFd/plugins/instancer/`:

```
cp -r ctfd-plugin/instancer /path/to/CTFd/CTFd/plugins/instancer
```

CTFd loads plugins from that directory on startup. The plugin registers the new
challenge type, the player instance API, and the admin flag-report page.

## 2. Add the extra services

Copy the instancer service folder and the Traefik config into your CTFd checkout
so the relative paths in the Compose file line up:

```
cp -r instancer /path/to/CTFd/instancer
cp compose/docker-compose.instancer.yml /path/to/CTFd/docker-compose.instancer.yml
```

The file `compose/docker-compose.override.example.yml` is an example of how to
expose CTFd on a fixed host port and turn off the bundled nginx when you sit
behind a tunnel. Copy it to `docker-compose.override.yml` in your checkout and
edit `SERVER_NAME` and the database settings to match your host.

## 3. Create your .env

Copy `.env.example` to `.env` in the CTFd checkout and set real values:

```
SECRET_KEY=... a long random string ...
INSTANCER_TOKEN=... another long random string ...
```

`SECRET_KEY` is the Flask secret and is also the key used to derive per-user
flags, so keep it stable during an event. `INSTANCER_TOKEN` is the shared secret
between CTFd and the instancer. Generate both with something like:

```
python3 -c "import secrets; print(secrets.token_urlsafe(48))"
```

## 4. Bring the stack up

From the CTFd checkout, start everything as one project:

```
docker compose -f docker-compose.yml -f docker-compose.instancer.yml -f docker-compose.override.yml up -d --build
```

Traefik now listens on host port 11080 and forwards `/` to CTFd and
`/i/<token>/` to instances. CTFd is also reachable directly on its own host port
for admin use.

The instancer refuses to run more than `MAX_GLOBAL_INSTANCES` live instances
across all players (default 100); past that, players get a `global_limit` error.
Size it for your event by setting `MAX_GLOBAL_INSTANCES` in `.env`, keeping host
memory in mind (each instance is capped at its challenge's Memory MB).

## 5. Build the sample challenge images

The instancer starts containers from images that already exist on the host.
Build the two samples:

```
docker build -t chal-web-sample:latest samples/web
docker build -t chal-terminal-sample:latest samples/terminal
```

## 6. Create the challenges in CTFd

In the CTFd admin panel, create a new challenge and pick the "instancer" type.
Fill in the fields the plugin adds. Each sample's `challenge.json` lists the
values to use:

- Docker image: for example `chal-web-sample:latest`
- Kind: `web` for HTTP challenges, `tcp` for interactive terminal challenges
  served through ttyd
- Port: the port your container listens on inside the image (8080 for both
  samples)
- TTL minutes: how long an instance lives before the reaper removes it, within
  10 seconds of the deadline (30 is a
  reasonable default)
- Per user limit: how many live instances one account may have **across all
  instancer challenges**, not just this one. With 1, a player must stop their
  current instance before starting a different challenge. Starting the same
  challenge again just returns the existing instance. The value set on the
  challenge being started is the one checked, so keep it the same on every
  challenge unless you mean otherwise.
- Memory MB and CPUs: the per-instance resource caps
- Flag prefix: the text before the braces in the flag, for example `flag`

Players now see Start, Stop, and Status controls on the challenge page. They
never see a static flag, because the flag is generated per player.

## 7. Smoke test the control plane

`instancer/test_instancer.sh` exercises the instancer directly: health, create a
web instance, solve it through Traefik, create a ttyd instance, check the
per-user cap and idempotency, inspect the container hardening, confirm outbound
internet is blocked, then destroy everything. It reads a few settings from the
top of the file, which you can override with environment variables:

```
PROJECT_DIR=/path/to/CTFd COMPOSE_NET=ctfd_default CTFD_HOST=ctf.example.com \
  TRAEFIK_URL=http://localhost:11080 bash instancer/test_instancer.sh
```

Run it after the stack is up.
