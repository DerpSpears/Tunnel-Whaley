#!/usr/bin/env bash
# Tunnel-Whaley setup: builds a fresh CTFd + per-user instancer stack from
# scratch. It asks a few questions, then clones CTFd, installs the plugin and
# the instancer, generates secrets, raises Docker's network limit, starts the
# stack, creates the admin account and loads the sample challenges.
#
#   ./setup.sh            (run from the repository root)
#
# Nothing on the host is changed until you confirm the summary.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only overridden by the test suite; normal runs always use the real file.
DAEMON_JSON="${TW_DAEMON_JSON:-/etc/docker/daemon.json}"
MIN_COMPOSE="2.24.4"   # first version that supports the !override YAML tag
REPO_URL="https://github.com/DerpSpears/Tunnel-Whaley"

# ---------------------------------------------------------------- output ---
if [ -t 1 ]; then
  BOLD=$'\e[1m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RED=$'\e[31m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
  BOLD=; GRN=; YLW=; RED=; DIM=; RST=
fi
info()    { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn()    { printf '%s!!  %s%s\n' "$YLW" "$*" "$RST" >&2; }
die()     { printf '%sERROR:%s %s\n' "$RED" "$RST" "$*" >&2; [ "${started:-n}" = y ] && cleanup_hint; exit 1; }
cleanup_hint() {
  warn "Setup stopped before finishing. To start over, remove what was created:"
  printf '      cd %q && ./compose.sh down -v; cd .. && sudo rm -rf %q\n' "$install_dir" "$install_dir" >&2
}
section() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RST"; }

# ---------------------------------------------------------------- prompts ---
# ask VAR "Question" "default" [validator]
ask() {
  local __var=$1 q=$2 def=${3:-} check=${4:-} ans
  while :; do
    if [ -n "$def" ]; then printf '%s %s[%s]%s: ' "$q" "$DIM" "$def" "$RST"; else printf '%s: ' "$q"; fi
    IFS= read -r ans || die "input closed before setup finished"
    ans=${ans:-$def}
    if [ -n "$check" ] && ! "$check" "$ans"; then continue; fi
    printf -v "$__var" '%s' "$ans"
    return
  done
}

# ask_yn VAR "Question" y|n
ask_yn() {
  local __var=$1 q=$2 def=$3 ans hint
  [ "$def" = y ] && hint="Y/n" || hint="y/N"
  while :; do
    printf '%s %s[%s]%s: ' "$q" "$DIM" "$hint" "$RST"
    IFS= read -r ans || die "input closed before setup finished"
    case "${ans:-$def}" in
      [Yy]|[Yy][Ee][Ss]) printf -v "$__var" y; return ;;
      [Nn]|[Nn][Oo])     printf -v "$__var" n; return ;;
      *) echo "  Please answer y or n." ;;
    esac
  done
}

