#!/usr/bin/with-contenv bashio

# Load user credentials from options using bashio
MQTT_HOST=$(bashio::config 'mqtt_host')
MQTT_PORT=$(bashio::config 'mqtt_port')
MQTT_USER=$(bashio::config 'mqtt_user')
MQTT_PASS=$(bashio::config 'mqtt_pass')
MQTT_TOPIC=$(bashio::config 'mqtt_topic')
SERIAL_PORT=$(bashio::config 'serial_port')

# Optional: Set default values if the configuration is not available
: "${MQTT_HOST:="localhost"}"
: "${MQTT_PORT:="1883"}"
: "${MQTT_USER:="default_user"}"
: "${MQTT_PASS:="default_password"}"
: "${MQTT_TOPIC:="home/time_logger"}"
: "${SERIAL_PORT:="/dev/ttyUSB2"}"

export MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS MQTT_TOPIC SERIAL_PORT

# State files
SMS_QUEUE="/tmp/sms_queue"
PROCESSED_CALLS="/tmp/processed_calls"
PROCESSED_SMS="/tmp/processed_sms"
GAMMU_CONFIG="/tmp/gammurc"
export SMS_QUEUE PROCESSED_CALLS PROCESSED_SMS GAMMU_CONFIG
touch "$SMS_QUEUE" "$PROCESSED_CALLS" "$PROCESSED_SMS"

cat > "$GAMMU_CONFIG" << EOF
[gammu]
device = $SERIAL_PORT
connection = at
EOF
bashio::log.info "Gammu config created at $GAMMU_CONFIG for device $SERIAL_PORT"

# Load function library
# shellcheck disable=SC1091
source /lib.sh

# Start MQTT listener that queues SMS commands
bashio::log.info "Starting MQTT SMS command listener on topic: ${MQTT_TOPIC}/send_sms"
mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "${MQTT_TOPIC}/send_sms" | while read -r payload; do

    bashio::log.info "Received SMS command: $payload"

    if echo "$payload" | jq -e '.number and .message' > /dev/null 2>&1; then
        echo "$payload" >> "$SMS_QUEUE"
        bashio::log.info "SMS queued for sending"
    else
        bashio::log.error "Invalid SMS format. Expected: {\"number\":\"+1234567890\",\"message\":\"text\"}"
    fi
done &

MQTT_SUB_PID=$!
bashio::log.info "MQTT listener started (PID: $MQTT_SUB_PID)"

# Main loop - Gammu-based polling pattern
bashio::log.info "Starting main monitoring loop (Gammu-based)"
while true; do
    # Wait for serial port to be available
    while [ ! -c "$SERIAL_PORT" ]; do
        bashio::log.info "Serial port $SERIAL_PORT not found. Retrying in 5 seconds..."
        sleep 5
    done

    # Priority 1: Drain one SMS from the outbound queue
    if send_queued_sms; then
        bashio::log.info "SMS sent, waiting ${POST_SMS_COOLDOWN}s before next cycle"
        sleep "$POST_SMS_COOLDOWN"
        continue
    fi

    # Priority 2: Check for missed calls
    bashio::log.debug "Checking for missed calls"
    check_missed_calls

    # Priority 3: Check for received SMS (stub — parsers in lib.sh are TODO)
    # check_received_sms

    sleep 10
done
