#!/bin/bash
# Library of pure functions for the modem add-on.
# Sourced by run.sh in production and by bats tests.
# Loading this file must have no side effects (no I/O on the modem, no MQTT calls).

: "${SMS_QUEUE:=/tmp/sms_queue}"
: "${PROCESSED_CALLS:=/tmp/processed_calls}"
: "${GAMMU_CONFIG:=/tmp/gammurc}"

send_queued_sms() {
    if [ -s "$SMS_QUEUE" ]; then
        local sms_data
        sms_data=$(head -n 1 "$SMS_QUEUE")
        local number
        number=$(echo "$sms_data" | jq -r '.number // empty' 2>/dev/null)
        local message
        message=$(echo "$sms_data" | jq -r '.message // empty' 2>/dev/null)

        if [ -n "$number" ] && [ -n "$message" ]; then
            bashio::log.info "Sending SMS to $number"
            local result
            result=$(echo "$message" | gammu -c "$GAMMU_CONFIG" sendsms TEXT "$number" 2>&1)
            local exit_code=$?

            if [ $exit_code -eq 0 ]; then
                bashio::log.info "SMS sent successfully to $number"
                mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
                    -t "${MQTT_TOPIC}/sms_status" \
                    -m "{\"number\":\"$number\",\"status\":\"sent\",\"timestamp\":\"$(date -Iseconds)\"}"
            else
                bashio::log.error "Failed to send SMS to $number: $result"
                mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
                    -t "${MQTT_TOPIC}/sms_status" \
                    -m "{\"number\":\"$number\",\"status\":\"failed\",\"error\":\"$result\",\"timestamp\":\"$(date -Iseconds)\"}"
            fi
            sed -i '1d' "$SMS_QUEUE"
            return 0
        else
            bashio::log.warning "Invalid SMS entry in queue, removing"
            sed -i '1d' "$SMS_QUEUE"
            return 1
        fi
    fi
    return 1
}

check_missed_calls() {
    local call_log
    call_log=$(gammu -c "$GAMMU_CONFIG" getcalllog 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        bashio::log.debug "Could not read call log (modem may not support it): $call_log"
        return 1
    fi

    echo "$call_log" | grep -i "Missed" | while IFS= read -r line; do
        if [[ "$line" =~ [Nn]umber[[:space:]]*[\"\']*([+0-9]+) ]]; then
            local caller_number="${BASH_REMATCH[1]}"
            caller_number=$(echo "$caller_number" | tr -d '"' | tr -d "'")
            local call_id="${caller_number}_$(date +%Y%m%d_%H)"

            if ! grep -qF "$call_id" "$PROCESSED_CALLS" 2>/dev/null; then
                local message="Missed call from: $caller_number"
                bashio::log.info "$message"
                mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
                    -t "$MQTT_TOPIC" -m "$message"
                echo "$call_id" >> "$PROCESSED_CALLS"
                tail -100 "$PROCESSED_CALLS" > "$PROCESSED_CALLS.tmp" 2>/dev/null
                mv "$PROCESSED_CALLS.tmp" "$PROCESSED_CALLS" 2>/dev/null
            fi
        fi
    done
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
