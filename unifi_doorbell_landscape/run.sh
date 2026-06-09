#!/usr/bin/with-contenv bashio
# ==============================================================================
# Map app (add-on) options -> env for the watchdog; optionally run the SSH
# setup wizard first (enables camera SSH on the console + extracts the
# camera Recovery Code from the newest Protect backup).
#
# Wizard trigger: camera_password empty AND console_host set. On success the
# discovered values are persisted into the app options via the Supervisor API
# and the console password is DELETED from the options (use-once policy).
#
# Outside Home Assistant (standalone docker compose) /data/options.json does
# not exist: configuration comes from plain env vars; the wizard runs when
# CAMERA_SSH_PASS is empty and CONSOLE_HOST is set (nothing is persisted).
# ==============================================================================
set -e

HA_MODE=0
if [ -f /data/options.json ]; then
    HA_MODE=1
    export CAMERA_IP="$(bashio::config 'camera_ip')"
    export CAMERA_SSH_PASS="$(bashio::config 'camera_password')"
    export CAMERA_MODEL="$(bashio::config 'model')"
    export ROTATION="$(bashio::config 'rotation')"
    export ROTATION_CHECK_INTERVAL="$(bashio::config 'check_interval')"
    export CONSOLE_HOST="$(bashio::config 'console_host')"
    export CONSOLE_SSH_USER="$(bashio::config 'console_ssh_user')"
    export CONSOLE_SSH_PASS="$(bashio::config 'console_ssh_password')"
else
    echo "[run] no /data/options.json -> standalone mode, using environment as-is"
fi

# bashio::config renders unset/null as the literal "null"; normalize.
for v in CAMERA_IP CAMERA_SSH_PASS CAMERA_MODEL ROTATION CONSOLE_HOST CONSOLE_SSH_USER CONSOLE_SSH_PASS; do
    [ "$(eval echo "\${$v:-}")" = "null" ] && eval "export $v=''"
done
: "${CAMERA_MODEL:=auto}"

# --- orientation: single 'rotation' option -> hallway + ISP triple ------------
# The encoder's hallway-mode override turns the portrait sensor frame into a
# landscape one; ISP flip+mirror (=180 deg) lands it upright. The triples below
# are calibrated against real hardware (Doorbell Lite) so the dropdown labels
# match the observed on-screen orientation. If a future model differs, THIS
# table is the single place to recalibrate.
#
# Advanced override: set HALLWAY_VALUE / ISP_FLIP / ISP_MIRROR directly in the
# environment (standalone only) to bypass this mapping.
if [ -n "${ROTATION:-}" ] || [ -z "${HALLWAY_VALUE:-}${ISP_FLIP:-}${ISP_MIRROR:-}" ]; then
    case "${ROTATION:-90}" in
        none)  export HALLWAY_VALUE=2 ISP_FLIP=1 ISP_MIRROR=1 ;;  # no net rotation
        90)    export HALLWAY_VALUE=0 ISP_FLIP=1 ISP_MIRROR=1 ;;  # landscape, one direction
        -90)   export HALLWAY_VALUE=0 ISP_FLIP=0 ISP_MIRROR=0 ;;  # landscape, the other direction
        *)     echo "[run] unknown rotation='${ROTATION}', defaulting to 90"
               export HALLWAY_VALUE=0 ISP_FLIP=1 ISP_MIRROR=1 ;;
    esac
fi

# --- optional setup wizard ----------------------------------------------------
if [ -z "${CAMERA_SSH_PASS:-}" ] && [ -n "${CONSOLE_HOST:-}" ]; then
    echo "[run] camera_password empty + console_host set -> running setup wizard"
    WIZ_OUT="$(/opt/rotation/setup-wizard.sh)" || {
        echo "[run] setup wizard FAILED - fix the issue (see log above) or fill camera_password manually."
        exit 1
    }
    eval "$(echo "$WIZ_OUT" | grep -E '^(CAMERA_SSH_PASS|CAMERA_IP)=')"
    export CAMERA_SSH_PASS CAMERA_IP

    if [ "$HA_MODE" = "1" ]; then
        echo "[run] persisting discovered values into app options; deleting console password (use-once)"
        # Non-fatal: a persistence hiccup must never crash the watchdog (set -e).
        bashio::addon.option 'camera_password' "$CAMERA_SSH_PASS" \
            || bashio::log.warning "could not persist camera_password (continuing)"
        if [ -n "${CAMERA_IP:-}" ]; then
            bashio::addon.option 'camera_ip' "$CAMERA_IP" \
                || bashio::log.warning "could not persist camera_ip (continuing)"
        fi
        # One-arg form DELETES the key (schema marks it optional, so the
        # resulting config still validates).
        bashio::addon.option 'console_ssh_password' \
            || bashio::log.warning "could not delete console_ssh_password (continuing)"
    fi
fi

if [ "$HA_MODE" = "1" ]; then
    bashio::log.info "Starting rotation watchdog for camera ${CAMERA_IP} (model ${CAMERA_MODEL}, rotation ${ROTATION:-90}, interval ${ROTATION_CHECK_INTERVAL:-30}s)"
fi

# Installing/starting this app IS the enable switch.
export ROTATION_FIX_ENABLED=1

exec /opt/rotation/camera-rotation-watchdog.sh
