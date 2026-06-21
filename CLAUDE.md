# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working with the user on this repo

For any non-trivial change (new feature, refactor, bugfix touching multiple files, design change):

1. **Propose** the change in chat — what + why + risks/trade-offs.
2. **Wait** for the user to accept the approach before writing code.
3. **Implement** locally — do not commit yet.
4. **Show** the diff (or a tight summary) and ask for confirmation.
5. **Commit** only when the user says to.
6. **Push** only when the user explicitly says to push.

Trivial edits (a typo, a comment fix, a version bump in isolation, work the user just spelled out end-to-end in their last message) can compress steps 3–5 into one motion, but the push is always a separate explicit instruction. When a PR is merged, the head branch on the remote is dead — never push follow-up commits to it. Start a fresh branch off the new `main` and open a new PR.

**Red-then-green is the default for any change with behavior to test.** Write the failing test first, commit it (red), then the code that makes it pass, commit that separately (green). This includes bug fixes (the test must fail on the broken code), new behavior (the test must fail before the code exists), and tightening invariants (the test asserts the new invariant). The reviewer sees the bug demonstrated before the fix, and a future refactor can't silently regress what the red commit pinned. Skip this only for: doc-only edits, version bumps in isolation, pure renames/moves with no behavior change, or work the user explicitly told you to do in one motion. When in doubt, write the test first.

## What this repo is

A Home Assistant add-on (not a standalone app). Two shell scripts — `gsm_mqtt/run.sh` (driver) and `gsm_mqtt/lib.sh` (logic) — packaged in a hassio-addons base image. Home Assistant runs the container. There is no in-container build/lint pipeline, but a bats test suite under `tests/` runs on the host against `lib.sh` with `gammu` and `mosquitto_pub` stubbed. To ship a change, bump `version` in `gsm_mqtt/config.yaml` and commit; users pull via the add-on store using `repository.yaml`.

The HA-facing name is "GSM MQTT Bridge"; the slug is `gsm_mqtt`. The repo was originally `test_time_addon` and the addon was called `time_logger` during initial prototyping — if you see those names in old commits or external docs, that's the legacy identity.

## Architecture (the parts that aren't obvious from one file)

**Single-tool serial access.** All modem operations go through `gammu` against a generated config at `/tmp/gammurc` (built in `run.sh` from the `serial_port` setting). This is deliberate — earlier versions mixed `gammu` with other AT-command tools and hit serial port conflicts. Do not add a second tool that opens `$SERIAL_PORT` directly; route new modem features through `gammu -c "$GAMMU_CONFIG" ...`.

**Code split:** `run.sh` is the thin driver (config, MQTT subscriber, main loop). All pure logic lives in `gsm_mqtt/lib.sh`, sourced from `/lib.sh` in the container. Tests in `tests/` source `lib.sh` directly with `gammu` and `mosquitto_pub` stubbed via PATH.

