#!/usr/bin/env python3
"""ios12-security-cam dashboard server.

Pulls MJPEG streams from one or more SecurityCam iOS devices and re-serves
them through a small Flask web UI on the local network.

Usage:
    python server.py --cam front=http://192.168.1.50:8080/stream \
                     --cam back=http://192.168.1.51:8080/stream \
                     --host 0.0.0.0 --port 5000

Optional: set DASHBOARD_PASSWORD to require HTTP Basic auth (user "admin").
Dependencies: flask, requests only (see requirements.txt).
"""

import argparse
import hmac
import os
import threading
import time
from datetime import datetime, timezone

import requests
from flask import (Flask, Response, abort, jsonify, render_template,
                   request as flask_request)

# ---------------------------------------------------------------------------
# JPEG marker constants. An MJPEG stream is just concatenated JPEG images;
# FF D8 marks the Start Of Image and FF D9 the End Of Image, so we can find
# frame boundaries by scanning for these two-byte markers even if the server
# in front of us mangles the multipart boundary headers.
# ---------------------------------------------------------------------------
SOI = b"\xff\xd8"
EOI = b"\xff\xd9"

RECONNECT_DELAY_SECONDS = 3.0
CONNECT_TIMEOUT = 5.0
READ_TIMEOUT = 10.0


class CameraWorker(threading.Thread):
    """Background thread that keeps `self.latest_frame` fresh from an MJPEG URL."""

    def __init__(self, name, url):
        super().__init__(daemon=True, name=f"cam-{name}")
        self.name = name
        self.url = url
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._frame = None            # latest complete JPEG bytes
        self._last_seen = None        # epoch seconds of last good frame
        self._online = False

    # -- state accessors (thread-safe) --------------------------------------

    def get_frame(self):
        with self._lock:
            return self._frame

    def status(self):
        with self._lock:
            return {
                "name": self.name,
                "url": self.url,
                "online": self._online,
                "last_seen": self._last_seen,
            }

    def stop(self):
        self._stop_event.set()

    # -- main loop -----------------------------------------------------------

    def run(self):
        while not self._stop_event.is_set():
            try:
                self._consume_stream()
            except Exception as exc:  # network error, bad stream, etc.
                with self._lock:
                    self._online = False
                print(f"[{self.name}] error: {exc}; retrying in "
                      f"{RECONNECT_DELAY_SECONDS}s")
                self._stop_event.wait(RECONNECT_DELAY_SECONDS)

    def _consume_stream(self):
        """Open the MJPEG URL and extract JPEG frames until it closes/fails."""
        with requests.get(self.url, stream=True,
                          timeout=(CONNECT_TIMEOUT, READ_TIMEOUT)) as resp:
            resp.raise_for_status()
            buf = bytearray()
            for chunk in resp.iter_content(chunk_size=4096):
                if self._stop_event.is_set():
                    return
                if not chunk:
                    continue
                buf.extend(chunk)

                # Extract every *complete* JPEG currently in the buffer.
                while True:
                    soi = buf.find(SOI)
                    if soi == -1:
                        # No start marker; keep a small tail in case SOI is
                        # split across two chunks.
                        del buf[:-2]
                        break
                    eoi = buf.find(EOI, soi + 2)
                    if eoi == -1:
                        # Frame still arriving — drop junk before SOI, wait.
                        if soi > 0:
                            del buf[:soi]
                        break
                    frame = bytes(buf[soi:eoi + 2])
                    del buf[:eoi + 2]
                    with self._lock:
                        self._frame = frame
                        self._last_seen = time.time()
                        self._online = True

        # Stream ended cleanly (server closed it); mark offline and let run()
        # reconnect after the delay.
        raise ConnectionError("MJPEG stream closed by remote")


# ---------------------------------------------------------------------------
# Camera registry
# ---------------------------------------------------------------------------

_cameras_lock = threading.RLock()
_cameras = {}   # name -> CameraWorker


def add_camera(name, url):
    """Register and start a worker for `name`. Returns False if it exists."""
    with _cameras_lock:
        if name in _cameras:
            return False
        worker = CameraWorker(name, url)
        _cameras[name] = worker
    worker.start()
    return True


def remove_camera(name):
    """Stop and unregister the worker named `name`. Returns True if removed."""
    with _cameras_lock:
        worker = _cameras.pop(name, None)
    if worker is None:
        return False
    worker.stop()
    return True


def list_cameras():
    with _cameras_lock:
        workers = list(_cameras.values())
    return [w.status() for w in workers]


def get_worker(name):
    with _cameras_lock:
        return _cameras.get(name)


# ---------------------------------------------------------------------------
# Flask application
# ---------------------------------------------------------------------------

app = Flask(__name__)

DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "")


