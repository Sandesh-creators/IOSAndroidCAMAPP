// SecurityCam dashboard front-end.
// - Polls /api/cameras every 5 s to keep the card list in sync.
// - Each card's <img> reloads /feed/<name> every ~1 s (cache-busted query).
// - Add/remove cameras through POST/DELETE on /api/cameras.

(function () {
  "use strict";

  var LIST_REFRESH_MS = 5000;   // camera list refresh interval
  var FRAME_REFRESH_MS = 1000;  // per-card image refresh interval

  var grid = document.getElementById("grid");
  var addForm = document.getElementById("add-form");
  var addMsg = document.getElementById("add-msg");
  var clock = document.getElementById("clock");

  // name -> { el, img, metaEl, timer } bookkeeping for existing cards.
  var cards = {};

  function fmtLastSeen(epoch) {
    if (!epoch) return "never";
    var ageSec = Math.max(0, Math.floor(Date.now() / 1000 - epoch));
    if (ageSec < 2) return "just now";
    if (ageSec < 60) return ageSec + "s ago";
    if (ageSec < 3600) return Math.floor(ageSec / 60) + "m ago";
    return Math.floor(ageSec / 3600) + "h ago";
  }

  function buildCard(cam) {
    var card = document.createElement("div");
    card.className = "card";

    var head = document.createElement("div");
    head.className = "card-head";

    var name = document.createElement("span");
    name.className = "name";
    name.textContent = cam.name;
    name.title = cam.url;

    var badge = document.createElement("span");
    badge.className = "badge";

    head.appendChild(name);
    head.appendChild(badge);

    var img = document.createElement("img");
    img.className = "frame";
    img.alt = "Live feed from " + cam.name;

    var meta = document.createElement("div");
    meta.className = "card-meta";

    var seen = document.createElement("span");
    seen.className = "seen";

    var actions = document.createElement("span");
    actions.className = "actions";

    var snapBtn = document.createElement("a");
    snapBtn.textContent = "Snapshot";
    snapBtn.href = "/snapshot/" + encodeURIComponent(cam.name);

    var streamLink = document.createElement("a");
    streamLink.textContent = "MJPEG";
    streamLink.href = "/stream/" + encodeURIComponent(cam.name);
    streamLink.target = "_blank";
    streamLink.rel = "noopener";

    var removeBtn = document.createElement("button");
    removeBtn.textContent = "Remove";
    removeBtn.className = "remove";
    removeBtn.addEventListener("click", function () {
      removeCamera(cam.name);
    });

    actions.appendChild(snapBtn);
    actions.appendChild(streamLink);
    actions.appendChild(removeBtn);

    meta.appendChild(seen);
    meta.appendChild(actions);

    card.appendChild(head);
    card.appendChild(img);
    card.appendChild(meta);

    // Refresh this card's frame about once per second.
    var timer = setInterval(function () {
      img.src = "/feed/" + encodeURIComponent(cam.name) + "?t=" + Date.now();
    }, FRAME_REFRESH_MS);
    img.src = "/feed/" + encodeURIComponent(cam.name) + "?t=" + Date.now();

    return { el: card, badge: badge, seen: seen, img: img, timer: timer };
  }

  function updateCard(entry, cam) {
    entry.badge.textContent = cam.online ? "ONLINE" : "OFFLINE";
    entry.badge.className = "badge " + (cam.online ? "online" : "offline");
    entry.seen.textContent = "last frame: " + fmtLastSeen(cam.last_seen);
    entry.el.querySelector(".name").title = cam.url;
  }

  function syncCards(cameraList) {
    var names = {};
    cameraList.forEach(function (cam) {
      names[cam.name] = cam;
      var entry = cards[cam.name];
      if (!entry) {
        entry = buildCard(cam);
        cards[cam.name] = entry;
        grid.appendChild(entry.el);
      }
      updateCard(entry, cam);
    });

    // Drop cards whose camera disappeared server-side.
    Object.keys(cards).forEach(function (name) {
      if (!names[name]) {
        clearInterval(cards[name].timer);
        cards[name].el.remove();
        delete cards[name];
      }
    });

    // Empty-state message.
    var empty = grid.querySelector(".empty");
    if (cameraList.length === 0) {
      if (!empty) {
        empty = document.createElement("div");
        empty.className = "empty";
        empty.textContent = "No cameras yet — add one above (point it at an iOS or Android MJPEG /stream URL).";
        grid.appendChild(empty);
      }
    } else if (empty) {
      empty.remove();
    }
  }

  function fetchCameras() {
    fetch("/api/cameras")
      .then(function (r) { return r.json(); })
      .then(syncCards)
      .catch(function () { /* server restarting; try again next tick */ });
  }

  function removeCamera(name) {
    if (!window.confirm("Remove camera '" + name + "'?")) return;
    fetch("/api/cameras/" + encodeURIComponent(name), { method: "DELETE" })
      .then(fetchCameras);
  }

  addForm.addEventListener("submit", function (ev) {
    ev.preventDefault();
    var name = document.getElementById("cam-name").value.trim();
    var url = document.getElementById("cam-url").value.trim();
    addMsg.className = "msg";
    addMsg.textContent = "";

    fetch("/api/cameras", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: name, url: url })
    })
      .then(function (r) {
        return r.json().then(function (j) { return { status: r.status, body: j }; });
      })
      .then(function (res) {
        if (res.status === 201) {
          addMsg.className = "msg ok";
          addMsg.textContent = "Camera '" + name + "' added.";
          addForm.reset();
          fetchCameras();
        } else {
          addMsg.className = "msg error";
          addMsg.textContent = res.body.error || "Failed to add camera.";
        }
      })
      .catch(function () {
        addMsg.className = "msg error";
        addMsg.textContent = "Network error talking to the dashboard server.";
      });
  });

  function tickClock() {
    clock.textContent = new Date().toLocaleTimeString();
  }

  setInterval(tickClock, 1000);
  tickClock();
  fetchCameras();
  setInterval(fetchCameras, LIST_REFRESH_MS);
})();
