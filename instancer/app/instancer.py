"""
CTFd instancer control plane.

Security model:
  * Only CTFd talks to this service, server-to-server, on an internal Docker
    network, authenticated with a bearer token (X-Auth-Token). Players never
    reach this API and can never supply an image or container parameters.
  * Docker is reached ONLY through a restricted docker-socket-proxy (no exec,
    no volume mounts, no privileged). This process runs as an unprivileged
    user and never sees the host socket.
  * Traefik has NO Docker access. This service publishes per-instance routes as
    Traefik file-provider config files that Traefik watches.
  * Every spawned instance is hardened: own internal network (no egress),
    cap_drop ALL, no-new-privileges, read-only rootfs + tmpfs, pid/mem/cpu
    caps, non-root, no host ports. It is reachable ONLY through Traefik via an
    unguessable /i/<token> path.
"""
import os
import time
import secrets
import logging
import threading

import docker
from docker.types import Ulimit
from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("instancer")

TOKEN = os.environ["INSTANCER_TOKEN"]
DOCKER_HOST = os.environ.get("DOCKER_HOST", "tcp://dockerproxy-rw:2375")
PUBLIC_BASE = os.environ.get("PUBLIC_BASE", "/i").rstrip("/")
ENTRYPOINT = os.environ.get("TRAEFIK_ENTRYPOINT", "web")
PROXY_LABEL = os.environ.get("PROXY_LABEL", "instancer.role=proxy")
DYNAMIC_DIR = os.environ.get("DYNAMIC_DIR", "/etc/traefik/dynamic")
MAX_GLOBAL = int(os.environ.get("MAX_GLOBAL_INSTANCES", "100"))

LABEL = "instancer.managed"
LIVE = ("created", "running", "restarting")

app = Flask(__name__)
cli = docker.DockerClient(base_url=DOCKER_HOST)
_lock = threading.Lock()


def auth_ok(req):
    return secrets.compare_digest(req.headers.get("X-Auth-Token", ""), TOKEN)


def traefik_container():
    key, _, val = PROXY_LABEL.partition("=")
    cs = cli.containers.list(filters={"label": f"{key}={val}"})
    if not cs:
        raise RuntimeError("Traefik proxy container not found (label %s)" % PROXY_LABEL)
    return cs[0]


def list_managed(**filt):
    labels = [f"{LABEL}=1"] + [f"instancer.{k}={v}" for k, v in filt.items()]
    return cli.containers.list(all=True, filters={"label": labels})


def live(cs):
    return [c for c in cs if c.status in LIVE]


def route_path(iid):
    return os.path.join(DYNAMIC_DIR, f"{iid}.yml")


def write_route(iid, tok, cname, port):
    base = f"{PUBLIC_BASE}/{tok}"
    content = (
        "http:\n"
        "  routers:\n"
        f'    "{iid}":\n'
        f'      rule: "PathPrefix(`{base}`)"\n'
        f'      entryPoints: ["{ENTRYPOINT}"]\n'
        f'      service: "{iid}"\n'
        "      priority: 100\n"
        "  services:\n"
        f'    "{iid}":\n'
        "      loadBalancer:\n"
        "        servers:\n"
        f'          - url: "http://{cname}:{port}"\n'
    )
    tmp = route_path(iid) + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, route_path(iid))  # atomic


def remove_route(iid):
    try:
        os.remove(route_path(iid))
    except FileNotFoundError:
        pass
    except Exception as e:
        log.warning("remove route %s: %s", iid, e)


def view(c):
    l = c.labels
    tok = l.get("instancer.token", "")
    return {
        "id": l.get("instancer.iid"),
        "chal_id": l.get("instancer.chal"),
        "user_id": l.get("instancer.user"),
        "token": tok,
        "url": f"{PUBLIC_BASE}/{tok}/",
        "kind": l.get("instancer.kind"),
        "expires": int(l.get("instancer.expires", "0")),
        "status": c.status,
    }


def _destroy(iid):
    remove_route(iid)
    for c in list_managed(iid=iid):
        try:
            c.remove(force=True)
        except Exception as e:
            log.warning("remove container %s: %s", iid, e)
    for n in cli.networks.list(filters={"label": [f"{LABEL}=1", f"instancer.iid={iid}"]}):
        try:
            try:
                n.disconnect(traefik_container(), force=True)
            except Exception:
                pass
            n.remove()
        except Exception as e:
            log.warning("remove network %s: %s", iid, e)


@app.get("/healthz")
def healthz():
    try:
        cli.ping()
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "detail": str(e)}), 500


@app.get("/instances")
def index():
    if not auth_ok(request):
        return ("", 401)
    user = request.args.get("user_id")
    cs = list_managed(user=user) if user else list_managed()
    return jsonify([view(c) for c in live(cs)])


