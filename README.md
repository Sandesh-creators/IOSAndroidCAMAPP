# ios12-security-cam

Turn old spare phones into network security cameras and watch every feed from a
single self-hosted dashboard.

Three components, no third-party camera/streaming libraries anywhere:

| Component | Tech | Role |
|-----------|------|------|
| `ios/`    | Swift 5 / UIKit (iOS 12.0+, Xcode 10–16) | Streams the iPhone camera as MJPEG over HTTP on port 8080 |
| `android/`| Kotlin (Android 5.0 / API 21+) | Same idea for old Android spares — identical `/stream`, `/snapshot`, `/` endpoints |
| `server/` | Python 3.9+ / Flask + requests | Pulls each phone's MJPEG stream and shows live feeds in a web UI |

## Architecture

```
+----------------------+        LAN (HTTP :8080)        +--------------------------+
| Old iPhone (iOS 12)  |   GET /stream  -> MJPEG        |  Python dashboard server |
| SecurityCam.app      | <------------------------------|  server/server.py        |
|  AVCaptureSession --JPEG--> tiny BSD-socket HTTP srv   |   worker thread per cam  |
+----------------------+                                |   parses FF D8..FF D9    |
                                                        |                          |
+----------------------+        LAN (HTTP :8080)         |  web UI on :5000         |
| Old Android phone    |   GET /stream  -> MJPEG        |  /feed/<cam>  /stream/…  |
| SecurityCam.apk      | <------------------------------|  optional Basic auth     |
|  Camera1 API --NV21-> JPEG --> ServerSocket HTTP srv   +-----------+--------------+
+----------------------+                                              |
                                                     browser (dark grid UI)
                                                          http://host:5000
```

Both phone apps expose the exact same wire protocol, so the dashboard does not
care whether a camera is an iPhone or an Android device.

## iOS app

Requirements: Xcode 10.x–16.x (deployment target 12.0; Swift 5). The `.xcodeproj`
is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not
committed:

```sh
brew install xcodegen
cd ios && xcodegen generate && open SecurityCam.xcodeproj
```

Run on the iPhone, grant camera permission; the green bar at the bottom shows
`http://<iphone-ip>:8080/stream`. The screen is kept awake automatically
(`isIdleTimerDisabled`). Key files:

* `CameraStreamer.swift` – AVCaptureSession (.medium, back wide camera),
  BGRA frames throttled to 10 FPS, encoded to JPEG (quality 0.5) via CIContext.
* `HTTPStreamServer.swift` – raw BSD socket server: `SO_REUSEADDR`,
  `SO_NOSIGPIPE` on every accepted fd, routes `/stream` (multipart MJPEG,
  boundary `frame`), `/snapshot`, `/`.
* `project.yml` – XcodeGen spec, bundle id `com.example.securitycam`.

CI builds an unsigned IPA (`SecurityCam-unsigned.ipa`) you can sideload with
AltStore / Sideloadly / Apple Configurator after re-signing.

### Signed builds (optional, documented only)

Add these repo secrets and adapt the workflow's `CODE_SIGNING_ALLOWED=NO` step:
`APPLE_CERT_P12`, `APPLE_CERT_PASSWORD`, `APPLE_PROVISION_PROFILE`,
`KEYCHAIN_PASSWORD`. Import the .p12 into a temporary keychain in CI, pass
`CODE_SIGN_IDENTITY="iPhone Developer" PROVISIONING_PROFILE_SPECIFIER=<name>`
and `-allowProvisioningUpdates`, then install the signed .app via Apple
Configurator or AltStore. Not enabled by default — never commit certificates.

## Android app

Open `android/` in Android Studio (Hedgehog+) or build headless:

```sh
cd android && ./gradlew :app:assembleDebug   # Gradle Wrapper — only JDK 17 needed
# APK lands in app/build/outputs/apk/debug/app-debug.apk
adb install app/build/outputs/apk/debug/app-debug.apk   # or copy to the phone, allow "unknown sources"
```

