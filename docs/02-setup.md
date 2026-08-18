# Setup

This guide sets up CTFd with the instancer on a fresh host. The commands assume
a Linux host with Docker Engine and the `docker compose` plugin installed.

## Prerequisites

- A Linux host with Docker Engine and the `docker compose` plugin.
- A CTFd checkout (the standard CTFd repository). This project is a plugin plus
  a few extra services that layer on top of a normal CTFd Compose setup.
- Optional but recommended: a Cloudflare account and the `cloudflared` daemon if
  you want to expose the event through a tunnel. See `03-cloudflare-tunnel.md`.

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
docker compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.instancer.yml up -d --build
```

Traefik now listens on host port 11080 and forwards `/` to CTFd and
`/i/<token>/` to instances. CTFd is also reachable directly on its own host port
for admin use.

## 5. Build the sample challenge images

The instancer starts containers from images that already exist on the host.
Build the two samples:

```
docker build -t chal-web-sample:latest instancer/challenges/web-sample
docker build -t chal-pwn-sample:latest instancer/challenges/pwn-sample
```

## 6. Create the challenges in CTFd

In the CTFd admin panel, create a new challenge and pick the "instancer" type.
Fill in the fields the plugin adds:

- Docker image: for example `chal-web-sample:latest`
- Kind: `web` for HTTP challenges, `tcp` for interactive terminal challenges
  served through ttyd
- Port: the port your container listens on inside the image (8080 for both
  samples)
- TTL minutes: how long an instance lives before the reaper stops it (30 is a
  reasonable default)
- Per user limit: how many instances of this challenge one account may run at
  once (usually 1)
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
