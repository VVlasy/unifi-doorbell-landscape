#!/usr/bin/env bash
#==============================================================================
# camera-rotation-watchdog.sh
#
# Keeps a UniFi Protect doorbell in LANDSCAPE-UPRIGHT.
#
# WHY THIS EXISTS
#   Doorbell firmware hardcodes a 90-degree portrait ("hallway") rotation.
#   Protect cannot turn it off: the camera reports featureFlags.hasHallwayMode=
#   false and ignores the controller's hallwayMode=disabled. So Protect, the
#   recordings and every downstream feed get portrait while other cameras are
#   landscape.
#
#   We override it ON THE CAMERA with two pieces:
#     1. rot90.so  - an LD_PRELOAD shim that interposes the encoder's C++
#        hallwayMode() getters and returns HALLWAY_VALUE (0 = disabled).
#        Injected by bind-mounting streamer_wrap.sh over /bin/ubnt_streamer;
#        the wrapper LD_PRELOADs the shim and execs the real binary.
#        hallwayMode=0 makes the encoder emit the native LANDSCAPE sensor
#        frame (upside-down for a typical doorbell mount).
#     2. ISP flip+mirror=1 in /etc/persistent/ubnt_isp.conf - a 180-degree
#        turn that corrects the upside-down landscape to upright.
#
# MULTI-MODEL SUPPORT
#   rot90.so is firmware-specific (built against the camera's libc, hooking
#   exact mangled symbols). Per-model builds live in models/<id>/:
#     models/<id>/rot90.so    - the shim built for that firmware
#     models/<id>/model.env   - MODEL_NAME, MODEL_MATCH (probe regex),
#                               REQUIRED_SYMBOLS
#   CAMERA_MODEL=auto (default) probes the camera over SSH and picks the
#   first model whose MODEL_MATCH hits the probe text. CAMERA_MODEL=<id>
#   forces a model. An unsupported camera gets a diagnostic dump formatted
#   for a GitHub issue (see ADDING_A_MODEL.md) and the watchdog idles.
#
# WHY A WATCHDOG (not a one-shot)
#   Neither piece survives a camera reboot: cfgmtd wipes unknown files from
#   /etc/persistent on boot and the bind-mount is volatile. This loop
#   re-applies the fix within CHECK_INTERVAL seconds of any drift.
#
# SAFETY
#   - Restarts the streamer with SIGTERM only. NEVER SIGKILL: a -9 on the
#     critical streamer makes the camera's own supervisor reboot the device.
#   - Only restarts a process when its config actually drifted (idempotent).
#   - Run this on the camera's LAN subnet; heavy SSH over a VPN can trip the
#     UniFi IPS.
#==============================================================================
set -uo pipefail

: "${ROTATION_FIX_ENABLED:=0}"
: "${CAMERA_IP:=}"
: "${CAMERA_SSH_PASS:=}"             # the camera's Recovery Code
: "${CAMERA_MODEL:=auto}"            # auto | <models/ subdir name>
: "${HALLWAY_VALUE:=0}"              # 0=disabled=>landscape (firmware default ~1=portrait)
: "${ISP_FLIP:=1}"                   # vertical flip   ) together = 180 deg, to correct
: "${ISP_MIRROR:=1}"                 # horizontal flip ) the upside-down native landscape
: "${ROTATION_CHECK_INTERVAL:=30}"

HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="${HERE}/models"
WRAP_FILE="${HERE}/streamer_wrap.sh"

log(){ echo "[rotation-watchdog] $*"; }

if [ "$ROTATION_FIX_ENABLED" != "1" ]; then
  log "ROTATION_FIX_ENABLED!=1 -> idling (doorbell stays stock portrait)."
  exec sleep infinity
fi
if [ -z "$CAMERA_IP" ] || [ -z "$CAMERA_SSH_PASS" ]; then
  log "CAMERA_IP / CAMERA_SSH_PASS not set -> idling."
  exec sleep infinity
fi
if [ ! -f "$WRAP_FILE" ] || [ ! -d "$MODELS_DIR" ]; then
  log "missing $WRAP_FILE or $MODELS_DIR -> idling."
  exec sleep infinity
fi

export SSHPASS="$CAMERA_SSH_PASS"
SSH="sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 ubnt@${CAMERA_IP}"