# ask_secret VAR "Question"  (blank = generate one)
ask_secret() {
  local __var=$1 q=$2 a b
  while :; do
    printf '%s %s[blank = generate one]%s: ' "$q" "$DIM" "$RST"
    IFS= read -r -s a || die "input closed before setup finished"; echo
    if [ -z "$a" ]; then printf -v "$__var" '%s' ""; return; fi
    if [ ${#a} -lt 8 ]; then echo "  Use at least 8 characters."; continue; fi
    if [ ${#a} -gt 128 ]; then echo "  Use at most 128 characters."; continue; fi
    printf 'Repeat it: '
    IFS= read -r -s b || die "input closed before setup finished"; echo
    if [ "$a" = "$b" ]; then printf -v "$__var" '%s' "$a"; return; fi
    echo "  They did not match, try again."
  done
}

# ------------------------------------------------------------- validators ---
is_posint() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] || { echo "  Enter a whole number of 1 or more."; return 1; }; }
is_nonempty() { [ -n "$1" ] || { echo "  This cannot be empty."; return 1; }; }
is_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "  Enter a valid email address."; return 1; }; }
is_username() {
  is_nonempty "$1" || return 1
  [[ $1 == *@* ]] && { echo "  The admin user name cannot be an email address."; return 1; }
  return 0
}
is_hostname() {
  [ -z "$1" ] && return 0
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* ]] \
    || { echo "  Enter a bare hostname like ctf.example.com (no http://, no path), or leave it blank."; return 1; }
}
is_user_mode() { [ "$1" = users ] || [ "$1" = teams ] || { echo "  Type users or teams."; return 1; }; }
port_free() {
  python3 -I - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(1)
PY
}
is_port() {
  [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { echo "  Enter a port between 1 and 65535."; return 1; }
  port_free "$1" || { echo "  Port $1 is already in use on this host. Pick another."; return 1; }
}
is_install_dir() {
  local d=$1
  [ -n "$d" ] || { echo "  This cannot be empty."; return 1; }
  [[ $d == /* ]] || d="$PWD/$d"
  case "$d/" in "$REPO_DIR"/*) echo "  Install somewhere outside this repository."; return 1 ;; esac
  if [ -e "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "  $d already exists and is not empty. Pick a new directory."; return 1
  fi
  local p; p=$(project_name "$d")
  if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$p" 2>/dev/null)" ]; then
    echo "  A Docker Compose project called '$p' already exists. Pick a directory with a different name."; return 1
  fi
}
project_name() { basename "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-' | sed 's/^[-_]*//'; }

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# ------------------------------------------------------- docker net pools ---
# Prints: ok | missing | invalid
pools_state() {
  python3 -I - "$DAEMON_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        txt = f.read()
except FileNotFoundError:
    print("missing"); sys.exit()
except PermissionError:
    print("unreadable"); sys.exit()
try:
    cfg = json.loads(txt) if txt.strip() else {}
except ValueError:
    print("invalid"); sys.exit()
print("ok" if cfg.get("default-address-pools") else "missing")
PY
}

apply_pools() {
  local tmp sudo=""
  tmp=$(mktemp)
  python3 -I - "$DAEMON_JSON" "$tmp" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src) as f:
        txt = f.read()
    cfg = json.loads(txt) if txt.strip() else {}
except FileNotFoundError:
    cfg = {}
cfg["default-address-pools"] = [
    {"base": "172.16.0.0/16", "size": 24},
    {"base": "10.208.0.0/12", "size": 24},
]
with open(dst, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  if [ ! -w "$(dirname "$DAEMON_JSON")" ] || { [ -e "$DAEMON_JSON" ] && [ ! -w "$DAEMON_JSON" ]; }; then
    sudo="sudo"
    info "Writing $DAEMON_JSON needs root, sudo may ask for your password."
  fi
  if [ -e "$DAEMON_JSON" ]; then
    $sudo cp -p "$DAEMON_JSON" "$DAEMON_JSON.bak.$(date +%Y%m%d%H%M%S)"
  fi
  $sudo install -m 0644 "$tmp" "$DAEMON_JSON"
  rm -f "$tmp"
  if [ "$DAEMON_JSON" = /etc/docker/daemon.json ]; then
    info "Restarting Docker to load the new address pools..."
    sudo systemctl restart docker
    local i
    for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
    docker info >/dev/null 2>&1 || die "Docker did not come back after the restart. Check: sudo journalctl -u docker"
    docker info 2>/dev/null | grep -q "172.16.0.0/16" \
      || warn "Docker restarted but does not report the new pools. Check $DAEMON_JSON."
  fi
}

# ===================================================================== main ===
cat <<EOF
${BOLD}Tunnel-Whaley setup${RST}
This builds a fresh CTFd with the per-user instancer. You will be asked a few
questions; press Enter to accept the default shown in [brackets].
EOF

# ------------------------------------------------------------ prerequisites --
section "Checking prerequisites"
for c in docker git curl python3; do
  command -v "$c" >/dev/null || die "'$c' is not installed. Install it and run setup.sh again."
done
docker info >/dev/null 2>&1 || die "Cannot talk to Docker. Start it, or add yourself to the docker group:
  sudo usermod -aG docker \$USER    (then log out and back in)"
compose_ver=$(docker compose version --short 2>/dev/null | sed 's/^v//') \
  || die "The 'docker compose' plugin (v2) is not installed."
version_ge "$compose_ver" "$MIN_COMPOSE" \
  || die "Docker Compose $compose_ver is too old; $MIN_COMPOSE or newer is needed."
rootless=n
docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && rootless=y
case "$(uname -m)" in
  x86_64|amd64)  ttyd_arch=x86_64 ;;
  aarch64|arm64) ttyd_arch=aarch64 ;;
  *) ttyd_arch=x86_64; warn "Untested CPU architecture $(uname -m); the terminal sample may not build." ;;
esac
info "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), Compose $compose_ver: OK"

# ---------------------------------------------------------------- questions --
section "Where to install"
ask install_dir "Install directory (CTFd is cloned here)" "$HOME/tunnel-whaley-ctfd" is_install_dir
[[ $install_dir == /* ]] || install_dir="$PWD/$install_dir"
project=$(project_name "$install_dir")
ask ctfd_version "CTFd version (git tag)" "3.8.7" is_nonempty
git ls-remote --exit-code --tags https://github.com/CTFd/CTFd.git "refs/tags/$ctfd_version" >/dev/null 2>&1 \
  || die "CTFd tag '$ctfd_version' was not found on GitHub (or GitHub is unreachable)."

section "Network"
ask public_host "Public hostname players will use, e.g. ctf.example.com (blank if none yet)" "" is_hostname
if [ -n "$public_host" ]; then local_def=y; else local_def=n; fi
ask_yn local_only "Listen on localhost only? (yes if a Cloudflare tunnel on this host is the only way in)" "$local_def"
if [ "$local_only" = y ]; then bind=127.0.0.1; else bind=0.0.0.0; fi
ask traefik_port "Main port, Traefik (players and the tunnel use this one)" "11080" is_port
while :; do
  ask ctfd_port "Direct CTFd port (admin and debugging only)" "11000" is_port
  [ "$ctfd_port" != "$traefik_port" ] && break
  echo "  It must differ from the main port."
done

section "Capacity"
cores=$(nproc 2>/dev/null || echo 2)
def_workers=$(( cores < 2 ? 2 : (cores > 12 ? 12 : cores) ))
ask workers "CTFd worker processes" "$def_workers" is_posint
ask max_global "Maximum live instances across all players" "100" is_posint
ask per_user "Maximum live instances per player (across all challenges)" "1" is_posint
ask ttl "Minutes an instance lives before it is stopped" "30" is_posint

pools=skip
if [ "$rootless" = y ]; then
  warn "Rootless Docker detected: skipping the address-pool fix. Configure pools in your rootless daemon.json yourself."
else
  state=$(pools_state)
  case "$state" in
    ok) info "Docker address pools are already configured; the ~30 instance limit does not apply." ;;
    invalid) die "$DAEMON_JSON is not valid JSON. Fix it by hand, then run setup.sh again." ;;
    *)
      echo
      echo "Docker's default network pools allow only about 30 live instances. setup.sh can"
      echo "add /24 pools to $DAEMON_JSON (a backup is kept) and restart Docker,"
      echo "which raises the limit to about 4,350. The restart briefly stops ALL containers"
      echo "on this host; ones with a restart policy start again by themselves."
      ask_yn fix_pools "Apply the network-pool fix now?" y
      [ "$fix_pools" = y ] && pools=apply
      if [ "$pools" = skip ] && [ "$max_global" -gt 25 ]; then
        warn "Without the fix, starting instances will fail after about 30 are live."
      fi ;;
  esac
fi

section "CTFd first-time setup"
ask_yn do_init "Create the admin account and configure CTFd now? (no = use the web setup page later)" y
do_samples=n; do_test=n; admin_pw=""; gen_pw=n
if [ "$do_init" = y ]; then
  ask ctf_name "CTF name" "Tunnel-Whaley CTF" is_nonempty
  ask user_mode "Mode: users or teams" "users" is_user_mode
  ask admin_name "Admin user name" "admin" is_username
  ask admin_email "Admin email" "" is_email
  ask_secret admin_pw "Admin password"
  if [ -z "$admin_pw" ]; then
    admin_pw=$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(15))'); gen_pw=y
  fi
  ask_yn do_samples "Add the sample challenges from samples/ (web + terminal)?" y
  if [ "$do_samples" = y ]; then
    ask_yn do_test "Run an end-to-end test (start each sample through CTFd, solve the web one, stop them)?" y
  fi
fi

# ------------------------------------------------------------------ summary --
section "Summary"
cat <<EOF
  Install directory   $install_dir   (Compose project: $project)
  CTFd version        $ctfd_version
  Public hostname     ${public_host:-(none yet)}
  Listen address      $bind
  Main port           $traefik_port   (Traefik: CTFd + instances)
  Direct CTFd port    $ctfd_port
  CTFd workers        $workers
  Max live instances  $max_global total, $per_user per player, ${ttl} min each
  Docker pool fix     $([ "$pools" = apply ] && echo "apply (restarts Docker)" || echo "no change")
EOF
if [ "$do_init" = y ]; then
  cat <<EOF
  CTF                 $ctf_name ($user_mode mode)
  Admin               $admin_name <$admin_email>
  Sample challenges   $([ "$do_samples" = y ] && echo yes || echo no)$([ "$do_test" = y ] && echo ", with end-to-end test")
EOF
fi
echo
ask_yn go "Go ahead?" y
[ "$go" = y ] || { echo "Nothing was changed."; exit 0; }

started=y
trap 'cleanup_hint' ERR

# ---------------------------------------------------------------- the work --
if [ "$pools" = apply ]; then
  section "Raising Docker's network limit"
  apply_pools
fi

section "Getting CTFd $ctfd_version"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$ctfd_version" \
  https://github.com/CTFd/CTFd.git "$install_dir"

section "Installing the plugin and the instancer"
cp -r "$REPO_DIR/ctfd-plugin/instancer" "$install_dir/CTFd/plugins/instancer"
mkdir -p "$install_dir/instancer"
cp -r "$REPO_DIR/instancer/app" "$REPO_DIR/instancer/traefik" "$install_dir/instancer/"
cp "$REPO_DIR/instancer/test_instancer.sh" "$install_dir/instancer/"
cp "$REPO_DIR/compose/docker-compose.instancer.yml" "$install_dir/"
cp -r "$REPO_DIR/samples" "$install_dir/samples"
# The instancer runs as an unprivileged user (65534) and writes one route file
# per live instance here; Traefik only reads it.
chmod 0777 "$install_dir/instancer/traefik/dynamic"

gen() { python3 -I -c 'import secrets; print(secrets.token_hex(32))'; }
(
  umask 077
  cat > "$install_dir/.env" <<EOF
# Generated by Tunnel-Whaley setup.sh. Keep this file private.
# SECRET_KEY also derives every player's flag: keep it stable for the event.
SECRET_KEY=$(gen)
INSTANCER_TOKEN=$(gen)
DB_PASSWORD=$(gen)
DB_ROOT_PASSWORD=$(gen)
MAX_GLOBAL_INSTANCES=$max_global
EOF
)

cat > "$install_dir/docker-compose.override.yml" <<EOF
# Generated by Tunnel-Whaley setup.sh.
# Ports, workers and database passwords for this host. Secrets come from .env.
services:
  ctfd:
    ports: !override
      - "$bind:$ctfd_port:8000"
    environment:
      - SECRET_KEY=\${SECRET_KEY}
      - DATABASE_URL=mysql+pymysql://ctfd:\${DB_PASSWORD}@db/ctfd
      - WORKERS=$workers
      - WORKER_CLASS=gevent
      - WORKER_TEMP_DIR=/dev/shm
      - GUNICORN_CMD_ARGS=--worker-connections=2000 --timeout=120 --graceful-timeout=30 --keep-alive=5 --max-requests=5000 --max-requests-jitter=500
      - REVERSE_PROXY=true
      # .env is private to its owner (mode 600) and CTFd reads its settings
      # from the environment above, so stop Flask from trying to open it.
      - FLASK_SKIP_DOTENV=1

  db:
    environment:
      - MARIADB_PASSWORD=\${DB_PASSWORD}
      - MARIADB_ROOT_PASSWORD=\${DB_ROOT_PASSWORD}

  traefik:
    ports: !override
      - "$bind:$traefik_port:80"
    labels:
      - "instancer.role=proxy-$project"   # matched by PROXY_LABEL below

  # Traefik is the front door, so CTFd's bundled nginx is not used.
  nginx:
    profiles:
      - donotstart

  # Each install gets its own instance namespace and proxy label, so several
  # Tunnel-Whaley stacks on one host never touch each other's instances.
  instancer:
    environment:
      - INSTANCER_NAMESPACE=$project
      - PROXY_LABEL=instancer.role=proxy-$project

  # SELinux (Fedora, RHEL, ...) never lets a container open docker.sock, so
  # the socket proxy runs unconfined. No effect on hosts without SELinux.
  # Challenge instances stay fully confined.
  dockerproxy-rw:
    security_opt:
      - label=disable
EOF

cat > "$install_dir/compose.sh" <<EOF
#!/bin/sh
# Run docker compose for this Tunnel-Whaley install, e.g.
#   ./compose.sh ps    ./compose.sh logs -f instancer    ./compose.sh down
cd "\$(dirname "\$0")" || exit 1
exec docker compose -p $project -f docker-compose.yml -f docker-compose.instancer.yml -f docker-compose.override.yml "\$@"
EOF
chmod +x "$install_dir/compose.sh"

# SELinux hosts: label the install directory once so containers may use the
# bind mounts (what ":z" would do, but up front, so containers starting in
# parallel never race a relabel). New files inherit the label.
if command -v getenforce >/dev/null && [ "$(getenforce 2>/dev/null)" != Disabled ]; then
  info "SELinux is on: labelling $install_dir for container use."
  chcon -R -t container_file_t "$install_dir" \
    || die "Could not set the SELinux label on $install_dir (chcon failed)."
fi
"$install_dir/compose.sh" config -q || die "The generated Compose configuration is invalid."
# The override is loaded last so its ports win; make sure only the two chosen
# ports end up published.
published=$("$install_dir/compose.sh" config --format json | python3 -I -c '
import json, sys
cfg = json.load(sys.stdin)
ports = set()
for svc in cfg.get("services", {}).values():
    for p in svc.get("ports") or []:
        ports.add(str(p.get("published")))
print(" ".join(sorted(ports)))')
[ "$published" = "$(printf '%s\n' "$ctfd_port" "$traefik_port" | sort | tr '\n' ' ' | sed 's/ $//')" ] \
  || die "The Compose configuration would publish ports [$published], expected only $ctfd_port and $traefik_port."

section "Building challenge images"
for f in "$install_dir"/samples/*/challenge.json; do
  [ -e "$f" ] || continue
  d=$(dirname "$f")
  img=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["docker_image"])' "$f")
  info "$img  <-  samples/$(basename "$d")"
  docker build -q --build-arg "TTYD_ARCH=$ttyd_arch" -t "$img" "$d" >/dev/null
done

section "Starting the stack (the first build of CTFd takes a few minutes)"
"$install_dir/compose.sh" up -d --build

info "Waiting for CTFd to answer..."
ok=n
for i in $(seq 1 90); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ctfd_port/healthcheck")" = 200 ]; then ok=y; break; fi
  sleep 2
done
[ "$ok" = y ] || die "CTFd did not become healthy in 3 minutes. Look at: $install_dir/compose.sh logs ctfd"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$traefik_port/healthcheck")
[ "$code" = 200 ] || die "CTFd is up but Traefik on port $traefik_port returned $code. Look at: $install_dir/compose.sh logs traefik"
info "CTFd is up, directly and through Traefik."

# Footer credit. Stored as CTFd's "theme_footer" setting, so admins can change
# or remove it later in Admin > Config > Theme. It extends the theme's own
# "Powered by CTFd" line, or adds its own line on themes without one.
info "Adding the 'Powered by CTFd and Tunnel-Whaley' footer..."
footer_sql=$(REPO_URL="$REPO_URL" python3 -I - <<'PY'
import os
html = """<script>
(function () {
  var a = document.createElement("a");
  a.href = "%s";
  a.target = "_blank";
  a.rel = "noopener";
  a.className = "text-secondary";
  a.innerHTML = '<small class="text-muted">Tunnel-Whaley</small>';
  var box = document.querySelector("footer.footer .container");
  if (box) {
    var and = document.createElement("small");
    and.className = "text-muted";
    and.textContent = " and ";
    box.appendChild(and);
    box.appendChild(a);
  } else {
    var d = document.createElement("div");
    d.className = "text-center py-3";
    d.innerHTML = '<small class="text-muted">Powered by <a class="text-secondary" href="https://ctfd.io">CTFd</a> and </small>';
    d.appendChild(a);
    document.body.appendChild(d);
  }
})();
</script>""" % os.environ["REPO_URL"]
v = html.replace("\\", "\\\\").replace("'", "\\'")
print("DELETE FROM config WHERE `key`='theme_footer';")
print("INSERT INTO config (`key`, value) VALUES ('theme_footer', '%s');" % v)
PY
)
db_pw=$(grep '^DB_PASSWORD=' "$install_dir/.env" | cut -d= -f2-)
printf '%s\n' "$footer_sql" | "$install_dir/compose.sh" exec -T -e MYSQL_PWD="$db_pw" db mariadb -uctfd ctfd \
  || die "Could not save the footer setting in the CTFd database."
"$install_dir/compose.sh" exec -T cache redis-cli FLUSHALL >/dev/null   # drop any cached copy of the setting

# ------------------------------------------------- CTFd setup, samples, test --
if [ "$do_init" = y ]; then
  section "Configuring CTFd"
  CTFD_URL="http://127.0.0.1:$ctfd_port" TRAEFIK_URL="http://127.0.0.1:$traefik_port" \
  CTF_NAME="$ctf_name" USER_MODE="$user_mode" ADMIN_NAME="$admin_name" \
  ADMIN_EMAIL="$admin_email" ADMIN_PASSWORD="$admin_pw" \
  DO_SAMPLES="$do_samples" DO_TEST="$do_test" SAMPLES_DIR="$install_dir/samples" \
  PER_USER="$per_user" TTL="$ttl" ENV_FILE="$install_dir/.env" \
  python3 -I - <<'PY'
import glob, hashlib, hmac, json, os, re, sys, time
import urllib.error, urllib.parse, urllib.request
from http.cookiejar import CookieJar

E = os.environ
CTFD, TRAEFIK = E["CTFD_URL"], E["TRAEFIK_URL"]
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))


