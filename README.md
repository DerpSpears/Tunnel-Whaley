# Tunnel-Whaley

A per-user challenge instancer for CTFd that runs behind a single Cloudflare tunnel.

It gives every player their own private copy of a challenge container, hands each
player a unique flag so sharing does not work, and routes everything (the
scoreboard and every live instance) through one HTTP entry point. That means no
extra ports, no raw TCP exposed to the internet, and one tunnel for the whole
event.

This repository contains the instancer, a CTFd plugin, two sample challenges
(one web, one terminal) and `setup.sh`, which builds the whole stack from
scratch in one go.

## What is in here

- `instancer/app/` The instancer control plane. A small Flask service that
  creates, tracks, and destroys per-user challenge containers by talking to
  Docker through a restricted proxy.
- `ctfd-plugin/instancer/` The CTFd plugin. Adds an "instancer" challenge type,
  the Start, Stop, and Status controls players see, per-user dynamic flags, auto
  stop on solve, and the admin flag-sharing report page.
- `instancer/traefik/dynamic/` The Traefik static route for CTFd. Per-instance
  routes are written into this directory at runtime and are not committed.
- `setup.sh` Interactive installer: builds a fresh CTFd with everything below
  wired in. See "Setup with setup.sh".
- `samples/` The two sample challenge types to copy: `samples/web/` (an HTTP
  login bypass) and `samples/terminal/` (an interactive program served as a
  browser terminal through ttyd). Each has a `challenge.json` with its CTFd
  settings. See `samples/README.md`.
- `docker/daemon.json.example` Docker daemon address pools so the host can
  create enough per-instance networks.
- `compose/` The Docker Compose files that wire CTFd, Traefik, the Docker socket
  proxy, and the instancer together.
- `instancer/test_instancer.sh` An end to end smoke test for the control plane.
- `docs/` Setup, how it works, the Cloudflare tunnel method, the dynamic flag
  design, the flag-sharing reports, and how to write your own challenges.

## Read the docs in this order

1. `docs/01-how-it-works.md`
2. `docs/02-setup.md`
3. `docs/03-cloudflare-tunnel.md`
4. `docs/04-dynamic-flags.md`
5. `docs/05-flag-sharing-reports.md`
6. `docs/06-writing-challenges.md`

## Setup with setup.sh (recommended)

On a Linux host with Docker, run from the repository root:

```
git clone https://github.com/DerpSpears/Tunnel-Whaley.git
cd Tunnel-Whaley
./setup.sh
```

The script asks its questions first, shows a summary, and changes nothing until
you confirm. Press Enter to accept a default.

### Requirements

- Linux with Docker Engine running, and your user able to run `docker` (in the
  `docker` group, or run the script as root)
- Docker Compose v2.24.4 or newer (`docker compose version`)
- `git`, `curl`, `python3`
- `sudo`, only if you let it apply the Docker network fix
- Internet access to GitHub and Docker Hub

### What it asks

| Question | Default | Notes |
|---|---|---|
| Install directory | `~/tunnel-whaley-ctfd` | Must be new or empty and outside this repo. Its name becomes the Compose project name. |
| CTFd version | `3.8.7` | Any CTFd git tag. 3.8.7 is the tested one. |
| Public hostname | none | e.g. `ctf.example.com`. Used for the printed URLs and the tunnel snippet. |
| Listen on localhost only | yes if a hostname is given | Yes binds the ports to `127.0.0.1` (tunnel-only). No binds `0.0.0.0`. |
| Main port (Traefik) | `11080` | Players and the tunnel use this one. Checked to be free. |
| Direct CTFd port | `11000` | Admin and debugging only. |
| CTFd worker processes | CPU cores, 2 to 12 | Gunicorn gevent workers. |
| Max live instances, all players | `100` | Written to `.env` as `MAX_GLOBAL_INSTANCES`. |
| Max live instances per player | `1` | Counts across all challenges. Applied to the samples. |
| Instance lifetime (minutes) | `30` | Applied to the samples. |
| Apply the network-pool fix | yes | Only asked if `/etc/docker/daemon.json` has no address pools. See the note at the end. |
| Create the admin now | yes | Asks CTF name, `users` or `teams` mode, admin name, email and password. A blank password generates one, shown once at the end. Say no to use CTFd's web setup page instead. |
| Add the sample challenges | yes | Builds and creates every challenge in `samples/*/challenge.json`. |
| Run the end-to-end test | yes | See below. |

### What it does

1. Checks Docker, the Compose version, the CPU type (x86_64 or ARM) and whether
   Docker is rootless.
