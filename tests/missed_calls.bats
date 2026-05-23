#!/usr/bin/env bats
load test_helper

@test "parse_missed_call_line extracts number and datetime" {
    run parse_missed_call_line 'Call 1, Missed, Number "+391234567890", Date/time: 21.10.2025 15:02:00'
    [ "$status" -eq 0 ]
    [ "$output" = "+391234567890|21.10.2025_15:02:00" ]
}

@test "parse_missed_call_line rejects line without datetime" {
    run parse_missed_call_line 'Call 1, Missed, Number "+391234567890"'
    [ "$status" -eq 1 ]
}

@test "missed call from new number publishes one MQTT event" {
    stub_gammu_calllog 'Call 1, Missed, Number "+391234567890", Date/time: 21.10.2025 15:02:00'
    stub_mosquitto_pub
    check_missed_calls
    [ "$(publish_count 'Missed call from: +391234567890')" -eq 1 ]
}

@test "same call seen on two polls publishes only once" {
    stub_gammu_calllog 'Call 1, Missed, Number "+391234567890", Date/time: 21.10.2025 15:02:00'
    stub_mosquitto_pub
    check_missed_calls
    check_missed_calls
    [ "$(publish_count 'Missed call from: +391234567890')" -eq 1 ]
}

@test "two distinct calls from same number both publish" {
    stub_gammu_calllog 'Call 1, Missed, Number "+391234567890", Date/time: 21.10.2025 15:02:00
Call 2, Missed, Number "+391234567890", Date/time: 21.10.2025 15:55:00'
    stub_mosquitto_pub
    check_missed_calls
    [ "$(publish_count 'Missed call from: +391234567890')" -eq 2 ]
}

@test "non-missed entries are ignored" {
    stub_gammu_calllog 'Call 1, Incoming, Number "+391111111111", Date/time: 21.10.2025 15:00:00
Call 2, Outgoing, Number "+392222222222", Date/time: 21.10.2025 15:01:00'
    stub_mosquitto_pub
    check_missed_calls
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}

@test "deleteallcalls is NOT invoked (would race with incoming calls)" {
    # Calling deleteallcalls right after getcalllog opens a window where a
    # fresh call can land in the log and be deleted before we ever see it.
    # We rely on datetime-keyed dedup + the modem's natural FIFO rotation
    # to keep things correct and bounded. See lib.sh check_missed_calls.
    stub_gammu_calllog 'Call 1, Missed, Number "+391234567890", Date/time: 21.10.2025 15:02:00'
    stub_mosquitto_pub
    check_missed_calls
    [ "$(gammu_call_count deleteallcalls)" -eq 0 ]
}

@test "dedup matches whole line, not substring" {
    # Regression: dedup_seen used `grep -qF` (substring), so any stored line
    # that contained the lookup key anywhere would falsely suppress a new
    # event. Seed the state file with a line that embeds the new key as a
    # substring and assert the event still publishes.
    echo 'noise_+391234567890_21.10.2025_15:02:00_suffix' > "$PROCESSED_CALLS"
    stub_gammu_calllog 'Call 1, Missed, Number "+391234567890", Date/time: 21.10.2025 15:02:00'
    stub_mosquitto_pub
    check_missed_calls
    [ "$(publish_count 'Missed call from: +391234567890')" -eq 1 ]
}

@test "gammu failure is tolerated (no crash, no publish)" {
    cat > "$STUB_DIR/gammu" <<'EOF'
#!/usr/bin/env bash
echo "Error: cannot open device" >&2
exit 2
EOF
    chmod +x "$STUB_DIR/gammu"
    stub_mosquitto_pub
    run check_missed_calls
    [ "$status" -eq 1 ]
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}