def say(msg):
    print("==> " + msg, flush=True)


def fail(msg):
    print("ERROR: " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


def http(method, url, data=None, headers=None, opener=op):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with opener.open(req, timeout=60) as r:
            return r.status, r.read().decode("utf-8", "replace"), r.geturl()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), url


def csrf():
    _, html, _ = http("GET", CTFD + "/admin/challenges")
    m = re.search(r"'csrfNonce':\s*\"([^\"]+)\"", html)
    if not m:
        fail("could not get a CSRF token from CTFd (is the admin logged in?)")
    return m.group(1)


def api(method, path, body, token):
    data = json.dumps(body).encode() if body is not None else None
    s, txt, _ = http(method, CTFD + path, data,
                     {"Content-Type": "application/json", "Accept": "application/json", "CSRF-Token": token})
    try:
        return s, json.loads(txt)
    except ValueError:
        return s, {"raw": txt[:300]}


# --- first-time setup -------------------------------------------------------
s, html, final = http("GET", CTFD + "/setup")
m = re.search(r'name="nonce"[^>]*value="([^"]+)"', html) or re.search(r'value="([^"]+)"[^>]*name="nonce"', html)
if "/setup" not in final or not m:
    fail("CTFd is already set up; setup.sh only configures a fresh install.")
form = {
    "ctf_name": E["CTF_NAME"], "ctf_description": "", "user_mode": E["USER_MODE"],
    "name": E["ADMIN_NAME"], "email": E["ADMIN_EMAIL"], "password": E["ADMIN_PASSWORD"],
    "ctf_theme": "core", "start": "", "end": "", "nonce": m.group(1), "_submit": "Finish",
}
s, html, final = http("POST", CTFD + "/setup", urllib.parse.urlencode(form).encode(),
                      {"Content-Type": "application/x-www-form-urlencoded"})
