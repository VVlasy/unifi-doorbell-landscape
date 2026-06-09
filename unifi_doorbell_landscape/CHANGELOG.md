# Changelog

## 1.4.0

- Switch to prebuilt images published on GHCR
  (`ghcr.io/vvlasy/unifi-doorbell-landscape`). Installs and updates now pull
  a ready image instead of building locally — much faster and no build
  failures on the Home Assistant host. No functional changes.

## 1.2.4
- a test update to verify update process

## 1.2.3

- Fix rotation labels: on real hardware the `none` and `-90` options produced
  each other's orientation. Their underlying hallway/ISP values are swapped so
  the dropdown labels now match what the camera actually shows. If you were on
  1.2.x, re-pick your Rotation after updating.

## 1.2.2

- Fix false "hook symbols missing" warning: the camera-side symbol check
  grepped the streamer binary directly, which the camera's busybox grep
  mishandles (false negatives, plus a stray "0" in the log). It now pipes the
  binary through `tr` (NUL to newline) so grep sees the symbol table as text
  - the same trick already used for /proc/environ. The rotation hook itself
  is unchanged.

## 1.2.1

- Fix wizard crash on first run: deleting the console password tripped schema
  validation ("Missing option 'console_ssh_password'"). The option is now
  optional (`password?`, no default), the wizard uses the proper one-arg
  delete, and option persistence is non-fatal so a hiccup can't crash the
  watchdog. If you hit this on 1.2.0, the recovery code was still saved -
  update and restart.

## 1.2.0

- Single **Rotation** dropdown (`none` / `90` / `-90`) replaces the separate
  `hallway_value` + `isp_flip` + `isp_mirror` options. `90` and `-90` are the
  two landscape directions (180° apart) so you can flip to whichever is
  upright for your mount. run.sh maps the choice to the underlying
  hallway/ISP values; standalone users can still set those three directly to
  override.

## 1.1.1

- Nicer settings UI: `model` and `hallway_value` are dropdowns
  (`list(...)` schema), `isp_flip`/`isp_mirror` are toggles (`bool`).
  Functionally identical; run.sh maps true/false back to 1/0.

## 1.1.0

- **Multi-model scaffolding**: per-model builds under `rotation/models/<id>/`
  (`rot90.so` + `model.env` with probe-match regex and required symbols).
  New `model` option (`auto` probes the camera and picks the build; force an
  id to override). Unsupported cameras get a ready-to-paste diagnostic dump
  in the log; see `ADDING_A_MODEL.md`.
- 