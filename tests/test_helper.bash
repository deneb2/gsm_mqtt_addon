#!/usr/bin/env bash
# Common setup for bats tests. Source via `load test_helper` in each .bats file.

setup() {
    export STUB_DIR="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUB_DIR"
    export PATH="$STUB_DIR:$PATH"

    export GAMMU_CONFIG="$BATS_TEST_TMPDIR/gammurc"
    export SMS_QUEUE="$BATS_TEST_TMPDIR/sms_queue"
    export PROCESSED_CALLS="$BATS_TEST_TMPDIR/processed_calls"
    export PROCESSED_SMS="$BATS_TEST_TMPDIR/processed_sms"
    export PUBLISH_LOG="$BATS_TEST_TMPDIR/published"
    export GAMMU_LOG="$BATS_TEST_TMPDIR/gammu_calls"
    touch "$GAMMU_CONFIG" "$SMS_QUEUE" "$PROCESSED_CALLS" "$PROCESSED_SMS" "$PUBLISH_LOG" "$GAMMU_LOG"

    export MQTT_HOST=h MQTT_PORT=1 MQTT_USER=u MQTT_PASS=p MQTT_TOPIC=home/test

    # Use a small MC window in tests so fixtures stay readable. In
    # production this defaults to 100 (the SIM7600 MC capacity).
    export MC_SNAPSHOT_SIZE=5

    # bashio::log.* doesn't exist on the host — shim it out.
    # shellcheck disable=SC2317
    bashio::log.info()    { :; }
    # shellcheck disable=SC2317
    bashio::log.debug()   { :; }
    # shellcheck disable=SC2317
    bashio::log.error()   { :; }
    # shellcheck disable=SC2317
    bashio::log.warning() { :; }
    export -f bashio::log.info bashio::log.debug bashio::log.error bashio::log.warning

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../gsm_mqtt/lib.sh"
}

# Stub `gammu` so every invocation logs args and prints fixed output.
# Usage: stub_gammu_dispatch with a router function name as $1.
# The router receives the gammu subcommand args and decides what to print
# and what exit code to return.
stub_gammu_dispatch() {
    local router="$1"
    cat > "$STUB_DIR/gammu" <<EOF
#!/usr/bin/env bash
# Strip out leading "-c <config>" so the router sees just the subcommand.
args=()
while [ \$# -gt 0 ]; do
    case "\$1" in
        -c) shift 2;;
        *) args+=("\$1"); shift;;
    esac
done
printf '%s\n' "\${args[*]}" >> "$GAMMU_LOG"
$router "\${args[@]}"
EOF
    chmod +x "$STUB_DIR/gammu"
    export -f "$router"
}

# Convenience: stub gammu so `getmemory MC 1 100` prints the supplied
# body and anything else exits non-zero. The body should be the raw
# multi-block output gammu emits for missed-call memory, e.g.:
#     Memory MC, Location 1
#     General number       : "+39…"
#     Name                 : ""
#     ...
stub_gammu_mc() {
    local body="$1"
    _mc_body="$body"
    export _mc_body
    _route_mc() {
        if [ "$1" = "getmemory" ] && [ "$2" = "MC" ]; then
            printf '%s\n' "$_mc_body"
            return 0
        fi
        return 1
    }
    stub_gammu_dispatch _route_mc
}

stub_mosquitto_pub() {
    cat > "$STUB_DIR/mosquitto_pub" <<'EOF'
#!/usr/bin/env bash
topic=""; msg=""
while [ $# -gt 0 ]; do
    case "$1" in
        -t) topic="$2"; shift 2;;
        -m) msg="$2";   shift 2;;
        *)  shift;;
    esac
done
echo "$topic|$msg" >> "$PUBLISH_LOG"
EOF
    chmod +x "$STUB_DIR/mosquitto_pub"
}

# Count lines in the publish log matching a fixed string.
publish_count() {
    local n
    n=$(grep -cF -- "$1" "$PUBLISH_LOG" 2>/dev/null)
    echo "${n:-0}"
}

# Count lines in the gammu call log matching a fixed string.
gammu_call_count() {
    local n
    n=$(grep -cF -- "$1" "$GAMMU_LOG" 2>/dev/null)
    echo "${n:-0}"
}