if "/setup" in final:
    errs = re.findall(r'alert-danger[^>]*>\s*(?:<[^>]+>\s*)*([^<]+)', html)
    fail("CTFd rejected the setup: " + ("; ".join(e.strip() for e in errs) or "status %s" % s))
say("Admin account '%s' created; CTFd is in %s mode." % (E["ADMIN_NAME"], E["USER_MODE"]))

if E["DO_SAMPLES"] != "y":
    sys.exit(0)

# --- sample challenges --------------------------------------------------------
token = csrf()
created = []
for path in sorted(glob.glob(os.path.join(E["SAMPLES_DIR"], "*", "challenge.json"))):
    spec = json.load(open(path))
    test = spec.pop("test", None)
    spec.update({"type": "instancer", "state": "visible",
                 "ttl_minutes": int(E["TTL"]), "per_user_limit": int(E["PER_USER"])})
    s, r = api("POST", "/api/v1/challenges", spec, token)
    if not r.get("success"):
        fail("could not create challenge '%s': %s" % (spec["name"], r))
    created.append((r["data"]["id"], spec, test))
    say("Challenge #%d '%s' (%s, %s) created." % (r["data"]["id"], spec["name"], spec["kind"], spec["docker_image"]))

if E["DO_TEST"] != "y":
    sys.exit(0)