minSdk 21 (Android 5.0). Uses the legacy Camera1 API + `YuvImage` NV21→JPEG so
it runs on ancient hardware with zero third-party dependencies (only AndroidX
appcompat/core for the activity base class). Same endpoints as iOS:
`http://<android-ip>:8080/stream`. Cleartext HTTP is explicitly allowed via
`network_security_config.xml` because the stream is plain HTTP on the LAN.

## Dashboard server

```sh
cd server
python3 -m venv ../.venv && ../.venv/bin/pip install -r requirements.txt
../.venv/bin/python server.py \
    --cam kitchen=http://192.168.1.50:8080/stream \
    --cam garage=http://192.168.1.77:8080/stream
```

Open `http://<host>:5000`. Cameras can also be added/removed at runtime from
the UI (or `POST`/`DELETE /api/cameras`). Set `DASHBOARD_PASSWORD` to require
HTTP Basic auth (user `admin`).

Routes: `/` UI · `/api/cameras` (GET/POST) · `/api/cameras/<name>` (DELETE) ·
`/feed/<name>` latest JPEG · `/snapshot/<name>` download · `/stream/<name>`
re-streamed MJPEG.

## Exposing it beyond the LAN (safely)

* **Preferred:** WireGuard/Tailscale — put the dashboard behind a VPN and only
  trusted devices can reach port 5000.
* **ngrok:** `ngrok http 5000` — set `DASHBOARD_PASSWORD` first; ngrok URLs are
  public.
* **Cloudflare Tunnel:** `cloudflared tunnel --url http://localhost:5000` —
  add Cloudflare Access in front for real protection.
* **Router port-forward:** NAT 5000/tcp → the server. Strongly discouraged
  without auth + TLS in front (reverse proxy such as Caddy).

> ⚠️ SECURITY WARNING: the phone streams are unauthenticated plain HTTP and
> the dashboard has no encryption of its own. Keep everything on the LAN or
> behind a VPN/tunnel with authentication. Never expose port 8080 or 5000
> directly to the internet.

## GitHub Actions

Both phone apps build entirely inside GitHub Actions — no local toolchain needed.
Every run produces an installable artifact under the workflow's **Artifacts** section.

* `.github/workflows/ios-build.yml` — macos-14 runner, Xcode 15.4 + XcodeGen →
  simulator compile check + **unsigned `SecurityCam-unsigned.ipa`** artifact;
  uploads xcodebuild logs on failure. Triggered on push/PR to `main` and can be
  started manually (**Actions ▸ iOS Build ▸ Run workflow**).
* `.github/workflows/android-build.yml` — ubuntu-latest runner, JDK 17 + the
  committed Gradle Wrapper (`./gradlew`, Gradle 8.7) → **debug-signed
  `app-debug.apk`** artifact (installable directly via `adb install` or by
  copying to the phone). Manual trigger: **Actions ▸ Android Build ▸ Run workflow**.
* `.github/workflows/python-lint.yml` — py_compile + flake8 (max line 120).

## Troubleshooting

* **Camera permission denied** — re-enable in Settings ▸ Privacy ▸ Camera
  (iOS) or Settings ▸ Apps ▸ SecurityCam ▸ Permissions (Android); relaunch.
* **Port 8080 in use** — another app holds it; kill it or change the port
  constant in `ViewController.swift` / `MainActivity.kt` and rebuild.
* **Phone sleeps / stream stops** — the apps keep the screen awake while in the
  foreground, but iOS suspends backgrounded apps entirely. Keep the app open,
  disable Auto-Lock (Settings ▸ Display), enable "Guided Access" to lock the
  screen to the app, and keep the phone charging. On Android, avoid Doze by
  staying plugged in or excluding the app from battery optimization.
* **IP changed after DHCP renewal** — reserve a static lease for the phone in
  your router, or update the `--cam` URL in the dashboard UI.
* **Dashboard shows OFFLINE** — check both devices are on the same SSN/VLAN,
  that client isolation is off on the router, and `curl http://<phone-ip>:8080/`.
