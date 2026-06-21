#!/usr/bin/env bats
# Missed-call detection polls the SIM's MC (Missed Calls) memory via
# `gammu getmemory MC 1 100`. gammu 1.42 has no getcalllog and the SIM
# refuses `deletememory MC` (GSM 07.07 says +CPBW does not apply to MC
# anyway), so we can't dedup by deleting after publish. Instead the
# detector snapshots the full top-100 ordered list each poll and
# publishes whichever entries shifted in at the top compared to the
# previous snapshot. The newest call is at Location 1.

load test_helper

# Build a fixture body: each argument is one "Location N: number" pair.
# Locations start at 1 (newest). Helper avoids 800-line heredocs.
mc_block() {
    local loc=1 num
    for num in "$@"; do
        printf 'Memory MC, Location %d\nGeneral number       : "%s"\nName                 : ""\n\n' "$loc" "$num"
        loc=$((loc + 1))
    done
}

@test "first poll silently records baseline, no publish" {
    stub_gammu_mc "$(mc_block +391000000001 +391000000002 +391000000003 +391000000004 +391000000005)"
    stub_mosquitto_pub
    check_missed_calls
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
    # Baseline must be persisted so next poll has something to compare against.
    [ -s "$PROCESSED_CALLS" ]
}

@test "no publish when MC contents are unchanged" {
    stub_gammu_mc "$(mc_block +391000000001 +391000000002 +391000000003 +391000000004 +391000000005)"
    stub_mosquitto_pub
    check_missed_calls          # baseline
    check_missed_calls          # no change
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}

@test "one new call: list shifts by 1, publish exactly the new top entry" {
    stub_gammu_mc "$(mc_block +391000000001 +391000000002 +391000000003 +391000000004 +391000000005)"
    stub_mosquitto_pub
    check_missed_calls          # baseline at top=+391000000001

    # New call from +399999999999 pushes in at Location 1; everything else
    # shifts down by one and the bottom entry falls off.
    stub_gammu_mc "$(mc_block +399999999999 +391000000001 +391000000002 +391000000003 +391000000004)"
    check_missed_calls

    [ "$(publish_count 'Missed call from: +399999999999')" -eq 1 ]
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "1" ]
}

@test "two new calls in one poll window: publish both, newest first" {
    stub_gammu_mc "$(mc_block +391000000001 +391000000002 +391000000003 +391000000004 +391000000005)"
    stub_mosquitto_pub
    check_missed_calls          # baseline

    # Two new calls arrive; list shifts by 2.
    stub_gammu_mc "$(mc_block +397777777777 +398888888888 +391000000001 +391000000002 +391000000003)"
    check_missed_calls

    [ "$(publish_count 'Missed call from: +397777777777')" -eq 1 ]
    [ "$(publish_count 'Missed call from: +398888888888')" -eq 1 ]
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "2" ]
    # Newest first: line 1 should be the most recent call.
    head -n 1 "$PUBLISH_LOG" | grep -qF '+397777777777'
}

@test "same caller repeated: list still shifts, publish triggers" {
    # On a fully-loaded SIM the same person calling twice still shifts
    # the list (their previous entry slides down by 1), so we detect it.
    # Only the pathological case where every slot already holds the same
    # number and that same person calls is undetectable — not tested here.
    stub_gammu_mc "$(mc_block +391000000001 +392000000002 +393000000003 +394000000004 +395000000005)"
    stub_mosquitto_pub
    check_missed_calls          # baseline

    # Same caller as top calls again: new top is +391000000001 again,
    # the previous top shifts to position 2, the tail drops.
    stub_gammu_mc "$(mc_block +391000000001 +391000000001 +392000000002 +393000000003 +394000000004)"
    check_missed_calls

    [ "$(publish_count 'Missed call from: +391000000001')" -eq 1 ]
}

@test "empty MC memory: no publish, no baseline-record crash" {
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

@test "no delete* command is ever invoked on the modem" {
    # SIM refuses deletememory MC / deleteallmemory MC. The detector
    # MUST NOT attempt them — clutters the log with "Security error"
    # noise and is pointless.
    stub_gammu_mc "$(mc_block +391000000001 +391000000002 +391000000003 +391000000004 +391000000005)"
    stub_mosquitto_pub
    check_missed_calls
    check_missed_calls
    [ "$(gammu_call_count deletememory)" -eq 0 ]
    [ "$(gammu_call_count deleteallmemory)" -eq 0 ]
    [ "$(gammu_call_count deleteallcalls)" -eq 0 ]
}

@test "list completely scrambled (e.g. modem reset): re-baseline silently" {
    stub_gammu_mc "$(mc_block +391111111111 +392222222222 +393333333333 +394444444444 +395555555555)"
    stub_mosquitto_pub
    check_missed_calls          # baseline

    # Completely different list with no overlap — modem reset, USB
    # replug, or > MC_SNAPSHOT_SIZE calls in one window. We can't
    # reconstruct what happened, so record the new state silently
    # rather than publishing a flood of dubious notifications.
    stub_gammu_mc "$(mc_block +396666666666 +397777777777 +398888888888 +399999999999 +390000000000)"
    check_missed_calls

    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}
