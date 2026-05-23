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
    source "$BATS_TEST_DIRNAME/../time_logger/lib.sh"
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

# Convenience: stub gammu to print a static body for getcalllog and succeed
# silently for deleteallcalls. Anything else exits non-zero.
stub_gammu_calllog() {
    local body="$1"
    _calllog_body="$body"
    export _calllog_body
    _route_calllog() {
        case "$1" in
            getcalllog) printf '%s\n' "$_calllog_body"; return 0;;
            deleteallcalls) return 0;;
            *) return 1;;
        esac
    }
    stub_gammu_dispatch _route_calllog
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
