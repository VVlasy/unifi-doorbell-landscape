# Home Assistant app (add-on): UniFi Doorbell Landscape
# Since Supervisor 2026.04.0 the base image must be set explicitly (no BUILD_FROM).
# Tag scheme is <alpine>-<release>, NOT the bare release tag.
FROM ghcr.io/home-assistant/base:3.23-2026.05.0

ARG BUILD_VERSION
ARG BUILD_ARCH

# bash       - the watchdog/wizard are bash scripts
# openssh    - SSH client to reach the camera + console
# sshpass    - non-interactive password auth (camera Recovery Code / console)
# coreutils  - GNU base64 (-w0); busybox base64 lacks it
# jq, unzip  - setup wizard: parse cameras.json from the Protect backup zip
RUN apk add --no-cache bash openssh-client sshpass coreutils jq unzip


COPY rotation/ /opt/rotation/
COPY run.sh /
RUN chmod a+x /run.sh \
      /opt/rotation/camera-rotation-watchdog.sh \
      /opt/rotation/setup-wizard.sh \
      /opt/rotation/streamer_wrap.sh

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="app" \
  io.hass.arch="${BUILD_ARCH}"

CMD [ "/run.sh" ]
