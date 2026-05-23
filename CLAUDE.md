# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Home Assistant add-on (not a standalone app). The whole add-on is one shell script — `time_logger/run.sh` — packaged in a hassio-addons base image. Home Assistant runs the container; there is no local build/test/lint pipeline. To ship a change, bump `version` in `time_logger/config.yaml` and commit; users pull via the add-on store using `repository.yaml`.

The user-facing name in HA is "Time Logger Add-On" but the actual function is GSM modem monitoring + SMS sending over MQTT. Don't be confused by the legacy `time_logger` slug.

## Architecture (the parts that aren't obvious from one file)

**Single-tool serial access.** All modem operations go through `gammu` against a generated config at `/tmp/gammurc` (`run.sh:28-33`). This is deliberate — earlier versions mixed `gammu` with other AT-command tools and hit serial port conflicts. Do not add a second tool that opens `$SERIAL_PORT` directly; route new modem features through `gammu -c "$GAMMU_CONFIG" ...`.

**Polling loop with strict priority** (`run.sh:152-176`):
1. Drain one SMS from `/tmp/sms_queue` if present (then `sleep 1`, continue — keeps outbound SMS responsive).
2. Otherwise `gammu getcalllog` and publish any new missed calls.
3. `check_received_sms` is a stub for inbound SMS; the gammu calls are commented out and ready to enable.

The loop sleeps 10s between idle cycles. The serial-port wait at the top (`run.sh:154-157`) keeps the loop alive across USB reconnects.

**MQTT command intake is a background subscriber** (`run.sh:133-145`). `mosquitto_sub` runs in a `while read` pipeline backgrounded with `&`; it appends validated JSON to `/tmp/sms_queue`. The main loop consumes the queue. Keep this decoupling — don't call `gammu sendsms` directly from the subscriber, or you'll race the call-log poll on the serial port.

**State files survive only inside the container's tmpfs:**
- `/tmp/sms_queue` — line-per-SMS JSON, FIFO, drained by `sed -i '1d'`.
- `/tmp/processed_calls` — dedup key is `${number}_$(date +%Y%m%d_%H)`, so the same number calling twice within one hour is suppressed. Trimmed to last 100 entries.
- `/tmp/gammurc` — regenerated on every start from `serial_port` config.

**MQTT topic shape** (base = `mqtt_topic` config, default `home/time_logger`):
- Subscribe: `<base>/send_sms` — payload must be `{"number":"...","message":"..."}` (validated with `jq -e '.number and .message'`).
- Publish: `<base>` (missed-call notifications, plain text) and `<base>/sms_status` (JSON with `status`: `sent`/`failed`).

## Config and permissions

`time_logger/config.yaml` is the HA add-on manifest. The `options`/`schema` sections define the UI form; defaults there are also the fallback values referenced in `run.sh:12-17` (keep them in sync). `devices:` exposes `/dev/ttyUSB*`, `/dev/ttyACM*`, and `/dev/bus/usb` — needed for the modem to appear inside the container. `full_access: true` and `host_dbus: true` are currently set; tighten only if you've verified gammu still works without them.

## Working with the modem (inside the container)

Useful one-liners when debugging via the add-on shell:
- `gammu -c /tmp/gammurc identify` — confirm modem is reachable.
- `gammu -c /tmp/gammurc getcalllog` — what the missed-call detector sees.
- `cat /tmp/sms_queue` — pending outbound SMS.
- `cat /tmp/processed_calls` — dedup state.

## Things to know before editing `run.sh`

- The missed-call parser depends on Gammu's English output (`grep -i "Missed"` and a regex for `Number "..."`). Localized Gammu output will break it.
- `bashio::config` returns empty strings (not unset) when a key is missing, so the `: "${VAR:=default}"` fallbacks fire only when the value is literally empty. Don't switch to `${VAR:-default}` — assignment to `VAR` is needed because later code reads it.
- Exit status of a pipeline like `echo "$log" | grep | while read` is the status of the last command, and the `while` body runs in a subshell — variables set inside it won't escape. The current code accommodates this; preserve the pattern or refactor the whole block.
