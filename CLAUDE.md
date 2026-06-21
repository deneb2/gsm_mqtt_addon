# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Home Assistant add-on (not a standalone app). Two shell scripts — `gsm_mqtt/run.sh` (driver) and `gsm_mqtt/lib.sh` (logic) — packaged in a hassio-addons base image. Home Assistant runs the container. There is no in-container build/lint pipeline, but a bats test suite under `tests/` runs on the host against `lib.sh` with `gammu` and `mosquitto_pub` stubbed. To ship a change, bump `version` in `gsm_mqtt/config.yaml` and commit; users pull via the add-on store using `repository.yaml`.

The HA-facing name is "GSM MQTT Bridge"; the slug is `gsm_mqtt`. The repo was originally `test_time_addon` and the addon was called `time_logger` during initial prototyping — if you see those names in old commits or external docs, that's the legacy identity.

## Architecture (the parts that aren't obvious from one file)

**Single-tool serial access.** All modem operations go through `gammu` against a generated config at `/tmp/gammurc` (built in `run.sh` from the `serial_port` setting). This is deliberate — earlier versions mixed `gammu` with other AT-command tools and hit serial port conflicts. Do not add a second tool that opens `$SERIAL_PORT` directly; route new modem features through `gammu -c "$GAMMU_CONFIG" ...`.

**Code split:** `run.sh` is the thin driver (config, MQTT subscriber, main loop). All pure logic lives in `gsm_mqtt/lib.sh`, sourced from `/lib.sh` in the container. Tests in `tests/` source `lib.sh` directly with `gammu` and `mosquitto_pub` stubbed via PATH.

