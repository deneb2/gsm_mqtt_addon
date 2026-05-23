# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Home Assistant add-on (not a standalone app). Two shell scripts — `time_logger/run.sh` (driver) and `time_logger/lib.sh` (logic) — packaged in a hassio-addons base image. Home Assistant runs the container. There is no in-container build/lint pipeline, but a bats test suite under `tests/` runs on the host against `lib.sh` with `gammu` and `mosquitto_pub` stubbed. To ship a change, bump `version` in `time_logger/config.yaml` and commit; users pull via the add-on store using `repository.yaml`.

The user-facing name in HA is "Time Logger Add-On" but the actual function is GSM modem monitoring + SMS sending over MQTT. Don't be confused by the legacy `time_logger` slug.

## Architecture (the parts that aren't obvious from one file)

**Single-tool serial access.** All modem operations go through `gammu` against a generated config at `/tmp/gammurc` (built in `run.sh` from the `serial_port` setting). This is deliberate — earlier versions mixed `gammu` with other AT-command tools and hit serial port conflicts. Do not add a second tool that opens `$SERIAL_PORT` directly; route new modem features through `gammu -c "$GAMMU_CONFIG" ...`.

**Code split:** `run.sh` is the thin driver (config, MQTT subscriber, main loop). All pure logic lives in `time_logger/lib.sh`, sourced from `/lib.sh` in the container. Tests in `tests/` source `lib.sh` directly with `gammu` and `mosquitto_pub` stubbed via PATH.

**Polling loop with strict priority** (in `run.sh`):
1. Drain one SMS from `/tmp/sms_queue` if present (then `sleep "$POST_SMS_COOLDOWN"`, continue — keeps outbound SMS responsive while giving the modem time to recover).
2. Otherwise `gammu getcalllog` and publish any new missed calls.
3. `check_received_sms` is wired into `lib.sh` but its parsers (`parse_sms_dump`, `parse_sms_entry`) are TODO stubs; the call is commented out in `run.sh` until they're implemented.

The loop sleeps 10s between idle cycles. The serial-port wait at the top keeps the loop alive across USB reconnects.

**MQTT command intake is a background subscriber** in `run.sh`. `mosquitto_sub` runs in a `while read` pipeline backgrounded with `&`; it appends validated JSON to `/tmp/sms_queue`. The main loop consumes the queue. Keep this decoupling — don't call `gammu sendsms` directly from the subscriber, or you'll race the call-log poll on the serial port.

**State files survive only inside the container's tmpfs:**
- `/tmp/sms_queue` — line-per-SMS JSON, FIFO, drained by `sed -i '1d'`.
- `/tmp/processed_calls` — dedup key is `${number}_${call_datetime}` parsed from gammu output. Trimmed to last 200 entries. We do NOT clear the modem's call log — that would race with incoming calls and silently drop them.
- `/tmp/processed_sms` — same shape, keyed by `${location}_${datetime}` for inbound SMS (when enabled).
- `/tmp/gammurc` — regenerated on every start from `serial_port` config.

**MQTT topic shape** (base = `mqtt_topic` config, default `home/time_logger`):
- Subscribe: `<base>/send_sms` — payload must be `{"number":"...","message":"..."}` (validated with `jq -e '.number and .message'`).
- Publish: `<base>` (missed-call notifications, plain text), `<base>/sms_status` (JSON with `status`: `sent`/`failed`), and `<base>/sms_received` (JSON with `from`/`timestamp`/`body`, only once the SMS-receive parsers are implemented).

## Config and permissions

`time_logger/config.yaml` is the HA add-on manifest. The `options`/`schema` sections define the UI form; defaults there are also the fallback values set via `: "${VAR:=default}"` at the top of `run.sh` — keep the two in sync. `devices:` exposes `/dev/ttyUSB*`, `/dev/ttyACM*`, and `/dev/bus/usb` — needed for the modem to appear inside the container. `full_access: true` and `host_dbus: true` are currently set; tighten only if you've verified gammu still works without them.

## Tests

`bats tests/` runs the full suite on the host. `tests/test_helper.bash` sources `lib.sh` directly, shims `bashio::log.*`, and installs PATH-injected stubs for `gammu` and `mosquitto_pub` that record every invocation. When adding a new `check_*` function in `lib.sh`, write a matching `tests/<name>.bats` using the same stub helpers; aim for red-then-green commits so the test demonstrates the bug before the fix lands.

## Working with the modem (inside the container)

Useful one-liners when debugging via the add-on shell:
- `gammu -c /tmp/gammurc identify` — confirm modem is reachable.
- `gammu -c /tmp/gammurc getcalllog` — what the missed-call detector sees.
- `cat /tmp/sms_queue` — pending outbound SMS.
- `cat /tmp/processed_calls` — dedup state.

## Things to know before editing `lib.sh` / `run.sh`

- The missed-call parser depends on Gammu's English output. `LC_ALL=C` is set on every `gammu` invocation to lock the locale; preserve that if you add new gammu calls.
- `parse_missed_call_line`'s datetime regex assumes `DD.MM.YYYY HH:MM:SS`. If your modem/gammu version emits ISO dates the parser will silently skip every line.
- `bashio::config` returns empty strings (not unset) when a key is missing, so the `: "${VAR:=default}"` fallbacks fire only when the value is literally empty. Don't switch to `${VAR:-default}` — assignment to `VAR` is needed because later code reads it.
- The missed-call loop uses process substitution (`done < <(echo "$call_log" | grep -i "Missed")`) rather than `| while`, so the loop body runs in the function's own shell and `local` variables work normally.
- Do not add `gammu deleteallcalls` to `check_missed_calls` — see the long comment in that function for why.
