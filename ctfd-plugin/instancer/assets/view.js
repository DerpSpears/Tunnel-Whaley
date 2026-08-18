// Instancer challenge view for the modern CTFd theme (classroom).
//
// The modern theme renders the challenge body reactively via Alpine
// (x-html="$store.challenge.data.view"). CTFd core calls preRender()/postRender()
// SYNCHRONOUSLY around the store update, i.e. BEFORE Alpine actually swaps the
// modal DOM. On a challenge SWITCH that means a one-shot mount races the stale
// DOM, injects into it, and is then wiped when Alpine applies the new view.
//
// To be correct across every open/switch we install ONE persistent observer
// that re-ensures our panel whenever the shown instancer modal is missing it.

CTFd._internal.challenge.data = undefined;
CTFd._internal.challenge.renderer = null;
CTFd._internal.challenge.preRender = function () {};
CTFd._internal.challenge.render = null;

CTFd._internal.challenge.postRender = function () {
  // Just nudge the persistent observer; it does the real work once Alpine
  // has swapped in the new challenge body.
  scheduleEnsure();
};

CTFd._internal.challenge.submit = function (preview) {
  var challenge_id = parseInt(CTFd.lib.$("#challenge-id").val());
  var submission = CTFd.lib.$("#challenge-input").val();
  var body = { challenge_id: challenge_id, submission: submission };
  var params = {};
  if (preview) params["preview"] = true;
  return CTFd.api.post_challenge_attempt(params, body).then(function (response) {
    return response;
  });
};

function _csrf() {
  return (
    (window.init && window.init.csrfNonce) ||
    (window.CTFd && CTFd.config && CTFd.config.csrfNonce) ||
    ""
  );
}

function _api(method, chalId) {
  var url = "/plugins/instancer/instance";
  var opts = {
    method: method,
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "CSRF-Token": _csrf(),
    },
  };
  if (method === "GET" || method === "DELETE") {
    url += "?challenge_id=" + encodeURIComponent(chalId);
  } else {
    opts.body = JSON.stringify({ challenge_id: chalId });
  }
  return fetch(url, opts).then(function (r) {
    return r
      .json()
      .catch(function () {
        return {};
      })
      .then(function (d) {
        return { status: r.status, data: d };
      });
  });
}

// ---- Persistent mount machinery -------------------------------------------

function _storeData() {
  try {
    return (
      (window.Alpine &&
        Alpine.store("challenge") &&
        Alpine.store("challenge").data) ||
      null
    );
  } catch (e) {
    return null;
  }
}

function _isInstancer() {
  var d = _storeData();
  if (!d) return false;
  if (d.type === "instancer") return true;
  if (d.type_data && d.type_data.id === "instancer") return true;
  return false;
}

function _currentModal() {
  return document.querySelector(".modal.show");
}

function _chalId(modal) {
  var d = _storeData();
  if (d && (d.id || d.id === 0)) return d.id;
  var idEl = modal && modal.querySelector("#challenge-id");
  return idEl ? idEl.value : null;
}

// Ensure the instancer panel exists in the currently shown instancer modal.
// Safe to call repeatedly; it is a no-op when the panel is already present.
function ensurePanel() {
  var modal = _currentModal();
  if (!modal) return;
  if (!_isInstancer()) return;
  var container = modal.querySelector("#challenge") || modal;
  var submitRow = container.querySelector(".submit-row");
  if (!submitRow) return;
  if (container.querySelector("#instancer-panel")) return; // already mounted
  var chalId = _chalId(modal);
  if (!chalId && chalId !== 0) return;
  injectPanel(container, submitRow, chalId);
}

var _raf = 0;
function scheduleEnsure() {
  if (_raf) return;
  var raf =
    window.requestAnimationFrame ||
    function (f) {
      return setTimeout(f, 16);
    };
  _raf = raf(function () {
    _raf = 0;
    ensurePanel();
  });
}

function installObserver() {
  if (window.__instancerObserverInstalled) {
    scheduleEnsure();
    return;
  }
  window.__instancerObserverInstalled = true;
  var obs = new MutationObserver(function () {
    scheduleEnsure();
  });
  obs.observe(document.body, { childList: true, subtree: true });
  document.addEventListener("shown.bs.modal", scheduleEnsure, true);
  scheduleEnsure();
}

installObserver();

// ---- Panel rendering -------------------------------------------------------