# --- end-to-end test ----------------------------------------------------------
secret = b""
for line in open(E["ENV_FILE"]):
    if line.startswith("SECRET_KEY="):
        secret = line.split("=", 1)[1].strip().encode()
plain = urllib.request.build_opener()   # players do not carry the admin cookie


def expected_flag(cid, prefix, account_id=1):
    d = hmac.new(secret, ("%s:%s" % (cid, account_id)).encode(), hashlib.sha256).hexdigest()[:24]
    return "%s{%s}" % (prefix, d)


def wait_up(url):
    for _ in range(40):
        s, body, _ = http("GET", url, opener=plain)
        if s == 200:
            return body
        time.sleep(1)
    fail("instance at %s never answered with 200" % url)


def start(cid):
    return api("POST", "/plugins/instancer/instance", {"challenge_id": cid}, token)


def stop(cid):
    api("DELETE", "/plugins/instancer/instance?challenge_id=%d" % cid, None, token)


say("Testing every sample through CTFd and Traefik...")
for cid, spec, test in created:
    s, r = start(cid)
    if not r.get("success"):
        fail("starting '%s' failed: %s" % (spec["name"], r))
    url = TRAEFIK + r["data"]["url"]
    body = wait_up(url)
    if test and test.get("method") == "POST":
        _, body, _ = http("POST", url, test.get("body", "").encode(),
                          {"Content-Type": "application/x-www-form-urlencoded"}, opener=plain)
    if test and test.get("expect") == "flag":
        if E["USER_MODE"] == "users":
            want = expected_flag(cid, spec.get("flag_prefix", "flag"))
            if want not in body:
                fail("'%s' did not return the expected per-player flag %s" % (spec["name"], want))
        elif not re.search(re.escape(spec.get("flag_prefix", "flag")) + r"\{[0-9a-f]{24}\}", body):
            fail("'%s' did not return a per-player flag" % spec["name"])
        say("  %-18s solved, per-player flag returned" % spec["name"])
    elif test and test.get("expect"):
        if test["expect"].lower() not in body.lower():
            fail("'%s' page did not contain '%s'" % (spec["name"], test["expect"]))
        say("  %-18s instance page loads" % spec["name"])
    else:
        say("  %-18s instance answers" % spec["name"])
    stop(cid)

