# UniFi Doorbell Landscape — Home Assistant app (add-on)

[![Add repository to my Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FVVlasy%2Funifi-doorbell-landscape)

Forces a **UniFi Protect doorbell** to output **landscape** video instead of
the hardcoded 90° portrait ("hallway") rotation that Protect cannot disable
for doorbells (`featureFlags.hasHallwayMode=false`; the camera ignores the
controller's `hallwayMode`).

The fix is applied **on the camera** (an `LD_PRELOAD` shim forcing
`hallwayMode=0` + an ISP 180° flip), so Protect, recordings and every
downstream consumer get the corrected orientation. Nothing on the camera
survives a reboot, so a small watchdog SSHes in every 30 s and re-applies it
on drift. This app packages that watchdog.

Split out of
[unifi-protect-loxone-intercom](https://github.com/VVlasy/unifi-protect-loxone-intercom),
where it started as an opt-in hack.

## Install (Home Assistant)

1. Settings → Apps → App Store → ⋮ → **Repositories** → add
   `https://github.com/VVlasy/unifi-doorbell-landscape` (or click the badge
   above).
2. Install **UniFi Doorbell Landscape**.
3. Enable camera SSH on your UniFi console and get the camera's Recovery Code
   — see the app's Documentation tab.
4. Fill in `camera_ip` and `camera_password`, start the app, watch the log.

## Standalone (no Home Assistant)

```bash
cp .env.example .env   # set CAMERA_IP and CAMERA_SSH_PASS
docker compose up -d --build
docker compose logs -f
```

## Setup wizard

The two manual prerequisites (enabling camera SSH, finding the Recovery Code)
can be automated: give the app your UniFi console's SSH credentials and on
first start it enables camera SSH via the Protect config override and
extracts the Recovery Code from your newest Protect backup. The console
password is used once and then wiped from the app's configuration. Details in
[DOCS.md](unifi_doorbell_landscape/DOCS.md).

## Supported hardware

| Model id                | Hardware                                                    | Status |
|-------------------------|-------------------------------------------------------------|--------|
| `uvc_g6o_doorbell_lite` | UniFi Doorbell Lite (G6O, Sigmastar Infinity6E, glibc 2.30) | tested |

The shim is firmware-specific; each supported model is a folder under
[`unifi_doorbell_landscape/rotation/models/`](unifi_doorbell_landscape/rotation/models)
with its own `rot90.so` build. `model: auto` probes the camera over SSH and
picks the matching build; unsupported cameras get a ready-to-paste diagnostic
dump in the log. To get a new model added (or add it yourself), see
[ADDING_A_MODEL.md](ADDING_A_MODEL.md). The camera's own `libc.so.6` (needed
for a build) is **not redistributable** and is not in this repo; pull it from
your own device.

## Caveats

This overrides **undocumented firmware internals** of a specific camera model.
It will break on firmware updates until `rot90.so` is rebuilt. The watchdog
restarts the camera's streamer with SIGTERM only — SIGKILL makes the camera
reboot itself. Treat it as a hack, not a supported feature. Full details and
hard-won gotchas are in the [app documentation](unifi_doorbell_landscape/DOCS.md)
and the comment headers of the scripts.
