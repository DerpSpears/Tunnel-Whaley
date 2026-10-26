import hmac
import hashlib
import os
import datetime

import requests
from flask import Blueprint, request, jsonify, current_app, render_template

from CTFd.models import Challenges, db
from CTFd.plugins import (
    register_plugin_assets_directory,
    register_admin_plugin_menu_bar,
)
from CTFd.plugins.challenges import CHALLENGE_CLASSES, BaseChallenge
from CTFd.utils.decorators import authed_only, admins_only
from CTFd.utils.user import get_current_user
from CTFd.utils.modes import get_model

try:
    from CTFd.utils.logging import log as ctfd_log
except Exception:  # pragma: no cover
    def ctfd_log(*args, **kwargs):
        pass

INT_FIELDS = ("port", "ttl_minutes", "per_user_limit", "mem_mb")


class InstancerChallengeModel(Challenges):
    __tablename__ = "instancer_challenge"
    __mapper_args__ = {"polymorphic_identity": "instancer"}
    id = db.Column(
        db.Integer, db.ForeignKey("challenges.id", ondelete="CASCADE"), primary_key=True
    )
    docker_image = db.Column(db.String(256))
    kind = db.Column(db.String(16), default="web")  # "web" or "tcp"
    port = db.Column(db.Integer, default=8000)
    ttl_minutes = db.Column(db.Integer, default=30)
    per_user_limit = db.Column(db.Integer, default=1)
    mem_mb = db.Column(db.Integer, default=256)
    cpus = db.Column(db.String(8), default="0.5")
    flag_prefix = db.Column(db.String(64), default="flag")

    def __init__(self, *args, **kwargs):
        super(InstancerChallengeModel, self).__init__(**kwargs)


class FlagShareReport(db.Model):
    """Records incidents where an account submitted another account's unique
    dynamic flag (flag sharing / cheating). Surfaced on the admin panel."""

    __tablename__ = "instancer_flag_reports"
    id = db.Column(db.Integer, primary_key=True)
    challenge_id = db.Column(db.Integer)
    submitter_id = db.Column(db.Integer)  # account_id that submitted the flag
    owner_id = db.Column(db.Integer)      # account_id the flag actually belongs to
    value = db.Column(db.Text)
    count = db.Column(db.Integer, default=1)
    created = db.Column(db.DateTime, default=datetime.datetime.utcnow)
    updated = db.Column(db.DateTime, default=datetime.datetime.utcnow)


def _secret():
    s = current_app.config.get("SECRET_KEY") or os.environ.get("SECRET_KEY") or ""
    if isinstance(s, str):
        s = s.encode()
    return s


def user_flag(challenge, account_id):
    """Stateless per-user flag: HMAC(secret, challenge_id:account_id).
    Unique per user so flag-sharing does not work."""
    msg = "{}:{}".format(challenge.id, account_id).encode()
    digest = hmac.new(_secret(), msg, hashlib.sha256).hexdigest()[:24]
    prefix = (challenge.flag_prefix or "flag")
    return "{}{{{}}}".format(prefix, digest)


def _instancer_base():
    return os.environ.get("INSTANCER_URL", "http://instancer:8080").rstrip("/")


def _headers():
    return {"X-Auth-Token": os.environ.get("INSTANCER_TOKEN", "")}


def _stop_user_instance(chal_id, account_id):
    """Destroy the given account's instance(s) for a challenge: the container,
    its network and its route, whatever state the container is in. Raises if
    the instancer cannot be reached or refuses, so callers can report it."""
    r = requests.post(
        _instancer_base() + "/instances/by",
        json={"user_id": str(account_id), "chal_id": str(chal_id)},
        headers=_headers(),
        timeout=30,
    )
    r.raise_for_status()


def _record_flag_share(challenge_id, submitter_id, owner_id, value):
    """Upsert a flag-sharing incident (dedup per challenge+submitter+owner)."""
    try:
        now = datetime.datetime.utcnow()
        rep = FlagShareReport.query.filter_by(
            challenge_id=challenge_id,
            submitter_id=submitter_id,
            owner_id=owner_id,
        ).first()
        if rep:
            rep.count = (rep.count or 1) + 1
            rep.updated = now
            rep.value = value
        else:
            rep = FlagShareReport(
                challenge_id=challenge_id,
                submitter_id=submitter_id,
                owner_id=owner_id,
                value=value,
                count=1,
                created=now,
                updated=now,
            )
            db.session.add(rep)
        db.session.commit()
    except Exception:
        try:
            db.session.rollback()
        except Exception:
            pass