# Deliver remote scripts via base64 over STDIN (not as an ssh command arg):
# a multi-KB inlined-base64 arg gets mangled by dropbear/busybox on the camera
# (apply wrote nothing, silently), while stdin is byte-clean. `base64 -d | sh`
# reconstructs and runs it on the camera.
run_remote(){ "$@" | base64 -w0 | $SSH "base64 -d | sh"; }

#==============================================================================
# Model resolution
#==============================================================================

# Camera-side PROBE: dump everything that can identify the model + firmware.
# Sources vary across models/firmware generations, so try them all; harmless
# reads only. Output doubles as the diagnostic bundle for unsupported models.
probe_script() {
cat <<'PRB'
echo "### board/version files"
for f in /etc/board.info /usr/etc/board.info /var/etc/board.info \
         /usr/etc/version /etc/version /usr/lib/version; do
  [ -f "$f" ] && { echo "--- $f"; cat "$f"; }
done
echo "### uname"; uname -a
echo "### streamer"
ls -l /bin/ubnt_streamer 2>/dev/null || echo "NO /bin/ubnt_streamer"
echo "### libc"
ls /lib/libc.so* /lib/libc-* 2>/dev/null
/lib/libc.so.6 2>/dev/null | head -1
PRB
}

# Camera-side symbol check for one model's REQUIRED_SYMBOLS (passed as $1).
symbols_script() {
cat <<SYM
BIN=/bin/ubnt_streamer
[ -f /etc/persistent/realbin/ubnt_streamer ] && BIN=/etc/persistent/realbin/ubnt_streamer
# NUL->newline so grep sees the binary's C-string symbol table as TEXT.
# busybox grep on a raw binary gives false negatives (and -qc leaks a count);
# this is the same trick used for /proc/environ in check_script.
for s in $1; do
  if tr '\\0' '\\n' < "\$BIN" 2>/dev/null | grep -qF "\$s"; then echo "FOUND \$s"; else echo "MISSING \$s"; fi
done
SYM
}