2. If you agreed: adds the address pools to `/etc/docker/daemon.json` (keeping
   any settings already there and a timestamped backup) and restarts Docker.
3. Clones CTFd at the chosen tag into the install directory.
4. Copies in the plugin (`CTFd/plugins/instancer`), the instancer service, the
   Traefik config, the instancer Compose file and `samples/`.
5. Writes `.env` (mode 600) with fresh random values for `SECRET_KEY`,
   `INSTANCER_TOKEN` and the database passwords, plus `MAX_GLOBAL_INSTANCES`.
6. Writes `docker-compose.override.yml` with your ports, listen address and
   worker count, and turns off CTFd's bundled nginx.
7. Writes `compose.sh`, a wrapper that runs `docker compose` with the right
   project name and files.
8. Builds an image for each sample and starts the stack, then waits until CTFd
   answers both directly and through Traefik.
9. Sets the footer to "Powered by CTFd and Tunnel-Whaley", linking to this repo.
   It is CTFd's Theme Footer setting, so you can change or remove it in
   Admin > Config > Theme.
10. If you said yes: runs CTFd's first-time setup, creates the sample challenges
    and runs the end-to-end test.

The end-to-end test does what a player does, through CTFd and Traefik. It starts
each sample, solves the web one and checks that the flag returned is this
player's own flag, checks that the terminal page loads, then checks that the
per-player limit refuses one instance too many. Every test instance is stopped
afterwards.

When it finishes it prints the URLs, the admin login and, if you gave a
hostname, the Cloudflare tunnel `ingress` snippet. Point the tunnel at the main
(Traefik) port, not at CTFd; see `docs/03-cloudflare-tunnel.md`.

### After setup

Everything lives in the install directory:

```
cd ~/tunnel-whaley-ctfd
./compose.sh ps                  # status
./compose.sh logs -f instancer   # follow a service's logs
./compose.sh restart ctfd
./compose.sh down                # stop (data in .data/ is kept)
```

- To change the instance cap later, edit `MAX_GLOBAL_INSTANCES` in `.env` and
  run `./compose.sh up -d`.
- To add challenges, see `samples/README.md`.
- To remove everything: `./compose.sh down -v`, then
  `sudo rm -rf ~/tunnel-whaley-ctfd`. Some files under `.data/` are owned by
  the containers' users, hence the `sudo`.

If setup stops partway, it prints these same removal commands. Run them, then
run `./setup.sh` again.

## Manual setup

If you would rather wire it into an existing CTFd yourself:

1. Raise Docker's network limit so more than ~30 instances can run: copy
   `docker/daemon.json.example` to `/etc/docker/daemon.json` and restart Docker.
2. Copy `ctfd-plugin/instancer` into your CTFd tree at `CTFd/plugins/instancer`.
3. Copy the `instancer/` folder and `compose/docker-compose.instancer.yml` into
   your CTFd checkout.
4. Copy `.env.example` to `.env` and set `SECRET_KEY` and `INSTANCER_TOKEN`.
5. Bring the stack up:
   `docker compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.instancer.yml up -d --build`
6. Build the sample images (`samples/`) and create challenges of type
   "instancer" in the CTFd admin panel.

Full steps are in `docs/02-setup.md`.

## Credits

See `CREDITS.md`. This is built on CTFd, Traefik, the Tecnativa docker socket
proxy, and ttyd, and it borrows its overall shape from well known CTF instancer
designs.

## A note on secrets

Never commit your real `.env`. It holds `SECRET_KEY` (which also derives every
player flag) and `INSTANCER_TOKEN` (the shared secret between CTFd and the
instancer). The `.gitignore` in this repo already excludes it.

## Note: instance limit (~30) and how to fix it

Out of the box, a host can only run about 30 instances at once. Each instance
gets its own private Docker network, and Docker's default address pools run out
after roughly 30 networks. When that happens, starting a new instance fails with:

```
could not find an available, non-overlapping IPv4 address pool among the defaults to assign to the network
```

This can be fixed by giving Docker smaller (/24) subnets, which raises the limit
to about 4,350 networks:

```
sudo cp docker/daemon.json.example /etc/docker/daemon.json   # merge by hand if the file already exists
sudo systemctl restart docker                                # briefly stops all containers on the host
docker info | grep -A3 "Default Address Pools"               # confirm the new pools
```

After that, the cap that applies is `MAX_GLOBAL_INSTANCES` (default 100), which
you can raise in `.env`. Full details are in `docs/02-setup.md`, step 0.
