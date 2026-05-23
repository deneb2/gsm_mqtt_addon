#!/bin/bash
# Library of pure functions for the modem add-on.
# Sourced by run.sh in production and by bats tests.
# Loading this file must have no side effects (no I/O on the modem, no MQTT calls).

: "${SMS_QUEUE:=/tmp/sms_queue}"
: "${PROCESSED_CALLS:=/tmp/processed_calls}"
: "${GAMMU_CONFIG:=/tmp/gammurc}"
: "${DEDUP_TRIM:=200}"
: "${POST_SMS_COOLDOWN:=3}"

emit_event() {
    local topic_suffix="$1"
    local payload="$2"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "${MQTT_TOPIC}${topic_suffix}" -m "$payload"
}

dedup_seen() {
    local state_file="$1"
    local key="$2"
    grep -qF -- "$key" "$state_file" 2>/dev/null
}

dedup_mark() {
    local state_file="$1"
    local key="$2"
    echo "$key" >> "$state_file"
    tail -n "$DEDUP_TRIM" "$state_file" > "$state_file.tmp" 2>/dev/null \
        && mv "$state_file.tmp" "$state_file"
}

# Parse one "Missed" line from `gammu getcalllog`.
# Echoes "number|datetime" on success, returns 1 on no match.
# Example input: Call 1, Missed, Number "+393755403326", Date/time: 21.10.2025 15:02:00
parse_missed_call_line() {
    local line="$1"
    local number datetime
    [[ "$line" =~ [Nn]umber[[:space:]]*[\"\']?([+0-9]+) ]] || return 1
    number="${BASH_REMATCH[1]}"
    [[ "$line" =~ [Dd]ate/time:[[:space:]]*([0-9.]+[[:space:]]+[0-9:]+) ]] || return 1
    datetime="${BASH_REMATCH[1]// /_}"
    echo "${number}|${datetime}"
}

send_queued_sms() {
    [ -s "$SMS_QUEUE" ] || return 1
    local sms_data number message result exit_code
    sms_data=$(head -n 1 "$SMS_QUEUE")
    number=$(echo "$sms_data" | jq -r '.number // empty' 2>/dev/null)
    message=$(echo "$sms_data" | jq -r '.message // empty' 2>/dev/null)

    if [ -z "$number" ] || [ -z "$message" ]; then
        bashio::log.warning "Invalid SMS entry in queue, removing"
        sed -i '1d' "$SMS_QUEUE"
        return 1
    fi

    bashio::log.info "Sending SMS to $number"
    result=$(echo "$message" | LC_ALL=C gammu -c "$GAMMU_CONFIG" sendsms TEXT "$number" 2>&1)
    exit_code=$?
    sed -i '1d' "$SMS_QUEUE"

    if [ $exit_code -eq 0 ]; then
        bashio::log.info "SMS sent successfully to $number"
        emit_event "/sms_status" \
            "{\"number\":\"$number\",\"status\":\"sent\",\"timestamp\":\"$(date -Iseconds)\"}"
    else
        bashio::log.error "Failed to send SMS to $number: $result"
        emit_event "/sms_status" \
            "{\"number\":\"$number\",\"status\":\"failed\",\"error\":\"$result\",\"timestamp\":\"$(date -Iseconds)\"}"
    fi
    return 0
}

check_missed_calls() {
    local call_log exit_code
    call_log=$(LC_ALL=C gammu -c "$GAMMU_CONFIG" getcalllog 2>&1)
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        bashio::log.debug "Could not read call log (modem may not support it): $call_log"
        return 1
    fi

    local line parsed number datetime key
    while IFS= read -r line; do
        parsed=$(parse_missed_call_line "$line") || continue
        number="${parsed%%|*}"
        datetime="${parsed##*|}"
        key="${number}_${datetime}"
        if dedup_seen "$PROCESSED_CALLS" "$key"; then
            continue
        fi
        bashio::log.info "Missed call from: $number"
        emit_event "" "Missed call from: $number"
        dedup_mark "$PROCESSED_CALLS" "$key"
    done < <(echo "$call_log" | grep -i "Missed")

    # Clear the modem's call log so it stays bounded. Datetime-based dedup is
    # the correctness mechanism; clearing is hygiene. Failures are tolerated.
    LC_ALL=C gammu -c "$GAMMU_CONFIG" deleteallcalls >/dev/null 2>&1 || true
    return 0
}

check_received_sms() {
    # Future implementation:
    # local sms_list
    # sms_list=$(gammu -c "$GAMMU_CONFIG" getallsms 2>&1)
    #
    # Parse SMS, publish to MQTT, delete from SIM
    # gammu -c "$GAMMU_CONFIG" deletesms 1 <location>

    return 0
}