**Polling loop with strict priority** (in `run.sh`):
1. Drain one SMS from `/tmp/sms_queue` if present (then `sleep "$POST_SMS_COOLDOWN"`, continue — keeps outbound SMS responsive while giving the modem time to recover).
2. Otherwise `gammu getmemory MC 1 $MC_SNAPSHOT_SIZE` (the SIM's Missed Calls phonebook) — parse via `parse_mc_snapshot` into a positional snapshot, compare to the previous snapshot saved in `/tmp/processed_calls`. `mc_shift_amount` finds how many entries shifted in at the top; those are published as new missed calls. First poll after restart silently records a baseline so an existing backlog doesn't flood Home Assistant.
3. `check_received_sms` runs `gammu getallsms`, parses each record via `parse_sms_dump` (splits into base64-encoded blocks, one per SMS) and `parse_sms_entry` (extracts `location|sender|datetime|body_b64` with the datetime ISO-normalized), publishes to `<base>/sms_received`, dedups in `/tmp/processed_sms`, and deletes the SMS from SIM memory.

The loop sleeps 10s between idle cycles. The serial-port wait at the top keeps the loop alive across USB reconnects.

**MQTT command intake is a background subscriber** in `run.sh`. `mosquitto_sub` runs in a `while read` pipeline backgrounded with `&`; it appends validated JSON to `/tmp/sms_queue`. The main loop consumes the queue. Keep this decoupling — don't call `gammu sendsms` directly from the subscriber, or you'll race the call-log poll on the serial port.

**State files survive only inside the container's tmpfs:**
- `/tmp/sms_queue` — line-per-SMS JSON, FIFO, drained by `sed -i '1d'`.
- `/tmp/processed_calls` — last line is the most recent MC snapshot (`num1|num2|…|numN`, position 1 = newest). Trimmed to last 200 snapshots. We do NOT delete from MC memory: GSM 07.07 says `+CPBW` (gammu's `deletememory`) does not apply to MC, and real-world SIMs return "Security error" — dedup is by snapshot comparison between polls, not by deletion.
- `/tmp/processed_sms` — same shape, keyed by `${location}_${datetime}` for inbound SMS.
- `/tmp/gammurc` — regenerated on every start from `serial_port` config.

**MQTT topic shape** (base = `mqtt_topic` config, default `home/gsm_mqtt`):
- Subscribe: `<base>/send_sms` — payload must be `{"number":"...","message":"..."}` (validated with `jq -e '.number and .message'`).
- Publish: `<base>` (missed-call notifications, plain text), `<base>/sms_status` (JSON with `status`: `sent`/`failed`), and `<base>/sms_received` (JSON with `from`/`timestamp`/`body`). `timestamp` is ISO 8601 with timezone offset, parsed from gammu's English-locale `Sent` field.

## Config and permissions

`gsm_mqtt/config.yaml` is the HA add-on manifest. The `options`/`schema` sections define the UI form; defaults there are also the fallback values set via `: "${VAR:=default}"` at the top of `run.sh` — keep the two in sync. `devices:` exposes `/dev/ttyUSB*`, `/dev/ttyACM*`, and `/dev/bus/usb` — needed for the modem to appear inside the container. `full_access: true` and `host_dbus: true` are currently set; tighten only if you've verified gammu still works without them.

## Tests

`bats tests/` runs the full suite on the host. `tests/test_helper.bash` sources `lib.sh` directly, shims `bashio::log.*`, and installs PATH-injected stubs for `gammu` and `mosquitto_pub` that record every invocation. When adding a new `check_*` function in `lib.sh`, write a matching `tests/<name>.bats` using the same stub helpers. (Red-then-green discipline is documented in the workflow section above.)

## Working with the modem (inside the container)

Useful one-liners when debugging via the add-on shell:
- `gammu -c /tmp/gammurc identify` — confirm modem is reachable.
- `gammu -c /tmp/gammurc getmemory MC 1 5` — what the missed-call detector sees. Each entry is `Location N` + `General number` + `Name`; Location 1 is the newest. There is no timestamp field. If this returns "Function not supported" the addon can't detect missed calls on this modem.
- `gammu -c /tmp/gammurc getallsms` — what the SMS-receive parser sees.
- `gammu -c /tmp/gammurc getsmsfolders` — list memory locations; folder 1 is usually SIM (SM), folder 2 is modem memory (ME).
- `cat /tmp/sms_queue` — pending outbound SMS.
- `cat /tmp/processed_calls` / `cat /tmp/processed_sms` — dedup state.

## Things to know before editing `lib.sh` / `run.sh`

- The missed-call parser depends on Gammu's English output. `LC_ALL=C` is set on every `gammu` invocation to lock the locale; preserve that if you add new gammu calls.
- Missed-call detection uses `gammu getmemory MC` (not `getcalllog` — that command does not exist in gammu 1.42). `parse_mc_snapshot` produces a positional list of up to `MC_SNAPSHOT_SIZE` numbers; `mc_shift_amount` finds the shift between two snapshots to determine new entries. The MC entries have no timestamp, so the published payload is just `Missed call from: +<number>` with no time field.
- `MC_SNAPSHOT_SIZE` defaults to 100 (matches the SIM7600 MC capacity). Tests override it to 5 in `test_helper.bash` so fixtures stay readable. Don't lower the production default below the SIM's MC capacity — partial snapshots break the shift-comparison invariant.
- `bashio::config` returns empty strings (not unset) when a key is missing, so the `: "${VAR:=default}"` fallbacks fire only when the value is literally empty. Don't switch to `${VAR:-default}` — assignment to `VAR` is needed because later code reads it.
- Do not add `gammu deletememory MC` or `deleteallmemory MC` to `check_missed_calls`. Real SIMs reject these as "Security error. Maybe no PIN?" even when no PIN is required — GSM 07.07 explicitly says `+CPBW` is not applicable to MC storage. The buffer auto-rotates FIFO on overflow anyway (verified empirically on SIM7600E-H).
- `check_received_sms` hardcodes `deletesms 1 "$location"` — memory `1` is SIM (`SM`). If the modem stores inbound SMS in modem memory (`ME`, often `2`) the delete silently fails (the call is suffixed `|| true`), dedup catches the re-publish, but the modem's inbox fills until cleared manually. Run `gammu -c /tmp/gammurc getsmsfolders` to see which memory your modem uses; if it's not SM=1, the constant needs to change or move to config.
- `parse_sms_entry`'s ISO datetime conversion accepts two gammu `Sent`-line shapes: the day-first form `Tue 21 Oct 2025 15:02:00 +0200` and the C-locale ctime form `Tue Oct 21 09:09:43 2025 +0200`. Anything else (different locale abbreviations, 6-digit TZ, ISO output) falls through to the underscore-escaped raw form — dedup still works but the published `timestamp` won't be ISO 8601.
- `lib.sh` uses `base64 | tr -d '\n'` rather than `base64 -w 0` because the addon's Alpine base ships BusyBox, which doesn't accept `-w`. Preserve the `tr -d '\n'` chain on any new encoding calls.