# Per-player cap: hold `limit` instances, the next one must be refused.
limit = int(E["PER_USER"])
if len(created) > limit:
    held = [c[0] for c in created[:limit]]
    for cid in held:
        start(cid)
    s, r = start(created[limit][0])
    for cid in held:
        stop(cid)
    if s != 429:
        stop(created[limit][0])
        fail("per-player limit of %d was not enforced (got %s %s)" % (limit, s, r))
    say("  per-player limit of %d is enforced" % limit)
say("End-to-end test passed; test instances were stopped.")
PY
fi

trap - ERR
started=n

# ------------------------------------------------------------------ the end --
host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[ "$bind" = 127.0.0.1 ] && host_ip=127.0.0.1
host_ip=${host_ip:-127.0.0.1}
section "Done"
cat <<EOF
  Players / tunnel   http://$host_ip:$traefik_port$( [ -n "$public_host" ] && echo "   (public: https://$public_host once the tunnel is set up)")
  Direct CTFd        http://$host_ip:$ctfd_port   (admin/debugging only)
EOF
if [ "$do_init" = y ]; then
  echo "  Admin login        $admin_name / $admin_email"
  if [ "$gen_pw" = y ]; then
    echo "  Admin password     ${BOLD}$admin_pw${RST}   (generated: save it now, it is not stored anywhere)"
  fi
else
  echo "  Finish the CTFd setup page at http://$host_ip:$traefik_port/setup"
fi
cat <<EOF

  Files              $install_dir/.env (secrets), docker-compose.override.yml (ports, workers)
  Manage             cd $install_dir && ./compose.sh ps | logs -f | restart | down
  Footer             "Powered by CTFd and Tunnel-Whaley" (change it in Admin > Config > Theme)
EOF
if [ -n "$public_host" ]; then
  cat <<EOF

  Point your Cloudflare tunnel at Traefik, not at CTFd, e.g. in config.yml:
    ingress:
      - hostname: $public_host
        service: http://localhost:$traefik_port
      - service: http_status:404
  See docs/03-cloudflare-tunnel.md for the full steps.
EOF
fi
echo
echo "  Add your own challenges: see samples/README.md and docs/06-writing-challenges.md."