@app.before_request
def require_basic_auth():
    """If DASHBOARD_PASSWORD is set, gate every route behind Basic auth.

    Uses hmac.compare_digest so password checks do not leak timing info.
    """
    if not DASHBOARD_PASSWORD:
        return None
    expected = ("admin", DASHBOARD_PASSWORD)
    auth = flask_request.authorization
    if auth is None or auth.username != expected[0] or \
            not hmac.compare_digest(str(auth.password or ""), expected[1]):
        return Response("Unauthorized", 401,
                        {"WWW-Authenticate": 'Basic realm="SecurityCam"'})
    return None


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/cameras", methods=["GET"])
def api_cameras_list():
    return jsonify(list_cameras())


@app.route("/api/cameras", methods=["POST"])
def api_cameras_add():
    data = flask_request.get_json(silent=True) or {}
    name = str(data.get("name", "")).strip()
    url = str(data.get("url", "")).strip()
    if not name or not url:
        return jsonify({"error": "both 'name' and 'url' are required"}), 400
    if not (url.startswith("http://") or url.startswith("https://")):
        return jsonify({"error": "url must start with http:// or https://"}), 400
    if not add_camera(name, url):
        return jsonify({"error": f"camera '{name}' already exists"}), 409
    return jsonify({"ok": True}), 201


@app.route("/api/cameras/<name>", methods=["DELETE"])
def api_cameras_remove(name):
    if not remove_camera(name):
        return jsonify({"error": f"no such camera '{name}'"}), 404
    return jsonify({"ok": True})


@app.route("/feed/<name>")
def feed(name):
    """Serve the single latest JPEG for an <img> tag (polled by the UI)."""
    worker = get_worker(name)
    if worker is None:
        abort(404)
    frame = worker.get_frame()
    if frame is None:
        # 204 tells the browser to keep showing the previous image.
        return Response(status=204,
                        headers={"Cache-Control": "no-store"})
    return Response(frame, mimetype="image/jpeg",
                    headers={"Cache-Control": "no-store"})


@app.route("/snapshot/<name>")
def snapshot(name):
    """Same JPEG as /feed but sent as a downloadable attachment."""
    worker = get_worker(name)
    if worker is None:
        abort(404)
    frame = worker.get_frame()
    if frame is None:
        abort(503)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    filename = f"{name}-{stamp}.jpg"
    return Response(frame, mimetype="image/jpeg",
                    headers={"Content-Disposition":
                             f'attachment; filename="{filename}"'})


@app.route("/stream/<name>")
def stream(name):
    """Re-stream the latest frames as our own multipart/x-mixed-replace MJPEG.

    Any browser pointed at this URL shows live video, because each part
    replaces the one before it.
    """
    worker = get_worker(name)
    if worker is None:
        abort(404)

    boundary = "frame"

    def generate():
        last_id = None
        while True:
            frame = worker.get_frame()
            if frame is not None and id(frame) != last_id:
                last_id = id(frame)
                yield (f"--{boundary}\r\n"
                       f"Content-Type: image/jpeg\r\n"
                       f"Content-Length: {len(frame)}\r\n\r\n").encode()
                yield frame
                yield b"\r\n"
            time.sleep(0.2)   # ~5 fps cap for the re-broadcast

    headers = {
        "Content-Type": f"multipart/x-mixed-replace; boundary={boundary}",
        "Cache-Control": "no-store",
        "Connection": "close",
    }
    return Response(generate(), headers=headers)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="SecurityCam dashboard server")
    parser.add_argument("--cam", action="append", default=[], metavar="NAME=URL",
                        help="Camera to watch, e.g. --cam front=http://192.168.1.50:8080/stream "
                             "(repeatable)")
    parser.add_argument("--host", default="0.0.0.0",
                        help="Bind address (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=5000,
                        help="Listen port (default 5000)")
    return parser.parse_args()


def parse_cam_specs(specs):
    """Turn ['name=url', ...] into [(name, url), ...]; exit on bad input."""
    parsed = []
    for spec in specs:
        if "=" not in spec:
            raise SystemExit(f"error: --cam expects NAME=URL, got '{spec}'")
        name, url = spec.split("=", 1)
        name, url = name.strip(), url.strip()
        if not name or not url:
            raise SystemExit(f"error: --cam expects NAME=URL, got '{spec}'")
        parsed.append((name, url))
    return parsed


def main():
    args = parse_args()
    for name, url in parse_cam_specs(args.cam):
        add_camera(name, url)
        print(f"watching '{name}' -> {url}")
    if not args.cam:
        print("no --cam given; open the UI and add cameras at runtime")
    # threaded=True lets the polling UI and MJPEG re-stream share the port.
    app.run(host=args.host, port=args.port, threaded=True)


if __name__ == "__main__":
    main()
