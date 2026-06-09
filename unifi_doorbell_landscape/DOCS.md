# UniFi Doorbell Landscape

Forces a UniFi Protect doorbell to output **landscape** video (matching your
other cameras) instead of the hardcoded 90° portrait ("hallway") rotation that
Protect cannot disable for doorbells.

The fix is applied **at the source (on the camera)**, so Protect, recordings,
and every downstream consumer (go2rtc, Frigate, Loxone, …) all get the
corrected orientation — no per-consumer rotation needed.


## How it works

Two pieces, both installed on the camera over SSH and kept applied by a
watchdog loop in this app:

1. **`rot90.so`** — an `LD_PRELOAD` shim that interposes the encoder's C++
   getter `ubnt::encoder::VideoEncoderSettings::hallwayMode()` and forces a
   rotation value (0 = disabled) → the encoder emits a **landscape** sensor
   frame instead of portrait. Injected by bind-mounting `streamer_wrap.sh`
   over `/bin/ubnt_streamer`.
2. **ISP `flip` + `mirror`** in `/etc/persistent/ubnt_isp.conf` — a 180°
   turn that lands the frame upright.

The **Rotation** option drives both: `90` and `-90` select the two landscape
directions (180° apart); the watchdog applies the matching hallway value and
ISP flip for you.

Neither piece survives a camera reboot (`cfgmtd` wipes `/etc/persistent` on
boot and the bind-mount is volatile), which is why this runs as a watchdog:
every `check_interval` seconds it SSHes to the camera, checks both pieces, and
re-applies them on drift.

## Setup — wizard (recommended) or manual

### Wizard

The app can do the whole setup itself. You provide one thing it cannot
automate: SSH access to your UniFi console (UniFi OS → Console Settings →
Advanced → enable SSH, set/note the root password).

1. Leave `camera_password` (and optionally `camera_ip`) empty.
2. Fill `console_host` and `console_ssh_password` (user is `root`).
3. Start the app. On first start it: enables camera SSH via Protect's
   config override (restarts `unifi-protect` — brief recording gap, only
   when the setting actually changed), pulls your newest Protect backup,
   extracts the camera's Recovery Code from it, persists the discovered
   values into this app's options, and **wipes the console password from
   the configuration** (use-once policy).

Wizard limitations: automatic Protect backups must be enabled (default on);
the newest backup can be up to ~24 h old, so a camera adopted today may not
be in it yet. With multiple doorbells, set `camera_ip` so the wizard knows
which one you mean. If the wizard can't help, it logs exactly why and what
to do.

### Manual (no console credentials)

1. **Enable camera SSH on your UniFi console.** On the UDM, set
   `{"enableSsh": true}` in the file Protect's `overrides` points to —
   `/etc/unifi-protect/config.json` on current builds (verify with
   `jq .overrides /usr/share/unifi-protect/app/config/default.json`) — then
   `systemctl restart unifi-protect`.
2. **Camera Recovery Code** — the camera then accepts SSH as user `ubnt` with
   the camera's Recovery Code as the password (Protect → camera → Settings →
   Recovery Code). Fill it into `camera_password` together with `camera_ip`.

Either way, your Home Assistant box must reach the camera's IP over SSH
(port 22). Keep this on the same LAN as the camera — heavy SSH over a VPN
can trip the UniFi IPS.

## Configuration

| Option                 | Description                                                                     |
|------------------------|---------------------------------------------------------------------------------|
| `model`                | `auto` (probe + match) or a folder name under `rotation/models/` to force.      |
| `camera_ip`            | LAN IP of the doorbell. Empty → wizard auto-picks if you have exactly one.      |
| `camera_password`      | The camera's **Recovery Code**. Empty → wizard fetches it (console fields set). |
| `console_host`         | UniFi console IP — wizard only.                                                  |
| `console_ssh_user`     | Console SSH user, normally `root` — wizard only.                                |
| `console_ssh_password` | Console SSH password — used once by the wizard, then auto-wiped.                |
| `rotation`             | Orientation: `none` \| `90` \| `-90`. `90`/`-90` are the two landscape directions (180° apart) — pick whichever is upright. |
| `check_interval`       | Seconds between drift checks/re-applies. Default `30`.                          |

### Which rotation do I pick?

Try `90`. If the scene is upside-down or sideways, switch to `-90`. The two
differ by 180°, which covers the common doorbell mounts. `none` leaves the
camera's native landscape frame without the upright correction. If neither
`90` nor `-90` is right, your camera reports orientation differently — open an
issue with a sample frame.
