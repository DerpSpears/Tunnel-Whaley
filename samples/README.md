# Sample challenges

Two starting points, one for each kind of instanced challenge. Copy the one
closest to what you are building.

| Folder | Kind | What the player gets | Image |
|---|---|---|---|
| `web/` | `web` | Their own copy of a website at `/i/<token>/` | `chal-web-sample:latest` |
| `terminal/` | `tcp` | Their own terminal in the browser (ttyd), running one program | `chal-terminal-sample:latest` |

Both read the player's flag from the `FLAG` environment variable, which the
instancer sets when it starts the container. Neither has a flag baked in.

## web: Login Portal

A one-file Python web server with a weak login form. Entering a quote character,
for example `' OR '1'='1`, gets you past the login and shows the flag. It answers
every path with the same page and uses only relative links, so it works under
`/i/<token>/`.

## terminal: Guess the Number

A small Python program, served in the browser through ttyd. Guess a number
from 1 to 100 within seven tries to get the flag. Use it as a template for any
"connect with netcat" style challenge: replace `vuln.py` and keep the ttyd
wrapper in the Dockerfile. ttyd runs only that program, so players never get a
shell.

## challenge.json

Each folder has a `challenge.json` holding the challenge's CTFd settings.
`setup.sh` reads every `samples/*/challenge.json`, builds the image and creates
the challenge. You can also copy the values into the CTFd admin form by hand.

```json
{
  "name": "Login Portal",          // shown to players
  "category": "Web",
  "value": 100,                    // points
  "description": "...",
  "docker_image": "chal-web-sample:latest",
  "kind": "web",                   // "web" or "tcp" (terminal through ttyd)
  "port": 8080,                    // port the app listens on inside the container
  "ttl_minutes": 30,               // replaced by the lifetime you give setup.sh
  "per_user_limit": 1,             // replaced by the per-player limit you give setup.sh
  "mem_mb": 256,
  "cpus": "0.5",
  "flag_prefix": "flag",           // flags look like flag{<24 hex chars>}
  "test": { "method": "POST", "body": "...", "expect": "flag" }
}
```

(Real JSON has no comments; they are only here to explain the fields.)

`test` is optional and only used by setup.sh's end-to-end test:

- `"expect": "flag"` sends the request (`GET`, or `POST` with `body`) and checks
  that the response contains this player's correct flag.
- `"expect": "<text>"` checks that the page contains that text.
- No `test` only checks that the instance answers.

## Adding your own challenge

1. Copy a folder: `cp -r samples/web samples/my-challenge`.
2. Change the app, keeping these rules (details in
   `docs/06-writing-challenges.md`):
   - read the flag from `FLAG`
   - listen on the port named in `challenge.json`
   - work under a sub-path: relative links only, or read `INSTANCE_BASE`
   - run as a non-root user on a read-only filesystem, with no internet access
3. Edit `challenge.json`: give it a new `name` and a new `docker_image` tag.

Then either:

- **Before running setup.sh:** leave the folder in `samples/`. setup.sh builds
  and creates it with the others.
- **On an install that is already running:** build the image on the host
  (`docker build -t chal-my-challenge:latest samples/my-challenge`), then create
  the challenge in CTFd under Admin > Challenges > Create, type "instancer",
  using the values from `challenge.json`.

The instancer never builds images. It only starts images that already exist on
the host, so rebuild the image whenever you change the challenge.
