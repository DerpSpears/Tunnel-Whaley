# Cloudflare tunnel: how we did it and how to replicate it

## Why a tunnel

The host that runs the event does not need a public IP or open inbound ports. A
Cloudflare tunnel makes an outbound connection from the host to Cloudflare, and
Cloudflare serves your public hostname and forwards requests back down that
connection. For a CTF this is convenient and safe: nothing on the host is
directly exposed to the internet, and you get TLS on the public hostname without
managing certificates yourself.

## The key idea that makes it simple

Everything the outside world needs sits behind one local HTTP port. Traefik
listens on host port 11080 and does all the routing:

- `/` goes to CTFd (the scoreboard).
- `/i/<token>/` goes to a specific live challenge instance.

Because both the scoreboard and every instance live under the same hostname and
the same port, the tunnel only has to forward one thing: local port 11080. You
do not create a tunnel route per challenge, and you never expose raw TCP. This is
the whole trick, and it is why the pwn sample is wrapped in ttyd (a browser
terminal over HTTP) rather than served as a raw TCP port.

## How to replicate it on your own system

These steps assume the CTFd plus instancer stack from `02-setup.md` is already
running, with Traefik on host port 11080.

### 1. Install cloudflared

Install the `cloudflared` daemon on the host using Cloudflare's packages for
your distribution. Then log in, which opens a browser and links the daemon to
your Cloudflare account and one of your zones:

```
cloudflared tunnel login
```

### 2. Create a named tunnel

```
cloudflared tunnel create ctf
```

This creates the tunnel and writes a credentials JSON file for it on the host.
Note the tunnel id it prints.

### 3. Point a hostname at the tunnel

Route a DNS hostname in your Cloudflare zone to the tunnel:

```
cloudflared tunnel route dns ctf ctf.example.com
```

Replace `ctf.example.com` with the hostname you want players to use.

### 4. Write the tunnel config

Create a config file, usually at `~/.cloudflared/config.yml`, that sends your
hostname to Traefik on the local port. The single ingress rule below is all you
need:

```
tunnel: <your-tunnel-id>
credentials-file: /root/.cloudflared/<your-tunnel-id>.json

ingress:
  - hostname: ctf.example.com
    service: http://localhost:11080
  - service: http_status:404
```

Notice that the service target is Traefik (`localhost:11080`), not CTFd
directly. That is what lets both the scoreboard and the instance routes flow
through the tunnel.

### 5. Run the tunnel

Test it in the foreground first:

```
cloudflared tunnel run ctf
```

Once it works, install it as a service so it survives reboots:

```
cloudflared service install
```

### 6. Tell CTFd its public name

Set `SERVER_NAME` in your CTFd environment to the public hostname (see the
example override file) and keep `REVERSE_PROXY=true` so CTFd trusts the
forwarded headers. Restart the stack if you change these.

## Things that bite people

- Point the tunnel at Traefik, not at CTFd. If you point it straight at CTFd,
  the `/i/<token>` instance routes will not resolve, because CTFd does not know
  about them.
- Keep instance challenges on HTTP. A raw TCP pwn service will not travel
  through a normal HTTP tunnel. Wrap it in ttyd, as the pwn sample does, or use
  Cloudflare's separate TCP features, which are more involved to set up.
- WebSockets work through the tunnel by default, which is what ttyd needs. You
  do not have to enable anything special for that.
- If an instance loads but its assets or terminal do not, check that the
  challenge honors the `INSTANCE_BASE` path it is given. See
  `06-writing-challenges.md`.
