#!/usr/bin/env bats
load test_helper

@test "POST_SMS_COOLDOWN defaults to at least 3 seconds" {
    [ -n "$POST_SMS_COOLDOWN" ]
    [ "$POST_SMS_COOLDOWN" -ge 3 ]
}

@test "send_queued_sms returns 1 when queue is empty" {
    stub_mosquitto_pub
    run send_queued_sms
    [ "$status" -eq 1 ]
}

@test "send_queued_sms drains one entry and publishes success status" {
    # stub gammu sendsms with success
    cat > "$STUB_DIR/gammu" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in
        -c) shift 2;;
        sendsms) shift; printf '%s\n' "sent ok"; exit 0;;
        *) shift;;
    esac
done
exit 0
EOF
    chmod +x "$STUB_DIR/gammu"
    stub_mosquitto_pub
    echo '{"number":"+391","message":"hi"}' > "$SMS_QUEUE"
    echo '{"number":"+392","message":"two"}' >> "$SMS_QUEUE"

    run send_queued_sms
    [ "$status" -eq 0 ]

    # First entry consumed, second remains
    run wc -l < "$SMS_QUEUE"
    [ "$output" = "1" ]

    [ "$(publish_count 'home/test/sms_status')" -eq 1 ]
    [ "$(publish_count 'status":"sent')" -eq 1 ]
}

@test "send_queued_sms publishes failed status on gammu error" {
    cat > "$STUB_DIR/gammu" <<'EOF'
#!/usr/bin/env bash
echo "Error sending" >&2
exit 5
EOF
    chmod +x "$STUB_DIR/gammu"
    stub_mosquitto_pub
    echo '{"number":"+391","message":"hi"}' > "$SMS_QUEUE"

    run send_queued_sms
    [ "$status" -eq 0 ]

    [ "$(publish_count 'status":"failed')" -eq 1 ]
    # Failed entry is still removed from the queue (no infinite retry loop)
    run wc -l < "$SMS_QUEUE"
    [ "$output" = "0" ]
}

@test "send_queued_sms drops invalid JSON entry without calling gammu" {
    : > "$STUB_DIR/gammu_was_called"
    cat > "$STUB_DIR/gammu" <<EOF
#!/usr/bin/env bash
echo called >> "$STUB_DIR/gammu_was_called"
exit 0
EOF
    chmod +x "$STUB_DIR/gammu"
    stub_mosquitto_pub
    echo 'not-json' > "$SMS_QUEUE"

    run send_queued_sms
    [ "$status" -eq 1 ]
    run wc -l < "$SMS_QUEUE"
    [ "$output" = "0" ]
    run wc -l < "$STUB_DIR/gammu_was_called"
    [ "$output" = "0" ]
}