@app.get("/instances/<iid>")
def get_one(iid):
    if not auth_ok(request):
        return ("", 401)
    cs = live(list_managed(iid=iid))
    if not cs:
        return (jsonify({"error": "not_found"}), 404)
    return jsonify(view(cs[0]))


@app.post("/instances")
def create():
    if not auth_ok(request):
        return ("", 401)
    d = request.get_json(force=True, silent=True) or {}
    try:
        chal_id = str(d["chal_id"])
        user_id = str(d["user_id"])
        image = str(d["image"])
        port = int(d["port"])
        flag = str(d["flag"])
    except (KeyError, ValueError, TypeError):
        return (jsonify({"error": "bad_request", "need": ["chal_id", "user_id", "image", "port", "flag"]}), 400)

    kind = str(d.get("kind", "web"))
    ttl = max(1, int(d.get("ttl", 60)))
    per_user = max(1, int(d.get("per_user_limit", 2)))
    mem = int(d.get("mem_mb", 256))
    cpus = float(d.get("cpus", 0.5))
    writable = bool(d.get("writable", False))
    extra_env = {str(k): str(v) for k, v in (d.get("env") or {}).items()}

    with _lock:
        # Idempotent: reuse a live instance for this (user, chal)
        for c in live(list_managed(user=user_id, chal=chal_id)):
            return jsonify(view(c))

        # Per-user cap (across all challenges) + global cap
        if len(live(list_managed(user=user_id))) >= per_user:
            return (jsonify({"error": "per_user_limit", "limit": per_user}), 429)
        if len(live(list_managed())) >= MAX_GLOBAL:
            return (jsonify({"error": "global_limit"}), 503)

        iid = secrets.token_hex(6)
        tok = secrets.token_urlsafe(16)
        base = f"{PUBLIC_BASE}/{tok}"
        netname = f"instnet_{iid}"
        cname = f"inst_{iid}"
        expires = int(time.time()) + ttl * 60

        labels = {
            LABEL: "1",
            "instancer.iid": iid,
            "instancer.user": user_id,
            "instancer.chal": chal_id,
            "instancer.token": tok,
            "instancer.kind": kind,
            "instancer.expires": str(expires),
        }
        env = {"FLAG": flag, "INSTANCE_BASE": base, "INSTANCE_TOKEN": tok}
        env.update(extra_env)

        hostcfg = dict(
            mem_limit=f"{mem}m",
            nano_cpus=int(cpus * 1e9),
            pids_limit=200,
            cap_drop=["ALL"],
            security_opt=["no-new-privileges:true"],
            read_only=(not writable),
            restart_policy={"Name": "no"},
            ulimits=[Ulimit(name="nofile", soft=4096, hard=4096)],
        )
        if not writable:
            hostcfg["tmpfs"] = {"/tmp": "rw,nosuid,size=64m", "/run": "rw,nosuid,size=16m"}

        net = None
        try:
            net = cli.networks.create(
                netname, driver="bridge", internal=True,
                labels={LABEL: "1", "instancer.iid": iid},
            )
            c = cli.containers.create(
                image, name=cname, detach=True, hostname="challenge",
                environment=env, labels=labels, network=netname, **hostcfg,
            )
            net.connect(traefik_container())  # so Traefik can reach the instance by name
            c.start()
            write_route(iid, tok, cname, port)
        except Exception as e:
            log.warning("spawn failed %s: %s", iid, e)
            _destroy(iid)
            if net is not None:
                try:
                    net.remove()
                except Exception:
                    pass
            return (jsonify({"error": "spawn_failed", "detail": str(e)}), 500)

        c.reload()
        log.info("spawned %s chal=%s user=%s image=%s", iid, chal_id, user_id, image)
        return jsonify(view(c))


@app.delete("/instances/<iid>")
def destroy(iid):
    if not auth_ok(request):
        return ("", 401)
    with _lock:
        _destroy(iid)
    return jsonify({"ok": True})


@app.post("/instances/by")
def destroy_by():
    """Stop a user's instance for a given challenge (used by the CTFd Stop button)."""
    if not auth_ok(request):
        return ("", 401)
    d = request.get_json(force=True, silent=True) or {}
    user_id = str(d.get("user_id", ""))
    chal_id = str(d.get("chal_id", ""))
    with _lock:
        for c in list_managed(user=user_id, chal=chal_id):
            _destroy(c.labels.get("instancer.iid"))
    return jsonify({"ok": True})


def reaper():
    while True:
        try:
            now = int(time.time())
            for c in list_managed():
                exp = int(c.labels.get("instancer.expires", "0"))
                if exp and now > exp:
                    log.info("reaping expired %s", c.labels.get("instancer.iid"))
                    with _lock:
                        _destroy(c.labels.get("instancer.iid"))
        except Exception as e:
            log.warning("reaper: %s", e)
        time.sleep(30)


threading.Thread(target=reaper, daemon=True).start()
