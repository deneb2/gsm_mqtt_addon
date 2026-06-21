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
: "${MC_SNAPSHOT_SIZE:=100}"

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

# Parse `gammu getmemory MC 1 100` output into a `|`-separated single
# line of up to MC_SNAPSHOT_SIZE numbers, ordered Location 1 first
# (Location 1 is the newest call on this hardware — confirmed
# empirically against a SIM7600E-H).
# Empty slots are kept as empty fields so positional comparison works.
# Echoes the snapshot line; empty echo if the dump contained no entries.
parse_mc_snapshot() {
    local dump="$1"
    local -a slots=()
    local cur_loc="" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^Memory[[:space:]]+MC,[[:space:]]+Location[[:space:]]+([0-9]+) ]]; then
            cur_loc="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^General[[:space:]]+number[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
            local num="${BASH_REMATCH[1]}"
            if [ -n "$cur_loc" ]; then
                slots[$((cur_loc - 1))]="$num"
                cur_loc=""
            fi
        fi
    done <<< "$dump"

    local i out=""
    for ((i = 0; i < MC_SNAPSHOT_SIZE; i++)); do
        out+="${slots[$i]:-}|"
    done
    # Always emit the snapshot, even when every slot is empty, so
    # check_missed_calls can persist an "empty MC" baseline. Without
    # this, the first real call after an empty-MC poll has no baseline
    # to shift against and gets silently swallowed.
    printf '%s\n' "$out"
}

# Given the new and old snapshots, find the shift amount k such that
# new[k..N-1] == old[0..N-1-k]. Returns 0..N. Returns N+1 if no shift
# matches (lists are unrelated — modem reset, burst >N, etc.).
mc_shift_amount() {
    local -n _shift_new=$1
    local -n _shift_old=$2
    local n=${#_shift_new[@]}
    local k i match
    # k = n would mean "every entry is new, no overlap with old" — the
    # modem-reset / huge-burst case we want to treat as a re-baseline,
    # so the loop deliberately stops at k = n - 1.
    for ((k = 1; k < n; k++)); do
        match=1
        for ((i = 0; i < n - k; i++)); do
            if [ "${_shift_new[$((k + i))]}" != "${_shift_old[$i]}" ]; then
                match=0
                break
            fi
        done
        if [ "$match" = "1" ]; then
            echo "$k"
            return 0
        fi
    done
    echo "$((n + 1))"
    return 0
}

check_missed_calls() {
    local mc_dump exit_code
    mc_dump=$(LC_ALL=C gammu -c "$GAMMU_CONFIG" getmemory MC 1 "$MC_SNAPSHOT_SIZE" 2>&1)
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        bashio::log.debug "Could not read MC memory (modem may not support it): $mc_dump"
        return 1
    fi

    local new_snapshot
    new_snapshot=$(parse_mc_snapshot "$mc_dump")
    [ -n "$new_snapshot" ] || return 0   # MC empty, nothing to do

    local last_snapshot=""
    [ -s "$PROCESSED_CALLS" ] && last_snapshot=$(tail -n 1 "$PROCESSED_CALLS")

    if [ "$new_snapshot" = "$last_snapshot" ]; then
        return 0
    fi

    if [ -z "$last_snapshot" ]; then
        bashio::log.info "Missed-call baseline recorded (no notification on initial poll)"
        dedup_mark "$PROCESSED_CALLS" "$new_snapshot"
        return 0
    fi

    local -a new_arr old_arr
    IFS='|' read -ra new_arr <<< "$new_snapshot"
    IFS='|' read -ra old_arr <<< "$last_snapshot"
    # `IFS='|' read -ra` strips ONE trailing empty field after a
    # trailing delimiter (bash 5.2 behavior), so a snapshot of exactly
    # MC_SNAPSHOT_SIZE pipes splits to MC_SNAPSHOT_SIZE fields directly.
    # No manual trim — the earlier `unset 'arr[-1]'` here destroyed a
    # legitimate empty slot whenever the last MC entry was empty.

    local k
    k=$(mc_shift_amount new_arr old_arr)

    if [ "$k" -gt "$MC_SNAPSHOT_SIZE" ]; then
        # Lists are unrelated (modem reset, USB replug, burst > snapshot
        # size). Can't reconstruct what was missed; resync the baseline
        # silently rather than spam the user.
        bashio::log.info "Missed-call snapshot resynced (no overlap with previous state)"
        dedup_mark "$PROCESSED_CALLS" "$new_snapshot"
        return 0
    fi

    local i number
    for ((i = 0; i < k; i++)); do
        number="${new_arr[$i]}"
        [ -n "$number" ] || continue
        bashio::log.info "Missed call from: $number"
        emit_event "" "Missed call from: $number"
    done
    dedup_mark "$PROCESSED_CALLS" "$new_snapshot"

    # We never call `gammu deletememory MC` / `deleteallmemory MC`. Real-world
    # SIMs reject them with "Security error" (GSM 07.07 says +CPBW does not
    # apply to MC storage) and the FIFO rotation handles overflow naturally.
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
