# Writing your own instanced challenges

This project ships two tiny samples you can copy, in `samples/`. See
`samples/README.md` for how to copy one and how `challenge.json` works. The rules below are what make
a challenge behave well behind the instancer and the tunnel.

## The contract every challenge follows

1. Read the flag from the `FLAG` environment variable. Never bake a real flag
   into the image. The instancer injects a per-player value at start time.
2. Listen on one TCP port inside the container. Tell CTFd that port number when
   you create the challenge. Do not publish host ports yourself.
3. Expect a read-only root filesystem, no outbound internet, dropped
   capabilities, and a non-root user. Write only to `/tmp` if you must, and keep
   it small.
4. Work under a subpath. Your instance is served at `/i/<token>/`, not at `/`.
   The instancer passes that base path to the container as `INSTANCE_BASE`.

## Web challenges (kind: web)

See `samples/web`. It is a single-file Python HTTP server
that:

- reads the flag from `FLAG`
- answers every path with the same page, so it works under `/i/<token>/` without
  needing the proxy to strip the prefix
- uses only relative links and form actions, so the browser stays on the
  instance path

The sample is a deliberately weak login form. Submitting a quote character, or
the classic `' OR '1'='1` style input, bypasses the check and prints the flag.
It is there to prove the plumbing end to end, not to be a hard challenge.

The simplest way to be subpath-safe is to serve the same content on any path and
keep every asset reference relative. If your framework needs to know its base
path, read `INSTANCE_BASE` and configure the framework's base URL from it.

## Interactive challenges (kind: tcp) through ttyd

See `samples/terminal`. A raw TCP service cannot travel through a
normal HTTP tunnel, so instead of exposing a socket we run the program inside
ttyd, which serves an interactive terminal over HTTP and WebSocket. The player
gets a real terminal in the browser, and everything still rides the one tunnel.

The important details in that Dockerfile:

- it downloads the official static ttyd release binary, because ttyd is not in
  the Debian package repositories
- it runs as a non-root `player` user
- it launches ttyd with `-b "$INSTANCE_BASE"` so the terminal's own asset and
  WebSocket URLs line up with `/i/<token>/`
- it uses `-W` to allow keyboard input
- it runs one fixed program (the challenge), so no shell is ever exposed to the
  player

The sample program is a guess-the-number game that prints the flag on a correct
guess. Swap in your own binary or script and keep the same ttyd wrapper.

## Checklist before you ship a challenge

- The image reads `FLAG` from the environment and prints or grants it only on a
  real solve.
- The service listens on the port you will configure in CTFd.
- Assets and links are relative, or the app respects `INSTANCE_BASE`.
- The container starts fine as a non-root user on a read-only root filesystem.
- The image is built and present on the host (the instancer does not build
  images, it only runs them).
- You set sensible TTL, per-user limit, memory, and CPU values on the challenge.
