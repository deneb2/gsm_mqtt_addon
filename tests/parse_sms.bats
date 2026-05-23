#!/usr/bin/env bats
# Tests for the real parse_sms_dump and parse_sms_entry implementations.
# These exercise the parsers against fixtures shaped like real `gammu
# getallsms` output. Plumbing (dedup, deletesms, MQTT publish) is covered
# separately in tests/sms_receive.bats with fake parsers.

load test_helper

# A realistic single-SMS block as gammu emits it. Note the header field
# alignment (Sent / Remote number / Status), the blank line between
# headers and body, and the trailing blank line.
sample_block_single() {
    cat <<'EOF'
Location 1, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+393359609600"
Sent                 : Tue 21 Oct 2025 15:02:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+393358989011"
Status               : Read

Hello, this is a test message.

EOF
}

b64_of_block() {
    "$@" | base64 -w 0
}

@test "parse_sms_entry extracts location, sender, ISO datetime, and body" {
    encoded=$(b64_of_block sample_block_single)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    # Expected: location|sender|datetime|body_b64
    IFS='|' read -r location sender datetime body_b64 <<<"$output"
    [ "$location" = "1" ]
    [ "$sender" = "+393358989011" ]
    [ "$datetime" = "2025-10-21T15:02:00+0200" ]
    body=$(echo "$body_b64" | base64 -d)
    [ "$body" = "Hello, this is a test message." ]
}

@test "parse_sms_entry returns 1 on empty input" {
    run parse_sms_entry ""
    [ "$status" -eq 1 ]
}

@test "parse_sms_entry returns 1 on garbage input" {
    encoded=$(printf '%s' "not an SMS block at all" | base64 -w 0)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 1 ]
}

@test "parse_sms_entry handles a multi-line body" {
    block=$(cat <<'EOF'
Location 3, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+393359609600"
Sent                 : Tue 21 Oct 2025 09:15:30 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+393358989011"
Status               : UnRead

Line one
Line two
Line three

EOF
)
    encoded=$(printf '%s' "$block" | base64 -w 0)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    IFS='|' read -r location sender datetime body_b64 <<<"$output"
    [ "$location" = "3" ]
    body=$(echo "$body_b64" | base64 -d)
    expected=$'Line one\nLine two\nLine three'
    [ "$body" = "$expected" ]
}

sample_dump_two_sms() {
    cat <<'EOF'
Location 1, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+393359609600"
Sent                 : Tue 21 Oct 2025 15:02:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+393358989011"
Status               : Read

First message body.

Location 2, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+393359609600"
Sent                 : Tue 21 Oct 2025 15:05:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+393358989011"
Status               : UnRead

Second message body.

2 SMS parts in 2 SMS sequences
EOF
}

@test "parse_sms_dump on empty input emits nothing" {
    run parse_sms_dump ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "parse_sms_dump emits one line per SMS record" {
    dump=$(sample_dump_two_sms)
    run parse_sms_dump "$dump"
    [ "$status" -eq 0 ]
    # One base64 string per line, no embedded newlines.
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "parse_sms_dump output round-trips through parse_sms_entry" {
    dump=$(sample_dump_two_sms)
    records=$(parse_sms_dump "$dump")
    # Each record is a base64 string parse_sms_entry can decode.
    locations=()
    while IFS= read -r record; do
        parsed=$(parse_sms_entry "$record")
        [ -n "$parsed" ]
        IFS='|' read -r loc _ _ _ <<<"$parsed"
        locations+=("$loc")
    done <<< "$records"
    [ "${locations[0]}" = "1" ]
    [ "${locations[1]}" = "2" ]
}

@test "parse_sms_dump ignores trailing summary line after last block" {
    # The "N SMS parts in M SMS sequences" tail should not become a third
    # record; parse_sms_entry will still decode the two real ones.
    dump=$(sample_dump_two_sms)
    run parse_sms_dump "$dump"
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "parse_sms_entry preserves a body containing a double quote" {
    # JSON publishing path uses jq --arg so escapes are handled downstream,
    # but the parser itself must round-trip the raw bytes through base64.
    block=$(cat <<'EOF'
Location 5, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+393359609600"
Sent                 : Wed 22 Oct 2025 08:00:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+393358989011"
Status               : UnRead

She said "hi" then left.

EOF
)
    encoded=$(printf '%s' "$block" | base64 -w 0)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    IFS='|' read -r _ _ _ body_b64 <<<"$output"
    body=$(echo "$body_b64" | base64 -d)
    [ "$body" = 'She said "hi" then left.' ]
}