resolve_model() {
  local dir id name match
  if [ "$CAMERA_MODEL" != "auto" ]; then
    dir="${MODELS_DIR}/${CAMERA_MODEL}"
    if [ -f "$dir/rot90.so" ]; then echo "$CAMERA_MODEL"; return 0; fi
    log "forced CAMERA_MODEL='$CAMERA_MODEL' but $dir/rot90.so not found." >&2
    return 1
  fi
  [ -n "$PROBE_TEXT" ] || return 1
  for dir in "$MODELS_DIR"/*/; do
    [ -f "$dir/model.env" ] || continue
    id="$(basename "$dir")"
    name="$(. "$dir/model.env" 2>/dev/null; echo "${MODEL_NAME:-$id}")"
    match="$(. "$dir/model.env" 2>/dev/null; echo "${MODEL_MATCH:-}")"
    [ -n "$match" ] || continue
    if echo "$PROBE_TEXT" | grep -qiE "$match"; then
      log "auto-detected model: $id ($name)" >&2
      echo "$id"; return 0
    fi
  done
  return 1
}

unsupported_report() {
  cat <<RPT
[rotation-watchdog] ============================================================
[rotation-watchdog] UNSUPPORTED CAMERA - no model matched the probe output.
[rotation-watchdog] To request support, open an issue at
[rotation-watchdog]   https://github.com/VVlasy/unifi-doorbell-landscape/issues
[rotation-watchdog] and paste everything between the BEGIN/END markers below.
[rotation-watchdog] See ADDING_A_MODEL.md in the repo for what happens next.
----------------------- BEGIN PROBE -----------------------
${PROBE_TEXT}
------------------------ END PROBE ------------------------
RPT
}

# Probe the camera (retry until reachable), then resolve the model once.
PROBE_TEXT=""
MODEL_ID=""
while :; do
  log "probing camera for model identification..."
  PROBE_TEXT="$(run_remote probe_script 2>/dev/null)" || PROBE_TEXT=""
  if [ -z "$PROBE_TEXT" ]; then
    log "camera unreachable during probe; retrying in 60s"
    sleep 60
    continue
  fi
  MODEL_ID="$(resolve_model)" || true
  break
done

if [ -z "$MODEL_ID" ]; then
  unsupported_report
  exec sleep infinity
fi

MODEL_DIR="${MODELS_DIR}/${MODEL_ID}"
SO_FILE="${MODEL_DIR}/rot90.so"
MODEL_NAME=""; REQUIRED_SYMBOLS=""
# shellcheck disable=SC1091
. "${MODEL_DIR}/model.env" 2>/dev/null || true
log "using model '${MODEL_ID}' (${MODEL_NAME:-unnamed}); shim: ${SO_FILE}"

# Sanity: hook symbols present in this camera's streamer? Warn loudly if not
# (a firmware update may have changed them) but keep going - worst case the
# shim loads and interposes nothing; check_script keeps reporting hook drift.
if [ -n "${REQUIRED_SYMBOLS}" ]; then
  symres="$(run_remote symbols_script "${REQUIRED_SYMBOLS}" 2>/dev/null)" || symres=""
  if echo "$symres" | grep -q MISSING; then
    log "WARNING: hook symbols missing in camera streamer - shim may be ineffective:"
    echo "$symres" | sed 's/^/[rotation-watchdog]   /'
  fi
fi

SO_B64="$(base64 -w0 "$SO_FILE")"
WRAP_B64="$(base64 -w0 "$WRAP_FILE")"

#==============================================================================
# Steady-state check/apply loop
#==============================================================================

# --- camera-side CHECK: prints OK or "DRIFT hook=.. flip=.." -------------------
check_script() {
cat <<CHK
PB=/etc/persistent
cur=\$(for p in \$(pidof ubnt_streamer); do tr '\0' '\n' </proc/\$p/environ 2>/dev/null | grep '^HALLWAY='; done | head -1)
hook=0
[ "\$cur" = "HALLWAY=${HALLWAY_VALUE}" ] && [ -f \$PB/rot90.so ] && [ "\$(grep -c ubnt_streamer /proc/mounts)" != "0" ] && hook=1
flip=0
grep -q '"flip": ${ISP_FLIP}' \$PB/ubnt_isp.conf 2>/dev/null && grep -q '"mirror": ${ISP_MIRROR}' \$PB/ubnt_isp.conf 2>/dev/null && flip=1
[ "\$hook" = 1 ] && [ "\$flip" = 1 ] && echo OK || echo "DRIFT hook=\$hook flip=\$flip"
CHK
}

# --- camera-side APPLY: (re)install hook + flip, restart only what changed -----
apply_script() {
cat <<APPLY
PB=/etc/persistent
echo '${SO_B64}'   | base64 -d > \$PB/rot90.so
echo '${WRAP_B64}' | base64 -d > \$PB/streamer_wrap.sh
chmod +x \$PB/streamer_wrap.sh
mkdir -p \$PB/realbin
[ -f \$PB/realbin/ubnt_streamer ] || { cp -f /bin/ubnt_streamer \$PB/realbin/ubnt_streamer; chmod +x \$PB/realbin/ubnt_streamer; }
echo ${HALLWAY_VALUE} > \$PB/hallway_val
ISPC=0
grep -q '"flip": ${ISP_FLIP}'     \$PB/ubnt_isp.conf || { sed -i 's/"flip": [0-9]*/"flip": ${ISP_FLIP}/'     \$PB/ubnt_isp.conf; ISPC=1; }
grep -q '"mirror": ${ISP_MIRROR}' \$PB/ubnt_isp.conf || { sed -i 's/"mirror": [0-9]*/"mirror": ${ISP_MIRROR}/' \$PB/ubnt_isp.conf; ISPC=1; }
[ "\$(grep -c ubnt_streamer /proc/mounts)" = "0" ] && mount -o bind \$PB/streamer_wrap.sh /bin/ubnt_streamer
kill \$(pidof ubnt_streamer) 2>/dev/null         # SIGTERM only - never -9
[ "\$ISPC" = "1" ] && kill \$(pidof ubnt_ispserver) 2>/dev/null
echo APPLIED
APPLY
}

log "starting; camera=${CAMERA_IP} model=${MODEL_ID} hallway=${HALLWAY_VALUE} flip=${ISP_FLIP} mirror=${ISP_MIRROR} interval=${ROTATION_CHECK_INTERVAL}s"
while true; do
  st="$(run_remote check_script 2>/dev/null)" || st="UNREACHABLE"
  case "$st" in
    OK)           : ;;  # steady state - stay quiet
    UNREACHABLE)  log "camera unreachable (rebooting?); will retry" ;;
    DRIFT*)       log "drift: $st -> applying"
                  r="$(run_remote apply_script 2>&1)"
                  log "apply -> ${r:-apply-failed(no output)}" ;;
    *)            log "unexpected check output: $st" ;;
  esac
  sleep "$ROTATION_CHECK_INTERVAL"
done
