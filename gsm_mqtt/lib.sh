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
    grep -qFx -- "$key" "$state_file" 2>/dev/null
}

dedup_mark() {
    local state_file="$1"
    local key="$2"
    echo "$key" >> "$state_file"
    tail -n "$DEDUP_TRIM" "$state_file" > "$state_file.tmp" 2>/dev/null \
        && mv "$state_file.tmp" "$state_file"
}

# Find the highest-location entry in a `gammu getallmemory MC` dump.
# Echoes "location|number" on success, returns 1 on empty/malformed input.
# gammu's MC memory entries look like:
#     Memory MC, Location 3
#     General number       : "+391234567890"
#     Name                 : ""
parse_mc_top_entry() {
    local dump="$1"
    [ -n "$dump" ] || return 1
    local top_loc=0 top_num="" cur_loc="" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^Memory[[:space:]]+MC,[[:space:]]+Location[[:space:]]+([0-9]+) ]]; then
            cur_loc="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^General[[:space:]]+number[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
            local num="${BASH_REMATCH[1]}"
            if [ -n "$cur_loc" ] && [ -n "$num" ] && [ "$cur_loc" -gt "$top_loc" ]; then
                top_loc="$cur_loc"
                top_num="$num"
            fi
            cur_loc=""
        fi
    done <<< "$dump"
    [ -n "$top_num" ] || return 1
    echo "${top_loc}|${top_num}"
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
    local mc_dump exit_code
    mc_dump=$(LC_ALL=C gammu -c "$GAMMU_CONFIG" getallmemory MC 2>&1)
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        bashio::log.debug "Could not read MC memory (modem may not support it): $mc_dump"
        return 1
    fi

    local parsed
    parsed=$(parse_mc_top_entry "$mc_dump") || return 0   # empty MC, nothing to do

    local number="${parsed##*|}"
    local last_key=""
    [ -s "$PROCESSED_CALLS" ] && last_key=$(tail -n 1 "$PROCESSED_CALLS")

    if [ "$parsed" = "$last_key" ]; then
        return 0
    fi

    if [ -z "$last_key" ]; then
        # First poll after restart: record baseline silently so the
        # existing MC backlog doesn't get re-published as fresh calls.
        bashio::log.info "Missed-call baseline recorded (no notification on initial poll)"
        dedup_mark "$PROCESSED_CALLS" "$parsed"
        return 0
    fi

    bashio::log.info "Missed call from: $number"
    emit_event "" "Missed call from: $number"
    dedup_mark "$PROCESSED_CALLS" "$parsed"

    # We intentionally never delete from MC memory. Real-world SIMs reject
    # `deletememory MC <loc>` with "Security error" even when no PIN is
    # required, so the addon can't reliably clear the log. Tracking the
    # (top_location, top_number) tuple between polls is the dedup mechanism
    # instead. The SIM's own FIFO rotation eventually drops oldest entries
    # once its capacity is reached.
    return 0
}

# Placeholder for inbound SMS handling. Wired into the main loop and into
# tests/sms_receive.bats; the modem-specific parsers below are TODO stubs.
# Drop in real implementations of parse_sms_dump and parse_sms_entry to enable.
parse_sms_dump() {
    local dump="$1"
    [ -n "$dump" ] || return 0
    local block="" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^Location[[:space:]]+[0-9]+,[[:space:]]+folder[[:space:]]+\"[^\"]+\",[[:space:]]+[A-Za-z]+[[:space:]]+memory ]]; then
            if [ -n "$block" ]; then
                printf '%s' "$block" | base64 | tr -d '\n'
                echo
            fi
            block="$line"
        elif [[ "$line" =~ ^[0-9]+[[:space:]]+SMS[[:space:]]+parts ]]; then
            if [ -n "$block" ]; then
                printf '%s' "$block" | base64 | tr -d '\n'
                echo
                block=""
            fi
        elif [ -n "$block" ]; then
            block+=$'\n'"$line"
        fi
    done <<< "$dump"
    if [ -n "$block" ]; then
        printf '%s' "$block" | base64 | tr -d '\n'
        echo
    fi
}

parse_sms_entry() {
    local b64="$1"
    [ -n "$b64" ] || return 1
    local block
    block=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || return 1
    [ -n "$block" ] || return 1

    local location="" sender="" datetime_raw=""
    local in_body=0 body=""
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ $in_body -eq 0 ]; then
            # Loose by design: body lines starting with "Location N, ..."
            # are kept safe by the in_body guard, not by tightening this
            # regex. parse_sms_dump uses the strict folder+memory variant.
            if [[ "$line" =~ ^Location[[:space:]]+([0-9]+) ]]; then
                location="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^Remote[[:space:]]+number[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                sender="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^Sent[[:space:]]*:[[:space:]]+(.+)$ ]]; then
                datetime_raw="${BASH_REMATCH[1]}"
                datetime_raw="${datetime_raw%"${datetime_raw##*[![:space:]]}"}"
            elif [[ "$line" =~ ^Status ]]; then
                in_body=1
            fi
        else
            if [ -z "$body" ]; then
                [ -z "$line" ] && continue
                body="$line"
            else
                body+=$'\n'"$line"
            fi
        fi
    done <<< "$block"

    [ -n "$location" ] && [ -n "$sender" ] && [ -n "$datetime_raw" ] || return 1

    while [ -n "$body" ] && [ "${body: -1}" = $'\n' ]; do
        body="${body%$'\n'}"
    done

    local datetime="" day="" mon_name="" year="" hms="" tz=""
    # Day-first shape: "Tue 21 Oct 2025 15:02:00 +0200"
    if [[ "$datetime_raw" =~ ([0-9]+)[[:space:]]+([A-Za-z]+)[[:space:]]+([0-9]{4})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]]+([+-][0-9]{4})([[:space:]]|$) ]]; then
        day="${BASH_REMATCH[1]}"; mon_name="${BASH_REMATCH[2]}"
        year="${BASH_REMATCH[3]}"; hms="${BASH_REMATCH[4]}"; tz="${BASH_REMATCH[5]}"
    # C-locale ctime shape: "Tue Oct 21 09:09:43 2025 +0200"
    elif [[ "$datetime_raw" =~ ([A-Za-z]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]]+([0-9]{4})[[:space:]]+([+-][0-9]{4})([[:space:]]|$) ]]; then
        mon_name="${BASH_REMATCH[1]}"; day="${BASH_REMATCH[2]}"
        hms="${BASH_REMATCH[3]}"; year="${BASH_REMATCH[4]}"; tz="${BASH_REMATCH[5]}"
    fi

    if [ -n "$mon_name" ]; then
        local mon=""
        case "$mon_name" in
            Jan) mon=01;; Feb) mon=02;; Mar) mon=03;; Apr) mon=04;;
            May) mon=05;; Jun) mon=06;; Jul) mon=07;; Aug) mon=08;;
            Sep) mon=09;; Oct) mon=10;; Nov) mon=11;; Dec) mon=12;;
        esac
        if [ -n "$mon" ]; then
            printf -v day "%02d" "$day"
            datetime="${year}-${mon}-${day}T${hms}${tz}"
        fi
    fi
    [ -z "$datetime" ] && datetime="${datetime_raw// /_}"

    local body_b64
    body_b64=$(printf '%s' "$body" | base64 | tr -d '\n')
    echo "${location}|${sender}|${datetime}|${body_b64}"
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
