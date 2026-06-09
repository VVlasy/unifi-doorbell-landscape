# Adding support for a new doorbell model

The shim (`rot90.so`) is firmware-specific: it is linked against the camera's
own glibc and interposes exact mangled C++ symbols in `/bin/ubnt_streamer`.
That is why support is per-model, packaged as one folder under
`unifi_doorbell_landscape/rotation/models/<model_id>/`:

```
models/<model_id>/
  rot90.so     # the LD_PRELOAD shim built for that firmware
  rot90.c      # its source (usually identical across models; libc differs)
  model.env    # MODEL_NAME, MODEL_MATCH, REQUIRED_SYMBOLS
  camlib/      # the camera's own libc.so.6 (NOT in git - not redistributable)
```

## If you have an unsupported doorbell

1. Install/start the app with your camera's IP + Recovery Code. The watchdog
   probes the camera, finds no matching model, and prints a diagnostic block
   between `BEGIN PROBE` / `END PROBE` markers in the log.
2. Open an issue at
   <https://github.com/VVlasy/unifi-doorbell-landscape/issues> and paste that
   block. It contains the board/firmware identification, whether
   `/bin/ubnt_streamer` exists, and the libc version — everything needed to
   judge feasibility. No secrets are included.

## What a port involves (maintainer checklist)

1. **Check the lever exists.** SSH to the camera and grep the streamer for
   the hallway-mode getters:

   ```sh
   grep -c _ZN4ubnt7encoder20VideoEncoderSettings11hallwayModeEv /bin/ubnt_streamer
   grep -c _ZN4ubnt3ipc8messages13VideoSettings11hallwayModeEv  /bin/ubnt_streamer
   ```

   Both present → the same interposition approach almost certainly works.
   Missing/renamed → dump symbols and find the new names first
   (`strings /bin/ubnt_streamer | grep -i hallway`).

2. **Pull the camera's libc** (`/lib/libc.so.6`, plus `libdl.so.2` if the
   firmware is old enough to have it) into `models/<id>/camlib/`. Check the
   glibc version: run `/lib/libc.so.6`.

3. **Build the shim** against that libc for the camera's architecture
   (check `uname -m`; Doorbell Lite is ARMv7 hard-float):

   ```sh
   arm-linux-gnueabihf-gcc -shared -fPIC -O2 -std=gnu11 -fno-stack-protector \
       -nostdlib -o rot90.so rot90.c camlib/libc.so.6
   ```

   Update the symbol names in `rot90.c` first if step 1 found different ones.

4. **Write `model.env`.** `MODEL_MATCH` is a case-insensitive extended regex
   matched against the probe output (board info + firmware strings + uname);
   make it specific — a false positive ships the wrong binary to someone's
   camera. `REQUIRED_SYMBOLS` are the mangled getters from step 1.

5. **Test manually before letting the watchdog loose.** Apply the hook by
   hand once (see the `apply_script` in `camera-rotation-watchdog.sh`) and
   verify: streamer restarts with SIGTERM, frame goes landscape, camera does
   NOT reboot. Remember the hard rules: **SIGTERM only** (SIGKILL on the
   streamer reboots the camera), and `/etc/persistent` is wiped on boot —
   that's expected, the watchdog re-applies.

6. PR with the new `models/<id>/` folder (without `camlib/` — gitignored),
   the model id added to the `model` dropdown in `config.yaml`
   (`schema: model: list(auto|...)`), and a line in the supported-hardware
   table in `README.md` + `DOCS.md`.

## Things that vary between models (watch for these)

- **SoC + architecture** — Doorbell Lite is Sigmastar Infinity6E / ARMv7 HF;
  other models may be aarch64. Wrong arch → shim simply won't load.
- **glibc symbol versions** — the shim must link against the camera's own
  libc (that's what `camlib/` is for). A build against a newer glibc loads
  on nothing older.
- **Mangled symbol names** — a firmware update can change the C++ signatures.
  `REQUIRED_SYMBOLS` exists so the watchdog warns instead of silently doing
  nothing.
- **ISP config location/format** — the 180° correction edits
  `/etc/persistent/ubnt_isp.conf` (`"flip"`/`"mirror"` JSON keys). Verify the
  file exists and uses the same keys on the new model.
- **Streamer restart semantics** — re-verify SIGTERM-restart behavior per
  model before trusting the watchdog with it. On the Doorbell Lite a SIGKILL
  makes the camera's supervisor reboot the whole device; assume the same
  until proven otherwise.