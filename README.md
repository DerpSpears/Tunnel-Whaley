# Tunnel-Whaley

A per-user challenge instancer for CTFd that runs behind a single Cloudflare tunnel.

It gives every player their own private copy of a challenge container, hands each
player a unique flag so sharing does not work, and routes everything (the
scoreboard and every live instance) through one HTTP entry point. That means no
extra ports, no raw TCP exposed to the internet, and one tunnel for the whole
event.

This repository contains only the instancer and two small sample challenges, so
you can read the whole thing end to end and drop it into your own CTFd setup.

## What is in here

- `instancer/app/` The instancer control plane. A small Flask service that
  creates, tracks, and destroys per-user challenge containers by talking to
  Docker through a restricted proxy.
- `ctfd-plugin/instancer/` The CTFd plugin. Adds an "instancer" challenge type,
  the Start, Stop, and Status controls players see, per-user dynamic flags, auto
  stop on solve, and the admin flag-sharing report page.
- `instancer/traefik/dynamic/` The Traefik static route for CTFd. Per-instance
  routes are written into this directory at runtime and are not committed.
- `instancer/challenges/web-sample/` A tiny HTTP challenge (a login bypass) that
  reads its flag from an environment variable.
- `instancer/challenges/pwn-sample/` A tiny interactive challenge served as a
  browser terminal through ttyd, so a classic netcat style task works over plain
  HTTP.
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

## Quick start

1. Raise Docker's network limit so more than ~30 instances can run: copy
   `docker/daemon.json.example` to `/etc/docker/daemon.json` and restart Docker.
2. Copy `ctfd-plugin/instancer` into your CTFd tree at `CTFd/plugins/instancer`.
3. Copy the `instancer/` folder and `compose/docker-compose.instancer.yml` into
   your CTFd checkout.
4. Copy `.env.example` to `.env` and set `SECRET_KEY` and `INSTANCER_TOKEN`.
5. Bring the stack up:
   `docker compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.instancer.yml up -d --build`
6. Build the sample images and create challenges of type "instancer" in the CTFd
   admin panel.

Full steps are in `docs/02-setup.md`.

## Credits

See `CREDITS.md`. This is built on CTFd, Traefik, the Tecnativa docker socket
proxy, and ttyd, and it borrows its overall shape from well known CTF instancer
designs.

## A note on secrets

Never commit your real `.env`. It holds `SECRET_KEY` (which also derives every
player flag) and `INSTANCER_TOKEN` (the shared secret between CTFd and the
instancer). The `.gitignore` in this repo already excludes it.