class InstancerChallenge(BaseChallenge):
    id = "instancer"
    name = "instancer"
    templates = {
        "create": "/plugins/instancer/assets/create.html",
        "update": "/plugins/instancer/assets/update.html",
        "view": "/plugins/instancer/assets/view.html",
    }
    scripts = {
        "create": "/plugins/instancer/assets/create.js",
        "update": "/plugins/instancer/assets/update.js",
        "view": "/plugins/instancer/assets/view.js",
    }
    route = "/plugins/instancer/assets/"
    blueprint = Blueprint(
        "instancer", __name__, template_folder="templates", static_folder="assets"
    )
    challenge_model = InstancerChallengeModel

    @classmethod
    def create(cls, request):
        data = dict(request.form or request.get_json() or {})
        for f in INT_FIELDS:
            if data.get(f) not in (None, ""):
                data[f] = int(data[f])
        challenge = cls.challenge_model(**data)
        db.session.add(challenge)
        db.session.commit()
        return challenge

    @classmethod
    def read(cls, challenge):
        challenge = InstancerChallengeModel.query.filter_by(id=challenge.id).first()
        data = super().read(challenge)
        data.update(
            {
                "docker_image": challenge.docker_image,
                "kind": challenge.kind,
                "port": challenge.port,
                "ttl_minutes": challenge.ttl_minutes,
                "per_user_limit": challenge.per_user_limit,
                "mem_mb": challenge.mem_mb,
                "cpus": challenge.cpus,
                "flag_prefix": challenge.flag_prefix,
            }
        )
        return data

    @classmethod
    def update(cls, challenge, request):
        data = dict(request.form or request.get_json() or {})
        for attr, value in data.items():
            if attr in INT_FIELDS and value not in (None, ""):
                value = int(value)
            setattr(challenge, attr, value)
        db.session.commit()
        return challenge

    @classmethod
    def attempt(cls, challenge, request):
        data = request.form or request.get_json()
        submission = (data.get("submission") or "").strip()
        user = get_current_user()
        account_id = user.account_id if user else 0
        expected = user_flag(challenge, account_id)

        # Correct: accept, then auto-stop this account's instance early so it
        # does not keep running until TTL expiry.
        if submission and hmac.compare_digest(submission, expected):
            try:
                _stop_user_instance(challenge.id, account_id)
            except Exception as e:
                # The solve still counts; the reaper removes the instance at
                # its TTL if this call failed.
                current_app.logger.warning(
                    "instancer: stop on solve failed for chal %s account %s: %s",
                    challenge.id, account_id, e,
                )
            return True, "Correct"

        # Incorrect against own flag: check whether it is *another* account's
        # valid dynamic flag for this challenge (flag sharing). If so, record
        # an admin report but still tell the submitter it is incorrect.
        if submission:
            try:
                Model = get_model()
                for acct in Model.query.with_entities(Model.id).all():
                    aid = acct.id
                    if aid == account_id:
                        continue
                    if hmac.compare_digest(submission, user_flag(challenge, aid)):
                        _record_flag_share(
                            challenge.id, account_id, aid, submission
                        )
                        try:
                            ctfd_log(
                                "submissions",
                                "[FLAG SHARING] account {submitter} submitted "
                                "account {owner}'s flag for challenge {chal}",
                                submitter=account_id,
                                owner=aid,
                                chal=challenge.id,
                            )
                        except Exception:
                            pass
                        break
            except Exception:
                pass

        return False, "Incorrect"


# ----------------- Instance control API -----------------

instancer_api = Blueprint("instancer_api", __name__)


def _load_instancer_chal(challenge_id):
    return InstancerChallengeModel.query.filter_by(id=challenge_id).first()


