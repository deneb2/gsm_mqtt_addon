#!/usr/bin/env bats
# Missed-call detection is based on polling the SIM's MC (Missed Calls)
# phonebook memory via `gammu getallmemory MC`. gammu's getcalllog command
# does not exist in 1.42.0 and per-entry `deletememory MC <loc>` is
# rejected as a security error on real-world SIMs, so we cannot use the
# delete-after-publish dedup pattern. Instead, the detector tracks the
# (top_location, top_number) tuple between polls and publishes whenever
# either changes. On the first poll after addon restart, it silently
# records the current top as a baseline so the existing MC backlog
# doesn't flood Home Assistant.

load test_helper

sample_mc_three() {
    cat <<'EOF'
Memory MC, Location 1
General number       : "+391234567890"
Name                 : ""

Memory MC, Location 2
General number       : "+391234567890"
Name                 : ""

Memory MC, Location 3
General number       : "+391111111111"
Name                 : ""
EOF
}

@test "first poll silently records baseline, no publish" {
    stub_gammu_mc "$(sample_mc_three)"
    stub_mosquitto_pub
    check_missed_calls
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}

@test "same MC content on two polls publishes only once (zero, after baseline)" {
    stub_gammu_mc "$(sample_mc_three)"
    stub_mosquitto_pub
    check_missed_calls          # baseline
    check_missed_calls          # no change
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}

@test "new entry at higher location publishes one notification" {
    stub_gammu_mc "$(sample_mc_three)"
    stub_mosquitto_pub
    check_missed_calls          # baseline at location 3

    # New call appears at location 4
    stub_gammu_mc "$(sample_mc_three)
Memory MC, Location 4
General number       : \"+399999999999\"
Name                 : \"\""
    check_missed_calls

    [ "$(publish_count 'Missed call from: +399999999999')" -eq 1 ]
}

@test "top entry content changing publishes once (shift-mode SIM)" {
    # Some SIMs keep locations stable but shift content down on new call.
    # Simulate: baseline has +391111 at top location 3, then top location 3
    # gets new content +395555.
    stub_gammu_mc "$(sample_mc_three)"
    stub_mosquitto_pub
    check_missed_calls          # baseline

    stub_gammu_mc 'Memory MC, Location 1
General number       : "+391234567890"
Name                 : ""

Memory MC, Location 2
General number       : "+391234567890"
Name                 : ""

Memory MC, Location 3
General number       : "+395555555555"
Name                 : ""'
    check_missed_calls

    [ "$(publish_count 'Missed call from: +395555555555')" -eq 1 ]
}

@test "empty MC memory: no publish, no baseline crash" {
    stub_gammu_mc ''
    stub_mosquitto_pub
    check_missed_calls
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}

@test "gammu failure is tolerated (returns 1, no publish)" {
    cat > "$STUB_DIR/gammu" <<'EOF'
#!/usr/bin/env bash
echo "Error opening device" >&2
exit 2
EOF
    chmod +x "$STUB_DIR/gammu"
    stub_mosquitto_pub
    run check_missed_calls
    [ "$status" -eq 1 ]
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}

@test "deleteallcalls / deletememory are NOT invoked" {
    # Whatever happens, we never try to delete from the modem. SIMs reject
    # MC deletion as a security error and gammu 1.42 has no getcalllog,
    # so there's nothing to clean up.
    stub_gammu_mc "$(sample_mc_three)"
    stub_mosquitto_pub
    check_missed_calls
    [ "$(gammu_call_count deleteallcalls)" -eq 0 ]
    [ "$(gammu_call_count deletememory)" -eq 0 ]
    [ "$(gammu_call_count deleteallmemory)" -eq 0 ]
}
