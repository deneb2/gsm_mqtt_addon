#!/usr/bin/env bats
# Tests for the check_received_sms plumbing. The real parsers
# (parse_sms_dump, parse_sms_entry) are TODO stubs in lib.sh — these tests
# override them with fakes that emit a known fixture, so we can lock in the
# dedup / publish / deletesms behavior independently from modem-specific
# output parsing. When the real parsers are implemented, add a separate
# parse_sms_entry.bats with samples of `gammu getallsms` output.

load test_helper

# Fake parser: one record per line on stdin, echo unchanged.
fake_parse_sms_dump() {
    printf '%s\n' "$1"
}

# Fake entry parser: input is already in "location|sender|datetime|body_b64".
fake_parse_sms_entry() {
    [ -n "$1" ] || return 1
    echo "$1"
}

install_fake_parsers() {
    parse_sms_dump()  { fake_parse_sms_dump "$@"; }
    parse_sms_entry() { fake_parse_sms_entry "$@"; }
    export -f parse_sms_dump parse_sms_entry fake_parse_sms_dump fake_parse_sms_entry
}

# Stub gammu so getallsms returns a piped multi-line "dump" and deletesms succeeds.
stub_gammu_sms() {
    _sms_dump="$1"
    export _sms_dump
    _route_sms() {
        case "$1" in
            getallsms) printf '%s\n' "$_sms_dump"; return 0;;
            deletesms) return 0;;
            *) return 1;;
        esac
    }
    stub_gammu_dispatch _route_sms
}

@test "received SMS publishes one event with body, sender, timestamp" {
    install_fake_parsers
    # body "hello" base64-encoded
    stub_gammu_sms '1|+390000|21.10.2025_15:02:00|aGVsbG8='
    stub_mosquitto_pub

    check_received_sms

    [ "$(publish_count 'home/test/sms_received')" -eq 1 ]
    [ "$(publish_count '+390000')" -eq 1 ]
    [ "$(publish_count 'hello')" -eq 1 ]
}

@test "same SMS seen twice publishes only once" {
    install_fake_parsers
    stub_gammu_sms '1|+390000|21.10.2025_15:02:00|aGVsbG8='
    stub_mosquitto_pub

    check_received_sms
    check_received_sms

    [ "$(publish_count 'home/test/sms_received')" -eq 1 ]
}

@test "two distinct SMS from same sender both publish" {
    install_fake_parsers
    stub_gammu_sms $'1|+390000|21.10.2025_15:02:00|b25l\n2|+390000|21.10.2025_15:03:00|dHdv'
    stub_mosquitto_pub

    check_received_sms

    [ "$(publish_count 'home/test/sms_received')" -eq 2 ]
    [ "$(publish_count 'one')" -eq 1 ]
    [ "$(publish_count 'two')" -eq 1 ]
}

@test "deletesms is invoked per published SMS" {
    install_fake_parsers
    stub_gammu_sms '1|+390000|21.10.2025_15:02:00|aGVsbG8='
    stub_mosquitto_pub

    check_received_sms

    [ "$(gammu_call_count deletesms)" -ge 1 ]
}

@test "deletesms is NOT invoked for already-seen SMS" {
    install_fake_parsers
    stub_gammu_sms '1|+390000|21.10.2025_15:02:00|aGVsbG8='
    stub_mosquitto_pub

    check_received_sms          # first poll: publishes + deletes
    : > "$GAMMU_LOG"            # reset call log
    check_received_sms          # second poll: dedup hit, no deletes
    [ "$(gammu_call_count deletesms)" -eq 0 ]
}

@test "gammu failure tolerated (no crash, no publish)" {
    install_fake_parsers
    cat > "$STUB_DIR/gammu" <<'EOF'
#!/usr/bin/env bash
echo "device busy" >&2
exit 1
EOF
    chmod +x "$STUB_DIR/gammu"
    stub_mosquitto_pub

    run check_received_sms
    [ "$status" -eq 1 ]
    run wc -l < "$PUBLISH_LOG"
    [ "$output" = "0" ]
}

@test "TODO: parse_sms_entry stub returns 1 (parser not yet implemented)" {
    # Sanity check that the real lib.sh stub still refuses to parse anything,
    # so production deployments without the parser don't accidentally publish
    # garbage. Remove this test once the real parser is implemented.
    run parse_sms_entry 'any input'
    [ "$status" -eq 1 ]
}
