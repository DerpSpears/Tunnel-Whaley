# Credits and inspiration

This project stands on a lot of existing open source work. The overall design is
a common pattern in CTF hosting, and the building blocks below did the heavy
lifting. Credit where it is due.

## Tools and projects this is built on

- CTFd, the scoreboard and challenge platform this plugs into. The instancer is
  written as a standard CTFd challenge-type plugin.
- Traefik, used as the single reverse proxy. Its file provider and live config
  watching are what let us add and remove per-instance routes with no restarts.
- Tecnativa docker-socket-proxy, used to give the control plane a small,
  restricted slice of the Docker API instead of full access to the host socket.
- ttyd by tsl0922, used to expose interactive netcat style challenges as a
  browser terminal over HTTP and WebSocket, so they work through a single tunnel
  with no raw TCP.
- Cloudflare Tunnel (cloudflared), used to publish the event without opening any
  inbound ports on the host.
- Docker and Docker Compose, for building and running everything.
- Flask, gunicorn, and the docker Python SDK, which the control plane is written
  with.

## Design inspiration

The idea of giving each player a private, disposable challenge instance behind
one proxy is well established in the CTF community. Projects like redpwn's klodd
and the per-user dynamic flag approach used by several open CTF platforms were
the reference points for how this should behave: unique flags per player, short
lived instances, and a single front door. This implementation is our own,
written to fit a file-provider Traefik setup and a Cloudflare tunnel, but the
shape of the solution owes a lot to that prior work.

If you recognize a specific project that should be credited here more directly,
please open an issue or a pull request and we will add it.
