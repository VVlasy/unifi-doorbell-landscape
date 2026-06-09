#!/usr/bin/env bash
#==============================================================================
# setup-wizard.sh - one-shot automation of the two manual prerequisites:
#
#   1. ENABLE CAMERA SSH on the UniFi console: writes {"enableSsh": true}
#      into the file Protect's `overrides` points to and restarts
#      unifi-protect (only when something actually changed).
#   2. FETCH THE CAMERA'S RECOVERY CODE: every Protect device's recovery
#      code lives in the "password" field of its record inside the NVR's
#      nightly backup zip (cameras.json). We pull the newest backup over
#      SSH and extract it locally - same approach as the community
#      unifi-protect-recovery tool.
#
# Inputs (env):
#   CONSOLE_HOST       UniFi console (UDM/CK) IP/host. Empty -> wizard skipped.
#   CONSOLE_SSH_USER   default root
#   CONSOLE_SSH_PASS   console SSH password (UniFi OS: enable SSH in console
#                      settings first - that one toggle cannot be automated)
#   CAMERA_IP          doorbell IP; empty -> auto-pick if exactly one doorbell
#
# Outputs (stdout, consumed by run.sh):
#   CAMERA_SSH_PASS=<code> and CAMERA_IP=<ip> lines on success.
#
# PREREQUISITE for step 2: automatic backups enabled in Protect (default on).
# The newest backup can be up to ~24h old; a camera adopted today may be
# missing from it - the wizard says so explicitly.
#==============================================================================
set -uo pipefail

: "${CONSOLE_HOST:=}"
: "${CONSOLE_SSH_USER:=root}"
: "${CONSOLE_SSH_PASS:=}"
: "${CAMERA_IP:=}"

log(){ echo "[setup-wizard] $*" >&2; }
fail(){ log "ERROR: $*"; exit 1; }

[ -n "$CONSOLE_HOST" ] || fail "CONSOLE_HOST not set"
[ -n "$CONSOLE_SSH_PASS" ] || fail "CONSOLE_SSH_PASS not set"

export SSHPASS="$CONSOLE_SSH_PASS"
CSSH=(sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 "${CONSOLE_SSH_USER}@${CONSOLE_HOST}")

log "connecting to console ${CONSOLE_SSH_USER}@${CONSOLE_HOST}..."
"${CSSH[@]}" "echo CONSOLE_OK" >/dev/null 2>&1 \
  || fail "cannot SSH to console. Enable SSH in UniFi OS (Console Settings -> Advanced -> SSH) and check the password."

#------------------------------------------------------------------------------
# Step 1: enable camera SSH via the Protect overrides file
#------------------------------------------------------------------------------
log "step 1/2: ensuring camera SSH is enabled in Protect..."
ENABLE_OUT="$("${CSSH[@]}" bash -s <<'EOS' 2>&1
set -u
OVR=""
for d in /usr/share/unifi-protect/app/config/default.json \
         /usr/share/unifi-protect/config/default.json; do
  [ -f "$d" ] && OVR="$(jq -r '.overrides // empty' "$d" 2>/dev/null)" && [ -n "$OVR" ] && break
done
[ -n "$OVR" ] || OVR=/etc/unifi-protect/config.json
if [ -f "$OVR" ] && jq -e '.enableSsh == true' "$OVR" >/dev/null 2>&1; then
  echo "ALREADY_ENABLED $OVR"
else
  mkdir -p "$(dirname "$OVR")"
  if [ -f "$OVR" ] && jq -e . "$OVR" >/dev/null 2>&1; then
    jq '.enableSsh = true' "$OVR" > "${OVR}.tmp" && mv "${OVR}.tmp" "$OVR"
  else
    printf '{"enableSsh": true}\n' > "$OVR"
  fi
  systemctl restart unifi-protect
  echo "ENABLED_AND_RESTARTED $OVR"
fi
EOS
)" || fail "enabling camera SSH failed: ${ENABLE_OUT}"
log "  -> ${ENABLE_OUT}"
case "$ENABLE_OUT" in
  ENABLED_AND_RESTARTED*) log "  note: unifi-protect restarted (brief recording gap); cameras pick up SSH on reconnect (~1-2 min)";;
esac

#------------------------------------------------------------------------------
# Step 2: extract the recovery code from the newest Protect backup
#------------------------------------------------------------------------------
log "step 2/2: locating newest Protect backup on the console..."
ZIP_PATH="$("${CSSH[@]}" "ls -t /srv/unifi-protect/backups/*.zip /etc/unifi-protect/backups/*.zip /data/unifi-core/backups/*.zip /data/unifi-protect/backups/*.zip 2>/dev/null | head -1")" || ZIP_PATH=""
[ -n "$ZIP_PATH" ] || fail "no Protect backup zip found. Enable automatic backups in Protect and wait for the nightly run, or enter the Recovery Code manually (Protect -> camera -> Settings -> Recovery Code)."
log "  backup: ${ZIP_PATH}"

TMPZIP="$(mktemp /tmp/protect-backup-XXXXXX.zip)"
trap 'rm -f "$TMPZIP"' EXIT
"${CSSH[@]}" "cat '$ZIP_PATH'" > "$TMPZIP" || fail "could not download the backup"

CAMS_MEMBER="$(unzip -l "$TMPZIP" | awk '{print $4}' | grep -E '(^|/)cameras\.json$' | head -1)"
[ -n "$CAMS_MEMBER" ] || fail "cameras.json not found inside the backup"
CAMS_JSON="$(unzip -p "$TMPZIP" "$CAMS_MEMBER")" || fail "could not extract cameras.json"

# Tolerant field access: ip lives in .host or .connectionHost across versions.
if [ -n "$CAMERA_IP" ]; then
  SELECTED="$(echo "$CAMS_JSON" | jq -c --arg ip "$CAMERA_IP" \
    'first(.[] | select((.host // .connectionHost // "") == $ip))')"
  [ -n "$SELECTED" ] && [ "$SELECTED" != "null" ] \
    || fail "no camera with IP ${CAMERA_IP} in the backup (backup may pre-date adoption, or wrong IP). Devices in backup: $(echo "$CAMS_JSON" | jq -r '[.[] | "\(.name)@\(.host // .connectionHost // "?")"] | join(", ")')"
else
  DOORBELLS="$(echo "$CAMS_JSON" | jq -c '[.[] | select((.type // .modelKey // "") | test("doorbell"; "i"))]')"
  N="$(echo "$DOORBELLS" | jq 'length')"
  if [ "$N" = "1" ]; then
    SELECTED="$(echo "$DOORBELLS" | jq -c '.[0]')"
  else
    fail "camera_ip not set and found ${N} doorbells in the backup. Set camera_ip. Doorbells: $(echo "$DOORBELLS" | jq -r '[.[] | "\(.name)@\(.host // .connectionHost // "?")"] | join(", ")')"
  fi
fi

NAME="$(echo "$SELECTED" | jq -r '.name // "?"')"
TYPE="$(echo "$SELECTED" | jq -r '.type // .modelKey // "?"')"
IP="$(echo "$SELECTED"   | jq -r '.host // .connectionHost // ""')"
CODE="$(echo "$SELECTED" | jq -r '.password // empty')"
[ -n "$CODE" ] || fail "camera record found (${NAME}) but it has no password field - backup format change? Enter the Recovery Code manually."

log "  found: ${NAME} (${TYPE}) at ${IP}"
log "setup complete. Recovery code extracted (not logged)."

# Machine-readable result for run.sh:
echo "CAMERA_SSH_PASS=${CODE}"
[ -n "$IP" ] && echo "CAMERA_IP=${IP}"
