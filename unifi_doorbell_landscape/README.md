# UniFi Doorbell Landscape

Force a UniFi Protect doorbell to **landscape** orientation. Overrides the
hardcoded portrait ("hallway") rotation — which Protect cannot disable for
doorbells — directly on the camera, and keeps the override applied across
camera reboots via an SSH watchdog.

Fixes the orientation **at the source**: Protect, recordings and all
downstream consumers (go2rtc, Frigate, Loxone, …) get landscape.

See the **Documentation** tab for prerequisites (camera SSH + Recovery Code),
configuration, supported hardware, and caveats.