**Polling loop with strict priority** (in `run.sh`):
1. Drain one SMS from `/tmp/sms_queue` if present (then `sleep "$POST_SMS_COOLDOWN"`, continue — keeps outbound SMS responsive while giving the modem time to recover).
2. Otherwise `gammu getallmemory MC` (the SIM's Missed Calls phonebook), parse via `parse_mc_top_entry`, and publish if the highest-location entry's `(location, number)` tuple differs from the last poll. The first poll after addon restart silently records the current top as a baseline so the existing backlog doesn't flood Home Assistant.
3. `check_received_sms` runs `gammu getallsms`, parses each record via `parse_sms_dump` (splits into base64-encoded blocks, one per SMS) and `parse_sms_entry` (extracts `location|sender|datetime|body_b64` with the datetime ISO-normalized), publishes to `<base>/sms_received`, dedups in `/tmp/processed_sms`, and deletes the SMS from SIM memory.

The loop sleeps 10s between idle cycles. The serial-port wait at the top keeps the loop alive across USB reconnects.

**MQTT command intake is a background subscriber** in `run.sh`. `mosquitto_sub` runs in a `while read` pipeline backgrounded with `&`; it appends validated JSON to `/tmp/sms_queue`. The main loop consumes the queue. Keep this decoupling — don't call `gammu sendsms` directly from the subscriber, or you'll race the call-log poll on the serial port.

**State files survive only inside the container's tmpfs:**
- `/tmp/sms_queue` — line-per-SMS JSON, FIFO, drained by `sed -i '1d'`.
- `/tmp/processed_calls` — last line holds the most recent `(location|number)` tuple from MC memory. Trimmed to last 200 entries. We do NOT delete from MC memory: real-world SIMs reject `deletememory MC <loc>` with "Security error" even with no PIN required, so the dedup mechanism is tuple-comparison between polls, not delete-after-publish.
- `/tmp/processed_sms` — same shape, keyed by `${location}_${datetime}` for inbound SMS.
- `/tmp/gammurc` — regenerated on every start from `serial_port` config.

**MQTT topic shape** (base = `mqtt_topic` config, default `home/gsm_mqtt`):
- Subscribe: `<base>/send_sms` — payload must be `{"number":"...","message":"..."}` (validated with `jq -e '.number and .message'`).
- Publish: `<base>` (missed-call notifications, plain text), `<base>/sms_status` (JSON with `status`: `sent`/`failed`), and `<base>/sms_received` (JSON with `from`/`timestamp`/`body`). `timestamp` is ISO 8601 with timezone offset, parsed from gammu's English-locale `Sent` field.

## Config and permissions

`gsm_mqtt/config.yaml` is the HA add-on manifest. The `options`/`schema` sections define the UI form; defaults there are also the fallback values set via `: "${VAR:=default}"` at the top of `run.sh` — keep the two in sync. `devices:` exposes `/dev/ttyUSB*`, `/dev/ttyACM*`, and `/dev/bus/usb` — needed for the modem to appear inside the container. `full_access: true` and `host_dbus: true` are currently set; tighten only if you've verified gammu still works without them.

## Tests

`bats tests/` runs the full suite on the host. `tests/test_helper.bash` sources `lib.sh` directly, shims `bashio::log.*`, and installs PATH-injected stubs for `gammu` and `mosquitto_pub` that record every invocation. When adding a new `check_*` function in `lib.sh`, write a matching `tests/<name>.bats` using the same stub helpers; aim for red-then-green commits so the test demonstrates the bug before the fix lands.

## Working with the modem (inside the container)

Useful one-liners when debugging via the add-on shell:
- `gammu -c /tmp/gammurc identify` — confirm modem is reachable.
- `gammu -c /tmp/gammurc getcalllog` — what the missed-call detector sees.
- `gammu -c /tmp/gammurc getallsms` — what the SMS-receive parser sees.
- `gammu -c /tmp/gammurc getsmsfolders` — list memory locations; folder 1 is usually SIM (SM), folder 2 is modem memory (ME).
- `cat /tmp/sms_queue` — pending outbound SMS.
- `cat /tmp/processed_calls` / `cat /tmp/processed_sms` — dedup state.

## Things to know before editing `lib.sh` / `run.sh`

- The missed-call parser depends on Gammu's English output. `LC_ALL=C` is set on every `gammu` invocation to lock the locale; preserve that if you add new gammu calls.
- Missed-call detection requires `gammu getallmemory MC` to work on the modem (the SIM's Missed Calls phonebook). gammu 1.42 has no `getcalllog` command at all, so the old polling approach is gone. If the modem returns "Function not supported" or "Security error" for `getallmemory MC`, detection is broken and the addon will silently never publish missed calls. Verify with `gammu -c /tmp/gammurc getallmemory MC` from the addon shell. The published payload contains only the caller's number — gammu's MC entries have no timestamp.
- `bashio::config` returns empty strings (not unset) when a key is missing, so the `: "${VAR:=default}"` fallbacks fire only when the value is literally empty. Don't switch to `${VAR:-default}` — assignment to `VAR` is needed because later code reads it.
- The missed-call loop uses process substitution (`done < <(echo "$call_log" | grep -i "Missed")`) rather than `| while`, so the loop body runs in the function's own shell and `local` variables work normally.
- Do not add `gammu deletememory MC` or `gammu deleteallmemory MC` to `check_missed_calls` — see the long comment in that function. Tested on a real SIM: gammu returns "Security error. Maybe no PIN?" even though no PIN is required. Tuple-comparison dedup works around this.
- `check_received_sms` hardcodes `deletesms 1 "$location"` — memory `1` is SIM (`SM`). If the modem stores inbound SMS in modem memory (`ME`, often `2`) the delete silently fails (the call is suffixed `|| true`), dedup catches the re-publish, but the modem's inbox fills until cleared manually. Run `gammu -c /tmp/gammurc getsmsfolders` to see which memory your modem uses; if it's not SM=1, the constant needs to change or move to config.
- `parse_sms_entry`'s ISO datetime conversion is locked to `LC_ALL=C` gammu output (`Tue 21 Oct 2025 15:02:00 +0200`). If the modem or gammu version emits a different date shape (e.g. ISO, locale-specific abbreviations, 6-digit TZ) the regex falls through to the underscore-escaped raw form — dedup still works but the published `timestamp` won't be ISO 8601.
- `lib.sh` uses `base64 | tr -d '\n'` rather than `base64 -w 0` because the addon's Alpine base ships BusyBox, which doesn't accept `-w`. Preserve the `tr -d '\n'` chain on any new encoding calls.
