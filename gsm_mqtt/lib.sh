#!/bin/bash
# Library of pure functions for the modem add-on.
# Sourced by run.sh in production and by bats tests.
# Loading this file must have no side effects (no I/O on the modem, no MQTT calls).

: "${SMS_QUEUE:=/tmp/sms_queue}"
: "${PROCESSED_CALLS:=/tmp/processed_calls}"
: "${PROCESSED_SMS:=/tmp/processed_sms}"
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

    local timestamp payload
    timestamp=$(date -Iseconds)
    if [ $exit_code -eq 0 ]; then
        bashio::log.info "SMS sent successfully to $number"
        payload=$(jq -cn \
            --arg number "$number" \
            --arg ts "$timestamp" \
            '{number:$number,status:"sent",timestamp:$ts}')
        emit_event "/sms_status" "$payload"
    else
        bashio::log.error "Failed to send SMS to $number: $result"
        payload=$(jq -cn \
            --arg number "$number" \
            --arg err "$result" \
            --arg ts "$timestamp" \
            '{number:$number,status:"failed",error:$err,timestamp:$ts}')
        emit_event "/sms_status" "$payload"
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

    # We intentionally do NOT clear the modem's call log here. A `deleteallcalls`
    # right after `getcalllog` opens a race window: any missed call arriving
    # between the read and the delete is nuked from the modem without ever
    # being processed, so the user gets no notification. Datetime-based dedup
    # already guarantees we never re-publish a call we've seen; the modem's own
    # FIFO rotation keeps its log bounded. Don't add a delete here.
    return 0
}

# Placeholder for inbound SMS handling. Wired into the main loop and into
# tests/sms_receive.bats; the modem-specific parsers below are TODO stubs.
# Drop in real implementations of parse_sms_dump and parse_sms_entry to enable.
parse_sms_dump() {
    # TODO: split `gammu getallsms` output into one record per SMS, one per line.
    # Echo each record verbatim (escaped as needed) so the caller's `while read`
    # can hand it to parse_sms_entry.
    return 0
}

parse_sms_entry() {
    # TODO: given one SMS record, echo "location|sender|datetime|body_base64".
    # Return 1 if the record cannot be parsed (skipped by the caller).
    return 1
}

check_received_sms() {
    local sms_dump exit_code
    sms_dump=$(LC_ALL=C gammu -c "$GAMMU_CONFIG" getallsms 2>&1)
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        bashio::log.debug "Could not read SMS (modem may not support it): $sms_dump"
        return 1
    fi

    local entry parsed location sender datetime body_b64 body key payload
    while IFS= read -r entry; do
        parsed=$(parse_sms_entry "$entry") || continue
        IFS='|' read -r location sender datetime body_b64 <<<"$parsed"
        key="${location}_${datetime}"
        if dedup_seen "$PROCESSED_SMS" "$key"; then
            continue
        fi
        body=$(echo "$body_b64" | base64 -d 2>/dev/null)
        payload=$(jq -n \
            --arg from "$sender" \
            --arg ts "$datetime" \
            --arg body "$body" \
            '{from:$from,timestamp:$ts,body:$body}')
        bashio::log.info "Received SMS from: $sender"
        emit_event "/sms_received" "$payload"
        dedup_mark "$PROCESSED_SMS" "$key"
        LC_ALL=C gammu -c "$GAMMU_CONFIG" deletesms 1 "$location" >/dev/null 2>&1 || true
    done < <(parse_sms_dump "$sms_dump")
    return 0
}