function injectPanel(container, submitRow, chalId) {
  var old = container.querySelector("#instancer-panel");
  if (old && old.parentNode) old.parentNode.removeChild(old);
  var host = document.createElement("div");
  host.id = "instancer-panel";
  host.className = "mt-3 mb-3";
  host.setAttribute("data-chal", String(chalId));
  submitRow.parentNode.insertBefore(host, submitRow);
  // Optimistic render: show the Launch button immediately (no network wait),
  // then reconcile with real status in the background.
  renderState(host, chalId, {});
  msg(host, "Checking for an existing instance\u2026");
  _api("GET", chalId)
    .then(function (res) {
      if (!host.isConnected) return; // panel was replaced by a switch
      if (host._launching) return; // don't clobber an in-flight launch
      var inst = res.data && res.data.data;
      if (inst && inst.url) {
        renderState(host, chalId, { instance: inst });
      } else {
        var m = host.querySelector("#instancer-msg");
        if (m && m.textContent.indexOf("Checking") === 0) m.textContent = "";
      }
    })
    .catch(function () {
      var m = host.querySelector("#instancer-msg");
      if (m && m.textContent.indexOf("Checking") === 0) m.textContent = "";
    });
}

var _timers = {};

function renderState(host, chalId, state) {
  state = state || {};
  if (_timers[chalId]) {
    clearInterval(_timers[chalId]);
    delete _timers[chalId];
  }
  var inst = state.instance;
  var html = '<div class="card border-info"><div class="card-body">';
  html += '<h5 class="card-title mb-2"><i class="fas fa-server"></i> Challenge Instance</h5>';
  if (inst && inst.url) {
    var label = inst.kind === "tcp" ? "Open terminal" : "Open in browser";
    html += '<p class="mb-2">Your private instance is running.</p>';
    html +=
      '<a class="btn btn-success me-2 mb-2" target="_blank" rel="noopener" href="' +
      inst.url +
      '">' +
      label +
      " <i class='fas fa-external-link-alt'></i></a>";
    html +=
      '<button class="btn btn-danger mb-2" id="instancer-stop">Stop instance</button>';
    html +=
      '<div class="small text-muted mt-1"><code>' +
      location.origin +
      inst.url +
      "</code></div>";
    if (inst.expires) {
      html += '<div class="small mt-1" id="instancer-countdown"></div>';
    }
  } else {
    html += '<p class="text-muted mb-2">No instance running yet. Launch one to get your unique flag.</p>';
    html +=
      '<button class="btn btn-primary" id="instancer-start">Launch Instance</button>';
  }
  html += '<div id="instancer-msg" class="small mt-2"></div>';
  html += "</div></div>";
  host.innerHTML = html;

  var startBtn = host.querySelector("#instancer-start");
  if (startBtn) {
    startBtn.addEventListener("click", function () {
      startBtn.disabled = true;
      host._launching = true;
      msg(host, "Launching your instance\u2026 this can take a few seconds.");
      _api("POST", chalId)
        .then(function (res) {
          host._launching = false;
          if (res.status === 429) {
            msg(host, "Instance limit reached for your account (" + (res.data.limit || "") + " max). Stop another instance first.");
            startBtn.disabled = false;
            return;
          }
          if (!res.data || !res.data.success) {
            msg(host, "Failed to launch: " + JSON.stringify((res.data && res.data.error) || res.data));
            startBtn.disabled = false;
            return;
          }
          renderState(host, chalId, { instance: res.data.data });
        })
        .catch(function (e) {
          host._launching = false;
          msg(host, "Error: " + e);
          startBtn.disabled = false;
        });
    });
  }

  var stopBtn = host.querySelector("#instancer-stop");
  if (stopBtn) {
    stopBtn.addEventListener("click", function () {
      stopBtn.disabled = true;
      msg(host, "Stopping\u2026");
      _api("DELETE", chalId)
        .then(function () {
          renderState(host, chalId, {});
        })
        .catch(function (e) {
          msg(host, "Error: " + e);
          stopBtn.disabled = false;
        });
    });
  }

  if (inst && inst.expires) {
    var el = host.querySelector("#instancer-countdown");
    var tick = function () {
      if (!host.isConnected) {
        clearInterval(_timers[chalId]);
        delete _timers[chalId];
        return;
      }
      var secs = Math.floor(inst.expires - Date.now() / 1000);
      if (secs <= 0) {
        el.textContent = "Instance expired \u2014 relaunch to continue.";
        clearInterval(_timers[chalId]);
        return;
      }
      var m = Math.floor(secs / 60), s = secs % 60;
      el.textContent = "Expires in " + m + "m " + (s < 10 ? "0" : "") + s + "s";
    };
    tick();
    _timers[chalId] = setInterval(tick, 1000);
  }
}

function msg(host, text) {
  var m = host.querySelector("#instancer-msg");
  if (m) m.textContent = text;
}