@instancer_api.route("/plugins/instancer/instance", methods=["POST"])
@authed_only
def start_instance():
    body = request.get_json(silent=True) or request.form
    challenge_id = body.get("challenge_id")
    chal = _load_instancer_chal(challenge_id)
    if not chal:
        return jsonify({"success": False, "error": "not_instancer"}), 400
    user = get_current_user()
    account_id = user.account_id
    flag = user_flag(chal, account_id)
    # Idempotent: if the user already has an instance for this challenge,
    # return it instead of creating a duplicate.
    try:
        rr = requests.get(
            _instancer_base() + "/instances",
            params={"user_id": str(account_id)},
            headers=_headers(),
            timeout=15,
        )
        existing = rr.json() if rr.content else []
        if isinstance(existing, dict):
            existing = existing.get("instances", [])
        for it in existing:
            if str(it.get("chal_id")) == str(chal.id):
                return jsonify({"success": True, "data": it})
    except Exception:
        pass
    payload = {
        "chal_id": str(chal.id),
        "user_id": str(account_id),
        "image": chal.docker_image,
        "port": chal.port,
        "flag": flag,
        "kind": chal.kind,
        "ttl": int(chal.ttl_minutes or 30),
        "per_user_limit": int(chal.per_user_limit or 1),
        "mem_mb": int(chal.mem_mb or 256),
        "cpus": str(chal.cpus or "0.5"),
        "writable": False,
    }
    try:
        r = requests.post(
            _instancer_base() + "/instances", json=payload, headers=_headers(), timeout=60
        )
    except Exception as e:
        return jsonify({"success": False, "error": "instancer_unreachable", "detail": str(e)}), 502
    data = r.json() if r.content else {}
    if r.status_code == 429 or (isinstance(data, dict) and data.get("error") == "per_user_limit"):
        return jsonify({"success": False, "error": "per_user_limit", "limit": data.get("limit")}), 429
    if r.status_code >= 400:
        return jsonify({"success": False, "error": "instancer_error", "detail": data}), 502
    return jsonify({"success": True, "data": data})


@instancer_api.route("/plugins/instancer/instance", methods=["GET"])
@authed_only
def status_instance():
    challenge_id = request.args.get("challenge_id")
    chal = _load_instancer_chal(challenge_id)
    if not chal:
        return jsonify({"success": False, "error": "not_instancer"}), 400
    user = get_current_user()
    account_id = user.account_id
    try:
        r = requests.get(
            _instancer_base() + "/instances",
            params={"user_id": str(account_id)},
            headers=_headers(),
            timeout=30,
        )
        items = r.json() if r.content else []
    except Exception as e:
        return jsonify({"success": False, "error": "instancer_unreachable", "detail": str(e)}), 502
    if isinstance(items, dict):
        items = items.get("instances", [])
    match = None
    for it in items:
        if str(it.get("chal_id")) == str(chal.id):
            match = it
            break
    return jsonify({"success": True, "data": match})


@instancer_api.route("/plugins/instancer/instance", methods=["DELETE"])
@authed_only
def stop_instance():
    challenge_id = request.args.get("challenge_id")
    chal = _load_instancer_chal(challenge_id)
    if not chal:
        return jsonify({"success": False, "error": "not_instancer"}), 400
    user = get_current_user()
    account_id = user.account_id
    try:
        _stop_user_instance(chal.id, account_id)
    except Exception as e:
        return jsonify({"success": False, "error": "instancer_unreachable", "detail": str(e)}), 502
    return jsonify({"success": True})


# ----------------- Admin: flag-sharing reports -----------------

instancer_admin = Blueprint(
    "instancer_admin", __name__, template_folder="templates"
)


@instancer_admin.route("/admin/instancer/reports", methods=["GET"])
@admins_only
def instancer_reports():
    reports = FlagShareReport.query.order_by(FlagShareReport.updated.desc()).all()
    names = {}
    try:
        Model = get_model()
        for acct in Model.query.all():
            names[acct.id] = getattr(acct, "name", None) or str(acct.id)
    except Exception:
        pass
    chal_names = {}
    try:
        for c in Challenges.query.with_entities(Challenges.id, Challenges.name).all():
            chal_names[c.id] = c.name
    except Exception:
        pass
    rows = []
    for r in reports:
        rows.append(
            {
                "challenge": chal_names.get(r.challenge_id, r.challenge_id),
                "challenge_id": r.challenge_id,
                "submitter": names.get(r.submitter_id, r.submitter_id),
                "submitter_id": r.submitter_id,
                "owner": names.get(r.owner_id, r.owner_id),
                "owner_id": r.owner_id,
                "value": r.value,
                "count": r.count,
                "updated": r.updated,
            }
        )
    return render_template("instancer_reports.html", reports=rows)


def load(app):
    app.db.create_all()
    CHALLENGE_CLASSES["instancer"] = InstancerChallenge
    register_plugin_assets_directory(app, base_path="/plugins/instancer/assets/")
    app.register_blueprint(instancer_api)
    app.register_blueprint(instancer_admin)
    try:
        register_admin_plugin_menu_bar(
            title="Flag Reports", route="/admin/instancer/reports"
        )
    except Exception:
        pass
