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
